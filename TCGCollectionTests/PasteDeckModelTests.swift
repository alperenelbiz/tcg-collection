import Foundation
import Testing
@testable import TCGCollection2

/// Stands in for `AppModel.catalogSettled`.
@MainActor private final class CatalogStep {
    var settled = true
}

/// Holds a read at its first step until `open()` (`PasteDeckModel.beforeLookup`).
@MainActor private final class Gate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// `"<cardKey>|<section>|<count>"` per card, in the deck's order.
private func shown(_ deck: Deck?) -> [String] { deck?.cards.map { "\($0.cardKey)|\($0.section)|\($0.count)" } ?? [] }

/// A paste from the text to the deck written (phase 3A task 7), on the fixture catalog and a temporary user folder.
@MainActor
struct PasteDeckModelTests {
    /// A library on a temporary folder whose `<game>.json` holds `json` (no file when nil), read once.
    private func library(game: String = "yu-gi-oh", _ json: String? = nil) async throws -> (UserLibrary, URL) {
        let folder = tempDir()
        if let json { try Data(json.utf8).write(to: folder.appending(path: "\(game).json")) }
        let library = UserLibrary(folder: folder, watcher: nil, newID: { "new" })
        await library.load()
        return (library, folder)
    }

    private func pasting(_ text: String, game: String = "yu-gi-oh", deck: String? = nil, library: UserLibrary,
                         reader: CatalogStore, step: CatalogStep = CatalogStep()) -> PasteDeckModel {
        PasteDeckModel(gameID: game, deckID: deck, name: "Wind", text: text, library: library, reader: reader,
                       catalogSettled: { _ in step.settled })
    }

    private static let windDeck = """
        {"version": 1, "decks": [{"id": "yg1", "name": "Wind", "format": "standard", "active": true,
          "cards": [{"cardKey": "swiftwind panther warrior", "name": "Swiftwind Panther Warrior", "section": "main", "count": 1}]}]}
        """

    @Test func readShowsEveryLineAndApplyCreatesTheDeck() async throws {
        let (library, folder) = try await library()
        let model = pasting(String(decoding: try fixture("deck-yugioh.txt"), as: UTF8.self), library: library,
                            reader: try await filledStore())
        #expect(model.canRead && model.lines.isEmpty && !model.canApply)
        await model.read()
        #expect(model.step == .table)
        #expect(model.lines.map(\.number) == [3, 6, 9])
        #expect(model.lines.map(\.section) == ["main", "extra", "side"])
        #expect(model.unknownCount == 0 && model.summary == "6 cards on 3 lines" && model.notice == nil)
        #expect(model.canApply)
        #expect(model.apply() == "new")
        let deck = library.deck(game: "yu-gi-oh", id: "new")
        #expect(deck?.name == "Wind" && deck?.format == "standard" && deck?.active == false)
        #expect(shown(deck) == ["swiftwind panther warrior|main|3", "stardust dragon|extra|2",
                                "token joey and red eyes black dragon|side|1"])
        #expect(deck?.cards.first?.name == "Swiftwind Panther Warrior")
        await library.flush()
        let file = try GameUserFile(data: Data(contentsOf: folder.appending(path: "yu-gi-oh.json")))
        #expect(file.decks == library.decks(game: "yu-gi-oh"))
    }

    /// While the game's catalog step is to come or running, "Read" is off and the sheet says why.
    @Test func readIsOffWhileTheCatalogIsNotSettled() async throws {
        let (library, _) = try await library()
        let step = CatalogStep()
        step.settled = false
        let model = pasting("1 Stardust Dragon", library: library, reader: try await filledStore(), step: step)
        #expect(!model.canRead && model.catalogBlock == PasteDeckModel.catalogUpdating)
        await model.read()
        #expect(model.step == .text)
        step.settled = true
        #expect(model.canRead && model.catalogBlock == nil)
        #expect(!pasting("  \n ", library: library, reader: try await filledStore()).canRead)   // no text
    }

    /// Fix round 1: a settled catalog without products of the game: "Read" is off and the sheet says the catalog is empty;
    /// a read asked anyway stays on the text.
    @Test func anEmptyCatalogSaysSo() async throws {
        let (library, _) = try await library()
        let model = pasting("1 Stardust Dragon", library: library, reader: try CatalogStore.inMemory())
        #expect(model.canRead)                                                  // not checked yet
        await model.checkCatalog()
        #expect(!model.canRead && model.catalogBlock == PasteDeckModel.catalogEmpty)
        await model.read()
        #expect(model.step == .text && model.lines.isEmpty)
        let full = pasting("1 Stardust Dragon", library: library, reader: try await filledStore())
        await full.checkCatalog()
        #expect(full.canRead && full.catalogBlock == nil)
    }

    /// Fix round 1: Cancel, Back or the sheet going away during a read cancels it; it stores nothing and fails nothing.
    @Test func aCancelledReadStoresNothing() async throws {
        let (library, _) = try await library()
        let model = pasting("1 Stardust Dragn\n1 Swiftwind Panther Warrior", library: library, reader: try await filledStore())
        let gate = Gate()
        model.beforeLookup = { await gate.wait() }
        model.startRead()
        while !gate.entered { await Task.yield() }
        #expect(model.step == .reading)
        model.cancelRead()
        gate.open()
        await model.readTask?.value
        #expect(model.step == .text && model.lines.isEmpty)
        model.beforeLookup = nil
        model.startRead()
        await model.readTask?.value
        #expect(model.step == .table && model.lines.count == 2)
    }

    /// Fix round 1: creating a deck from a paste is one library change; a refused file gets no deck and nothing is written.
    @Test func aPastedDeckIsAddedInOneChange() async throws {
        let (library, folder) = try await library()
        let before = library.version
        let card = DeckCard(cardKey: "stardust dragon", name: "Stardust Dragon", section: "extra", count: 2)
        #expect(library.addDeck(game: "yu-gi-oh", name: "Wind", format: "standard", cards: [card, card]) == "new")
        #expect(library.version == before + 1)
        #expect(shown(library.deck(game: "yu-gi-oh", id: "new")) == ["stardust dragon|extra|4"])
        let refused = #"{"version": 99, "collection": []}"#
        let (locked, lockedFolder) = try await self.library(refused)
        #expect(locked.addDeck(game: "yu-gi-oh", name: "Wind", format: "standard", cards: [card]) == nil)
        #expect(locked.decks(game: "yu-gi-oh").isEmpty)
        await locked.flush()
        #expect(try String(contentsOf: lockedFolder.appending(path: "yu-gi-oh.json"), encoding: .utf8) == refused)
        await library.flush()
        #expect(try GameUserFile(data: Data(contentsOf: folder.appending(path: "yu-gi-oh.json"))).decks.count == 1)
    }

    /// A misspelt name and a nonsense line: "Create deck" stays off until one is picked and the other dropped; the pick
    /// takes the picked card's default section.
    @Test func anUnknownLineIsFixedOrDropped() async throws {
        let (library, _) = try await library()
        let model = pasting("2 Stardust Dragn\n1 Qqq Zzz\n1 Swiftwind Panther Warrior\nAjani Resolute", library: library,
                            reader: try await filledStore())
        await model.read()
        #expect(model.unknownCount == 2 && !model.canApply)
        #expect(model.summary == "1 card on 1 line, 2 lines not recognised, 1 line dropped")
        let misspelt = try #require(model.lines.first)
        let offered = try #require(model.suggestions(for: misspelt))
        #expect(offered.first == Suggestion(cardKey: "stardust dragon", name: "Stardust Dragon"))
        #expect(model.suggestions(for: model.lines[1]) == [])
        #expect(model.suggestions(for: model.lines[2]) == nil)                  // known
        #expect(model.suggestions(for: model.lines[3]) == nil)                  // unreadable
        model.pick(offered[0], for: misspelt)
        #expect(model.lines[0].match == .card(cardKey: "stardust dragon", name: "Stardust Dragon"))
        #expect(model.lines[0].section == "extra")
        #expect(model.lines[0].note == "as written: Stardust Dragn")
        #expect(model.unknownCount == 1 && !model.canApply)
        model.drop(model.lines[1])
        #expect(model.isDroppedByHand(model.lines[1]) && model.canApply)
        model.keep(model.lines[1])
        #expect(!model.canApply)
        model.drop(model.lines[1])
        model.apply()
        #expect(shown(library.deck(game: "yu-gi-oh", id: "new")) == ["stardust dragon|extra|2", "swiftwind panther warrior|main|1"])
    }

    /// The exact key of the whole name first, then its base name: `Calm Rune (R02a)` is Calm Rune, a rune.
    @Test func aBracketedNameMatchesByItsBaseName() async throws {
        let (library, _) = try await library(game: "riftbound")
        let model = pasting("2 Calm Rune (R02a)\nChampion:\n1 Kai'Sa, Rebel", game: "riftbound", library: library,
                            reader: try await filledStore())
        await model.read()
        #expect(model.lines.map(\.match) == [.card(cardKey: "calm rune", name: "Calm Rune"),
                                             .card(cardKey: "kai sa rebel", name: "Kai'Sa, Rebel")])
        #expect(model.lines.map(\.section) == ["runes", "champion"])
    }

    /// A new deck's format sorts the lines: Magic's Commander, then Constructed.
    @Test func theFormatOfANewDeckSortsTheLines() async throws {
        let (library, _) = try await library(game: "magic-the-gathering")
        let model = pasting(String(decoding: try fixture("deck-commander.txt"), as: UTF8.self), game: "magic-the-gathering",
                            library: library, reader: try await filledStore())
        #expect(model.format == "commander")
        await model.read()
        #expect(model.lines.map(\.section) == ["commander", "deck", "deck", "deck", "deck", "deck"])
        #expect(model.lines.last?.note == "no section Sideboard in Commander")
        #expect(model.lines[3].match == .card(cardKey: "stingcaster mage", name: "Stingcaster Mage"))   // the base name
        #expect(model.lines[3].note == "as written: Stingcaster Mage (Borderless) (0329)")
        #expect(model.unknownCount == 1)                                        // Fire // Ice: not in the fixture
        model.format = "constructed"
        #expect(model.lines.map(\.section) == ["deck", "deck", "deck", "deck", "deck", "sideboard"])
        #expect(model.lines.first?.note == "no section Commander in Constructed")
    }

    /// Adding to a deck: counts go onto the deck's cards. A change of the deck after the read is said, and the paste adds to
    /// the deck as it is then; a removed deck cannot be added to.
    @Test func aPasteAddsToTheDeckAsItIsNow() async throws {
        let (library, _) = try await library(Self.windDeck)
        let model = pasting("2 Swiftwind Panther Warrior\n1 Stardust Dragon", deck: "yg1", library: library,
                            reader: try await filledStore())
        await model.read()
        #expect(model.notice == nil && model.canApply)
        library.changeDeck(game: "yu-gi-oh", id: "yg1") {
            DeckRules.setting($0, count: 2, cardKey: "swiftwind panther warrior", name: "", section: "main")
        }
        #expect(model.notice == PasteDeckModel.deckChanged)
        #expect(model.apply() == "yg1")
        #expect(shown(library.deck(game: "yu-gi-oh", id: "yg1")) == ["swiftwind panther warrior|main|4", "stardust dragon|extra|1"])
        library.removeDeck(game: "yu-gi-oh", id: "yg1")
        #expect(model.notice == PasteDeckModel.deckGone && !model.canApply && model.apply() == nil)
    }

    /// A game that cannot change: no read, nothing applied; the problem is said.
    @Test func aGameThatCannotChangeSaysWhy() async throws {
        let folder = tempDir().appending(path: "gone")
        let library = UserLibrary(folder: folder, watcher: nil)
        await library.load()
        let model = pasting("1 Stardust Dragon", library: library, reader: try await filledStore())
        #expect(model.problem != nil && !model.canRead)
        #expect(model.problem == library.problem(game: "yu-gi-oh"))
    }

    /// Back, a new text and Read again: the drops of the last table are gone.
    @Test func backAndReadAgain() async throws {
        let (library, _) = try await library()
        let model = pasting("1 Qqq Zzz", library: library, reader: try await filledStore())
        await model.read()
        model.drop(model.lines[0])
        model.back()
        model.text = "1 Qqq Zzz\n1 Stardust Dragon"
        await model.read()
        #expect(model.lines.map(\.number) == [1, 2] && model.unknownCount == 1)
    }
}
