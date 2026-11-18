import Foundation
import Testing
@testable import TCGCollection2

/// The pure decisions of the Decks sidebar section and the deck page (`DeckPage`, `Screen.checked`).
@MainActor
struct DeckViewTests {
    private let riftbound = Games.game("riftbound")!
    private let magic = Games.game("magic-the-gathering")!
    private let yugioh = Games.game("yu-gi-oh")!

    private func card(_ key: String, _ section: String, _ count: Int, name: String? = nil) -> DeckCard {
        DeckCard(cardKey: key, name: name ?? key, section: section, count: count)
    }

    private func deck(_ cards: [DeckCard], active: Bool = true, format: String = "standard") -> Deck {
        Deck(id: "d1", name: "Kai'Sa", format: format, active: active, cards: cards)
    }

    private let kaisa = product(id: 721337, name: "Kai'Sa, Rebel", cardType: "Champion Unit")
    private let rune = product(id: 722282, name: "Calm Rune (R02a)", cardType: "Rune")
    private let lockUp = product(id: 721334, name: "Dockside Lock-Up", cardType: "Gear")

    private func read(_ keys: Set<String>, owned: [String: Int] = [:]) -> DeckRead {
        let all: [String: [ProductRecord]] = ["kai sa rebel": [kaisa], "calm rune": [rune], "dockside lock up": [lockUp]]
        var made = DeckPage.read(game: riftbound, printings: all.filter { keys.contains($0.key) }, keys: keys, rows: [],
                                 ygoType: { _ in nil })
        made.ownedByCard = owned
        return made
    }

    private let none: ([ProductRecord]) -> ShownPrice? = { _ in nil }

    /// A deck alone: every owned copy is available to it.
    private func owned(_ read: DeckRead?) -> [String: Int] { read?.ownedByCard ?? [:] }

    private func line(count: Int, missing: Int, isBasic: Bool = false) -> DeckLine {
        DeckLine(card: card("kai sa rebel", "main", count), shown: kaisa, kind: nil, isBasic: isBasic, owned: count - missing,
                 missing: missing, price: nil)
    }

    /// A57, D13 (phase 6A feedback 1, F2): a list row's price column: the shown printing's price, "No price" for a printing
    /// without one, and nothing for a card without a printing (its label still says "no price").
    @Test func aListRowsPriceColumn() {
        var priced = line(count: 1, missing: 0)
        priced.shownPrice = ShownPrice(amount: 5.12, isLow: false)
        #expect(DeckPage.rowPriceText(priced) == "$5.12")
        #expect(DeckPage.rowPriceText(line(count: 1, missing: 0)) == "No price")
        let gone = DeckLine(card: card("vanished", "main", 1, name: "Vanished"), shown: nil, kind: nil, isBasic: false,
                            owned: 0, missing: 0, price: nil)
        #expect(DeckPage.rowPriceText(gone) == nil)
        #expect(DeckPage.accessibilityText(gone) == "Vanished, ×1, no price")
    }

    // MARK: The sidebar

    /// A14, D7: an active deck shows its missing copies as a number; one that misses nothing, one that is not active, and
    /// one whose catalog read is not there yet show none.
    @Test func theSidebarCountIsForActiveDecksWithMissingCopies() {
        let three = read(["kai sa rebel", "dockside lock up"], owned: ["kai sa rebel": 2])
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 2)]), read: three, available: owned(three)) == nil)        // 0 missing
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3)]), read: three, available: owned(three)) == "1")
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3), card("dockside lock up", "main", 3),
                                            card("dockside lock up", "sideboard", 3)]), read: three,
                                      available: owned(three)) == "7")
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3)], active: false), read: three, available: owned(three)) == nil)
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3)]), read: nil, available: owned(nil)) == nil)
        // A basic rune is never missing, a card the catalog lacks is not counted.
        #expect(DeckPage.sidebarCount(deck([card("calm rune", "runes", 12), card("gone", "main", 3)]),
                                      read: read(["calm rune", "gone"]), available: [:]) == nil)
    }

    /// The count of the sidebar row comes only from a read of the game on screen.
    @Test func theSidebarUsesOnlyAReadOfItsGame() {
        let join = DeckJoin()
        join.read = read(["kai sa rebel"])
        join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 1, priceDay: nil, catalogSettled: true)
        #expect(join.read(game: "riftbound") != nil)
        #expect(join.read(game: "cyberpunk") == nil)
        join.joined = nil
        #expect(join.read(game: "riftbound") == nil)
    }

    // MARK: The screen

    /// A deck screen stored (or launched) for a deck that is not in the game's file any more opens the Collection; every
    /// other screen stays. Its string form is `deck:<id>`; the four old strings keep their meaning.
    @Test func aStoredDeckThatIsGoneFallsBackToTheCollection() {
        #expect(Screen.checked(.deck("a"), deckIDs: ["a", "b"]) == .deck("a"))
        #expect(Screen.checked(.deck("c"), deckIDs: ["a", "b"]) == .collection)
        #expect(Screen.checked(.deck("a"), deckIDs: []) == .collection)
        #expect(Screen.checked(.wanted, deckIDs: []) == .wanted)
        #expect(Screen.checked(.allCards, deckIDs: ["a"]) == .allCards)
        #expect(Screen(storedValue: "deck:6F1A") == .deck("6F1A"))
        #expect(Screen.deck("6F1A").storedValue == "deck:6F1A")
        #expect(Screen(storedValue: "deck:") == nil)
        #expect(Screen(storedValue: "deck") == nil)
        for (text, screen) in [("collection", Screen.collection), ("wanted", .wanted), ("for-sale", .forSale),
                               ("all-cards", .allCards)] {
            #expect(Screen(storedValue: text) == screen)
            #expect(screen.storedValue == text)
        }
        #expect(Screen.deck("a").isList)
    }

    // MARK: The page

    /// Loading until the folder is read (and, for a deck with cards, until its first join ended); unavailable when the
    /// game's file is refused or the folder is missing; gone when the read folder has no such deck; empty for a deck
    /// without cards (no join needed); else listed.
    @Test func thePhaseOfTheDeckPage() {
        let empty = deck([]), full = deck([card("kai sa rebel", "main", 1)])
        let listed = DeckPage.content(full, game: riftbound, read: read(["kai sa rebel"]), available: [:], joinFailed: false,
                                      catalogHasProducts: true, catalogSettled: true, price: none)
        func phase(_ deck: Deck?, listed: DeckContent? = nil, canChange: Bool = true, problem: String? = nil) -> DeckPhase {
            DeckPage.phase(deck: deck, listed: listed, canChange: canChange, problem: problem)
        }
        #expect(phase(nil, canChange: false) == .loading)          // the folder is still read
        #expect(phase(full, canChange: false) == .loading)
        #expect(phase(nil, canChange: false, problem: "riftbound.json cannot be read.") == .unavailable)
        #expect(phase(full, canChange: false, problem: "The collection folder is not at /x.") == .unavailable)
        #expect(phase(nil) == .gone)
        #expect(phase(empty) == .empty)
        #expect(phase(full) == .loading)                          // no join has ended yet
        #expect(phase(full, listed: listed) == .list)
    }

    /// D8: `×3`, `×3 · 2 missing`; a basic card is never "missing", whatever the line says.
    @Test func aCellsLeftText() {
        #expect(DeckPage.countText(line(count: 3, missing: 0)) == "×3")
        #expect(DeckPage.countText(line(count: 3, missing: 2)) == "×3 · 2 missing")
        #expect(DeckPage.countText(line(count: 1, missing: 1)) == "×1 · 1 missing")
        #expect(DeckPage.countText(line(count: 12, missing: 12, isBasic: true)) == "×12")
    }

    /// An empty deck is not a wall of warnings: a section's warning shows only once the deck has a card; then every unmet
    /// bound shows.
    @Test func aWarningShowsOnlyOnADeckWithCards() {
        let format = riftbound.format("standard")
        let legend = DeckSectionView(section: format.sections[0], count: 0, groups: [], warning: "needs 1 card")
        #expect(DeckPage.warning(legend, deckHasCards: false) == nil)
        #expect(DeckPage.warning(legend, deckHasCards: true) == "needs 1 card")
        let fine = DeckSectionView(section: format.sections[0], count: 1, groups: [], warning: nil)
        #expect(DeckPage.warning(fine, deckHasCards: true) == nil)
    }

    /// The page lays the live deck on its last join, as Wanted does: sections in the format's order with their groups, a
    /// card added since the join is pending (no picture, `×n`, no "missing"), the catalog's line while it downloads; on a
    /// settled catalog a card the join looked up and did not find is "not in the catalog" (D13) and not missing.
    @Test func thePageLaysTheLiveDeckOnItsLastJoin() throws {
        let live = deck([card("kai sa rebel", "main", 2), card("dockside lock up", "main", 2), card("calm rune", "runes", 12),
                         card("gone card", "main", 3, name: "Gone Card"), card("new card", "main", 1, name: "New Card")])
        let joined = read(["kai sa rebel", "dockside lock up", "calm rune", "gone card"],
                          owned: ["kai sa rebel": 1, "dockside lock up": 3])
        let during = DeckPage.content(live, game: riftbound, read: joined, available: owned(joined), joinFailed: false, catalogHasProducts: true,
                                      catalogSettled: false, price: none)
        #expect(during.sections.map(\.section.id) == ["legend", "champion", "main", "runes", "battlefields", "sideboard"])
        let main = try #require(during.sections.first { $0.id == "main" })
        #expect(main.groups.map(\.name) == ["Units", "Gear", CardKind.other])
        #expect(main.count == 8)
        let lines = Dictionary(uniqueKeysWithValues: main.groups.flatMap(\.lines).map { ($0.card.cardKey, $0) })
        #expect(DeckPage.countText(try #require(lines["kai sa rebel"])) == "×2 · 1 missing")
        #expect(DeckPage.countText(try #require(lines["dockside lock up"])) == "×2")
        #expect(DeckPage.countText(try #require(lines["gone card"])) == "×3")
        #expect(lines["gone card"]?.name == "Gone Card" && lines["gone card"]?.shown == nil)
        let runes = try #require(during.sections.first { $0.id == "runes" })
        #expect(DeckPage.countText(runes.groups[0].lines[0]) == "×12")         // basic: never missing
        #expect(during.note == CollectionList.catalogDownloading)

        let settled = DeckPage.content(live, game: riftbound, read: joined, available: owned(joined), joinFailed: false, catalogHasProducts: true,
                                       catalogSettled: true, price: none)
        #expect(settled.note == nil)
        // A card the join did not read (added since) is pending: no picture, no "missing", until the next join.
        let added = try #require(settled.sections.flatMap { $0.groups.flatMap(\.lines) }.first { $0.card.cardKey == "new card" })
        #expect(added.shown == nil && DeckPage.countText(added) == "×1")
        #expect(DeckMaths.totals(settled.sections) == "20 cards · 1 missing · 1 without a price")

        // No product of the game: the cards alone, under their saved names.
        let alone = DeckPage.content(live, game: riftbound, read: nil, available: owned(nil), joinFailed: false, catalogHasProducts: false,
                                     catalogSettled: true, price: none)
        #expect(alone.note == CollectionList.catalogEmpty)
        #expect(alone.sections.flatMap { $0.groups.flatMap(\.lines) }.allSatisfy { $0.shown == nil && $0.missing == 0 })
        // A failed join keeps what it read before.
        let failed = DeckPage.content(live, game: riftbound, read: joined, available: owned(joined), joinFailed: true, catalogHasProducts: true,
                                      catalogSettled: true, price: none)
        #expect(failed.note == CollectionList.catalogUnreadableKept)
    }

    /// The read: each card's kind from its first printing with a card type (Yu-Gi-Oh!: the YGOPRODeck type first, A15),
    /// the basic cards, and the copies owned per card (`WantedList.ownedByCard`).
    @Test func theReadKeepsKindsBasicsAndOwnedCopies() {
        let rows = [CollectionRow(productID: 721337, finish: "Normal", count: 2, condition: "", name: "Kai'Sa, Rebel"),
                    CollectionRow(productID: 721337, finish: "Foil", count: 1, condition: "", name: "Kai'Sa, Rebel"),
                    CollectionRow(productID: 999, finish: "Normal", count: 5, condition: "", name: "Other")]
        let made = DeckPage.read(game: riftbound, printings: ["kai sa rebel": [kaisa], "calm rune": [rune]],
                                 keys: ["kai sa rebel", "calm rune", "gone"], rows: rows, ygoType: { _ in "xyz" })
        #expect(made.ownedByCard == ["kai sa rebel": 3])
        #expect(made.basics == ["calm rune"])
        #expect(made.kinds["kai sa rebel"] == CardKind(group: "Units", flags: [CardKind.champion]))
        #expect(made.kinds["calm rune"]?.group == "Runes")
        #expect(made.kinds["gone"] == nil)
        #expect(made.keys == ["kai sa rebel", "calm rune", "gone"])

        let untyped = product(id: 1, game: "yu-gi-oh", name: "Swiftwind Panther Warrior")
        let typed = product(id: 2, game: "yu-gi-oh", name: "Swiftwind Panther Warrior (Starlight Rare)", cardType: "Effect Monster")
        let ygo = DeckPage.read(game: yugioh, printings: ["swiftwind panther warrior": [untyped, typed]],
                                keys: ["swiftwind panther warrior"], rows: [], ygoType: { _ in "xyz" })
        #expect(ygo.kinds["swiftwind panther warrior"] == CardKind(group: "Monsters", flags: [CardKind.extraDeck]))
        let fallback = DeckPage.read(game: yugioh, printings: ["swiftwind panther warrior": [untyped, typed]],
                                     keys: ["swiftwind panther warrior"], rows: [], ygoType: { _ in nil })
        #expect(fallback.kinds["swiftwind panther warrior"] == CardKind(group: "Monsters", flags: []))
    }

    /// The search filters the cells: only matching lines, sections and groups without a match are left out.
    @Test func theSearchFiltersTheCells() {
        let live = deck([card("kai sa rebel", "main", 2), card("dockside lock up", "main", 2), card("calm rune", "runes", 12)])
        let content = DeckPage.content(live, game: riftbound, read: read(["kai sa rebel", "dockside lock up", "calm rune"]),
                                       available: [:], joinFailed: false, catalogHasProducts: true, catalogSettled: true, price: none)
        #expect(DeckPage.filtered(content.sections, text: "") == content.sections)
        let rune = DeckPage.filtered(content.sections, text: "Rune")
        #expect(rune.map(\.id) == ["runes"] && rune[0].groups.flatMap(\.lines).map(\.card.cardKey) == ["calm rune"])
        #expect(DeckPage.filtered(content.sections, text: "kaisa").isEmpty)
        #expect(DeckPage.filtered(content.sections, text: "kai sa").flatMap { $0.groups.flatMap(\.lines) }.count == 1)
    }

    /// D12: a format change keeps every card; a card in a section the new format lacks goes to its kind's default section
    /// there, an unknown kind to the first counted section that is not by hand only.
    @Test func aFormatChangeSendsEachCardToItsDefaultSection() {
        let commander = Deck(id: "d1", name: "Ajani", format: "commander", active: false,
                             cards: [card("ajani resolute", "commander", 1), card("bloodline recollector", "deck", 1),
                                     card("gone", "commander", 1)])
        let changed = DeckPage.changingFormat(commander, to: magic.format("constructed"), game: magic,
                                              kinds: ["ajani resolute": CardKind(group: "Planeswalkers", flags: [])])
        #expect(changed.format == "constructed")
        #expect(changed.cards.map(\.id) == ["ajani resolute|deck", "bloodline recollector|deck", "gone|deck"])
        #expect(changed.cards.reduce(0) { $0 + $1.count } == 3)
    }

    /// One kept state per deck of the window's game: the same while the game stays, every one dropped on a game switch.
    @Test func theWindowKeepsOneStatePerDeckOfItsGame() {
        let memory = DeckMemory()
        let a = memory.state(game: "riftbound", deck: "a"), b = memory.state(game: "riftbound", deck: "b")
        #expect(a !== b && a.deckID == "a" && b.gameID == "riftbound")
        #expect(memory.state(game: "riftbound", deck: "a") === a)
        memory.keep(game: "riftbound")
        #expect(memory.state(game: "riftbound", deck: "b") === b)
        // Final fix B9: a deck that is gone loses its state at once; the others keep theirs.
        memory.keep(decks: ["b"])
        #expect(memory.state(game: "riftbound", deck: "b") === b)
        let fresh = memory.state(game: "riftbound", deck: "a")
        #expect(fresh !== a)
        memory.keep(game: "cyberpunk")
        #expect(memory.state(game: "riftbound", deck: "a") !== fresh)
        #expect(memory.state(game: "cyberpunk", deck: "a") !== memory.state(game: "riftbound", deck: "a"))
    }

    /// The muted line under the sidebar's decks: nothing for 0, then "1 deck cannot be read." / "2 decks cannot be read.".
    @Test func theUnreadableDecksLine() {
        #expect(DeckPage.unreadableText(0) == nil)
        #expect(DeckPage.unreadableText(1) == "1 deck cannot be read.")
        #expect(DeckPage.unreadableText(2) == "2 decks cannot be read.")
    }

    /// Final fix B8: the muted line under a deck page's totals: nothing for 0, then "1 card of this deck cannot be read." /
    /// "2 cards of this deck cannot be read.".
    @Test func theUnreadableCardsLine() {
        #expect(DeckPage.unreadableCardsText(0) == nil)
        #expect(DeckPage.unreadableCardsText(1) == "1 card of this deck cannot be read.")
        #expect(DeckPage.unreadableCardsText(2) == "2 cards of this deck cannot be read.")
    }

    // MARK: Adding cards (phase 3A task 6)

    /// D9, D10: `+` and "Add to deck" add to the card's default section in the deck's format: its kind from its first
    /// printing with a card type, the YGOPRODeck type first for Yu-Gi-Oh! (A15).
    @Test func theSectionAnAddedCardGoesTo() {
        let cyberpunk = Games.game("cyberpunk")!
        func section(_ game: GameDefinition, _ format: String, _ printings: [ProductRecord], ygo: String? = nil) -> String {
            DeckPage.addSection(game: game, format: game.format(format),
                                kind: CardKinds.deckKind(game: game, printings: printings, ygoType: { _ in ygo }))
        }
        let effect = product(id: 1, game: "yu-gi-oh", name: "Stardust Dragon", cardType: "Effect Monster")
        #expect(section(yugioh, "standard", [effect], ygo: "synchro") == "extra")             // the index first
        #expect(section(yugioh, "standard", [effect]) == "main")
        #expect(section(yugioh, "standard", [product(id: 2, game: "yu-gi-oh", name: "X", cardType: "Synchro/Effect Monster")]) == "extra")
        #expect(section(yugioh, "standard", [product(id: 3, game: "yu-gi-oh", name: "Y", cardType: "Spell Card")]) == "main")
        // The first printing with a card type decides.
        #expect(section(yugioh, "standard", [product(id: 4, game: "yu-gi-oh", name: "Z"),
                                             product(id: 5, game: "yu-gi-oh", name: "Z", cardType: "Link/Effect Monster")]) == "extra")
        #expect(section(riftbound, "standard", [kaisa]) == "main")                            // never Champion (by hand)
        #expect(section(riftbound, "standard", [rune]) == "runes")
        #expect(section(magic, "commander", [product(id: 6, game: "magic-the-gathering", name: "Bear", cardType: "Creature — Bear")]) == "deck")
        #expect(section(magic, "constructed", [product(id: 7, game: "magic-the-gathering", name: "Bolt", cardType: "Instant")]) == "deck")
        #expect(section(cyberpunk, "standard", [product(id: 8, game: "cyberpunk", name: "Kerry", cardType: "Legend")]) == "legends")
        // No printing: the format's first counted section that is not by hand only.
        #expect(CardKinds.deckKind(game: yugioh, printings: [], ygoType: { _ in nil }) == nil)
        #expect(DeckPage.addSection(game: yugioh, format: yugioh.format("standard"), kind: nil) == "main")
        #expect(DeckPage.addSection(game: magic, format: magic.format("commander"), kind: nil) == "deck")
    }

    /// `+` adds one copy to the card's default section of the deck's format; `−` takes one off that section first, then off
    /// the others in the format's order.
    @Test func plusAndMinusOfACardFollowItsDefaultSection() {
        let stardust = DeckCardToAdd(cardKey: "stardust dragon", name: "Stardust Dragon",
                                     kind: CardKinds.deckKind(game: yugioh, printings: [product(id: 1, game: "yu-gi-oh", name: "Stardust Dragon",
                                                                                           cardType: "Synchro Monster")], ygoType: { _ in "synchro" }))
        let start = deck([card("stardust dragon", "side", 1)])
        let added = DeckPage.addingOne(DeckPage.addingOne(start, stardust, game: yugioh), stardust, game: yugioh)
        #expect(added.cards == [card("stardust dragon", "side", 1), card("stardust dragon", "extra", 2, name: "Stardust Dragon")])
        let taken = DeckPage.takingOne(DeckPage.takingOne(added, stardust, game: yugioh), stardust, game: yugioh)
        #expect(taken.cards == [card("stardust dragon", "side", 1)])
        #expect(DeckPage.takingOne(taken, stardust, game: yugioh).cards.isEmpty)
    }

    /// Final fix A3: a card page's "New Deck…" gives `addDeck` the card's one copy in its default section of the chosen
    /// format (one library change), the same card `addingOne` adds to an empty deck of that format.
    @Test func aCardPagesNewDeckStartsWithTheCardsOneCopy() async throws {
        let stardust = DeckCardToAdd(cardKey: "stardust dragon", name: "Stardust Dragon",
                                     kind: CardKind(group: "Monsters", flags: [CardKind.extraDeck]))
        let cards = DeckPage.newDeckCards(stardust, format: "standard", game: yugioh)
        #expect(cards == [card("stardust dragon", "extra", 1, name: "Stardust Dragon")])
        #expect(cards == DeckPage.addingOne(deck([]), stardust, game: yugioh).cards)
        let bear = DeckCardToAdd(cardKey: "bear", name: "Bear", kind: nil)
        #expect(DeckPage.newDeckCards(bear, format: "constructed", game: magic).map(\.section) == ["deck"])
        let library = UserLibrary(folder: tempDir(), watcher: nil, newID: { "n1" })
        await library.load()
        let before = library.version
        #expect(library.addDeck(game: "yu-gi-oh", name: "", format: "standard", cards: cards) == "n1")
        #expect(library.version == before + 1)
        #expect(library.deck(game: "yu-gi-oh", id: "n1")?.cards == cards)
    }

    /// The card page's "Decks": one line per (deck, section) that holds the card, in deck order, then the format's section
    /// order (a section the format lacks last); a deck without the card has no line.
    @Test func theCardPageListsEachDeckAndSectionThatHoldsTheCard() {
        let warrior = "swiftwind panther warrior"
        let first = Deck(id: "a", name: "Wind", format: "standard", active: false,
                         cards: [card(warrior, "side", 1), card("other", "main", 3), card(warrior, "main", 2)])
        let none = Deck(id: "b", name: "Empty", format: "standard", active: false, cards: [card("other", "main", 1)])
        let second = Deck(id: "c", name: "Second", format: "standard", active: true,
                          cards: [card(warrior, "maybe", 4), card(warrior, "extra", 1)])
        let lines = DeckPage.cardLines(decks: [first, none, second], cardKey: warrior, game: yugioh)
        #expect(lines == [DeckCardLine(deckID: "a", deckName: "Wind", section: "main", sectionName: "Main Deck", count: 2),
                          DeckCardLine(deckID: "a", deckName: "Wind", section: "side", sectionName: "Side Deck", count: 1),
                          DeckCardLine(deckID: "c", deckName: "Second", section: "extra", sectionName: "Extra Deck", count: 1),
                          DeckCardLine(deckID: "c", deckName: "Second", section: "maybe", sectionName: "maybe", count: 4)])
        #expect(lines.map(\.id) == ["a-main", "a-side", "c-extra", "c-maybe"])
        #expect(DeckPage.cardLines(decks: [none], cardKey: warrior, game: yugioh).isEmpty)
    }

    /// The search cell's `+` is off at 999 or more copies in the card's default section, whatever the other sections hold;
    /// its count is the deck's copies over all sections.
    @Test func theSearchCellsPlusStopsAt999InTheDefaultSection() {
        let lockUp = DeckCardToAdd(cardKey: "dockside lock up", name: "Dockside Lock-Up",
                                   kind: CardKinds.deckKind(game: riftbound, printings: [self.lockUp], ygoType: { _ in nil }))
        let fine = DeckPage.searchCount(deck([card("dockside lock up", "main", 998), card("dockside lock up", "sideboard", 5)]),
                                        lockUp, game: riftbound)
        #expect(fine.copies == 1003 && fine.copies < fine.plusLimit)
        let full = DeckPage.searchCount(deck([card("dockside lock up", "sideboard", 2), card("dockside lock up", "main", 999)]),
                                        lockUp, game: riftbound)
        #expect(full.copies == 1001 && full.copies >= full.plusLimit)
        let above = DeckPage.searchCount(deck([card("dockside lock up", "main", 1200)]), lockUp, game: riftbound)
        #expect(above.copies >= above.plusLimit)
        let none = DeckPage.searchCount(deck([card("dockside lock up", "sideboard", 3)]), lockUp, game: riftbound)
        #expect(none.copies == 3 && none.copies < none.plusLimit)
    }

    /// Fix round 1: the search cell and the card page read a card's printings through two store calls
    /// (`printings(game:cardKeys:)` for a page of results, `printings(game:cardKey:)` for a page); a card whose newest
    /// printing has no card type lands in the same section from both.
    @Test func theSearchAndTheCardPageAddACardToTheSameSection() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.store")
        let store = try CatalogStore(url: url)
        let older = Date(timeIntervalSince1970: 1_700_000_000), newer = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.upsertSets([SetRecord(groupID: 1, gameID: "yu-gi-oh", name: "Old", abbreviation: "", publishedOn: older),
                                    SetRecord(groupID: 2, gameID: "yu-gi-oh", name: "New", abbreviation: "", publishedOn: newer)])
        try await store.replaceProducts(of: 1, with: [product(id: 10, game: "yu-gi-oh", groupID: 1, name: "Stardust Dragon",
                                                              number: "TDGS-EN040", rarity: "Ultra Rare", cardType: "Synchro Monster")], at: newer)
        try await store.replaceProducts(of: 2, with: [product(id: 20, game: "yu-gi-oh", groupID: 2, name: "Stardust Dragon",
                                                              number: "PROMO-EN001", rarity: "Promo")], at: newer)
        let key = "stardust dragon"
        let fromSearch = try await store.printings(game: "yu-gi-oh", cardKeys: [key])[key] ?? []
        let fromPage = try await store.printings(game: "yu-gi-oh", cardKey: key)
        #expect(fromSearch.first?.productID == 20)                         // the newest, untyped, is the cover
        let none: (String) -> String? = { _ in nil }
        let format = yugioh.format("standard")
        let searchCard = DeckCardToAdd(cardKey: key, name: "Stardust Dragon",
                                       kind: CardKinds.deckKind(game: yugioh, printings: fromSearch, ygoType: none))
        let pageCard = DeckCardToAdd(cardKey: key, name: "Stardust Dragon",
                                     kind: CardKinds.deckKind(game: yugioh, printings: fromPage, ygoType: none))
        #expect(DeckPage.addSection(game: yugioh, format: format, kind: searchCard.kind) == "extra")
        #expect(DeckPage.addingOne(deck([], format: "standard"), searchCard, game: yugioh)
                == DeckPage.addingOne(deck([], format: "standard"), pageCard, game: yugioh))
    }

    // MARK: A deck card's printing (phase 3A feedback 1, A18)

    /// A card page's "Add to deck" saves the page's printing on a new line only; a search cell's card has none to save.
    /// A card page's "New Deck…" saves it on the new deck's one card.
    @Test func aCardPageSavesItsPrintingOnANewLine() {
        let kind = CardKind(group: "Monsters", flags: [])
        let page = DeckCardToAdd(cardKey: "twin", name: "Twin", kind: kind, productID: 719834)
        let search = DeckCardToAdd(cardKey: "twin", name: "Twin", kind: kind)
        #expect(search.productID == nil)
        let added = DeckPage.addingOne(deck([]), page, game: yugioh)
        #expect(added.cards == [DeckCard(cardKey: "twin", name: "Twin", section: "main", count: 1, productID: 719834)])
        let again = DeckPage.addingOne(added, DeckCardToAdd(cardKey: "twin", name: "Twin", kind: kind, productID: 5), game: yugioh)
        #expect(again.cards == [DeckCard(cardKey: "twin", name: "Twin", section: "main", count: 2, productID: 719834)])
        #expect(DeckPage.addingOne(deck([]), search, game: yugioh).cards.map(\.productID) == [nil])
        #expect(DeckPage.newDeckCards(page, format: "standard", game: yugioh).map(\.productID) == [719834])
        #expect(DeckPage.newDeckCards(search, format: "standard", game: yugioh).map(\.productID) == [nil])
    }

    /// Fix round 2: the printing button applies what it said at render, and only while the line's stored printing is still
    /// what it was then; a double click across a re-render does nothing the second time.
    @Test func thePrintingButtonAppliesWhatItSaid() {
        let use = DeckPage.printingChoice(stored: nil, page: 7)
        #expect(use.title == "Use this printing" && use.target == 7)
        #expect(DeckPage.printingToApply(use, current: nil) == .some(7))
        #expect(DeckPage.printingToApply(use, current: 7) == nil)            // changed since: nothing
        let any = DeckPage.printingChoice(stored: 7, page: 7)
        #expect(any.title == "Any printing" && any.target == nil)
        #expect(DeckPage.printingToApply(any, current: 7) == .some(nil))
        #expect(DeckPage.printingToApply(any, current: nil) == nil)
        let move = DeckPage.printingChoice(stored: 3, page: 7)
        #expect(move.title == "Use this printing")
        #expect(DeckPage.printingToApply(move, current: 3) == .some(7))
        #expect(DeckPage.printingToApply(move, current: 5) == nil)
    }

    /// The card page's deck lines carry each line's stored printing, for "Use this printing" / "Any printing".
    @Test func theCardPagesDeckLinesCarryTheirPrinting() {
        let held = Deck(id: "a", name: "Wind", format: "standard", active: false,
                        cards: [DeckCard(cardKey: "twin", name: "Twin", section: "main", count: 2, productID: 7),
                                DeckCard(cardKey: "twin", name: "Twin", section: "side", count: 1)])
        #expect(DeckPage.cardLines(decks: [held], cardKey: "twin", game: yugioh).map(\.productID) == [7, nil])
    }

    /// The read counts the copies owned per printing (over its finishes) of the deck's cards, for the shown printing.
    @Test func theReadCountsTheCopiesOwnedPerPrinting() {
        let rows = [CollectionRow(productID: 721337, finish: "Normal", count: 2, condition: "", name: "Kai'Sa, Rebel"),
                    CollectionRow(productID: 721337, finish: "Foil", count: 1, condition: "", name: "Kai'Sa, Rebel"),
                    CollectionRow(productID: 999, finish: "Normal", count: 5, condition: "", name: "Other")]
        let made = DeckPage.read(game: riftbound, printings: ["kai sa rebel": [kaisa], "calm rune": [rune]],
                                 keys: ["kai sa rebel", "calm rune"], rows: rows, ygoType: { _ in nil })
        #expect(made.ownedByPrinting == [721337: 3])
    }

    /// The page shows the stored printing, else the one owned, and its own price; the cell's text says that price.
    @Test func thePageShowsTheChosenOrOwnedPrinting() {
        let first = product(id: 1, game: "yu-gi-oh", name: "Twin"), second = product(id: 2, game: "yu-gi-oh", name: "Twin")
        let rows = [CollectionRow(productID: 2, finish: "Normal", count: 1, condition: "", name: "Twin")]
        let read = DeckPage.read(game: yugioh, printings: ["twin": [first, second]], keys: ["twin"], rows: rows,
                                 ygoType: { _ in nil })
        let prices: [Int: ShownPrice] = [1: ShownPrice(amount: 1, isLow: false), 2: ShownPrice(amount: 3, isLow: false)]
        let price: ([ProductRecord]) -> ShownPrice? = { list in list.compactMap { prices[$0.productID] }.min { $0.amount < $1.amount } }
        func shownLine(_ card: DeckCard) -> DeckLine? {
            DeckPage.content(deck([card]), game: yugioh, read: read, available: read.ownedByCard, joinFailed: false, catalogHasProducts: true,
                             catalogSettled: true, price: price).sections.flatMap { $0.groups.flatMap(\.lines) }.first
        }
        let owned = shownLine(DeckCard(cardKey: "twin", name: "Twin", section: "main", count: 1))
        #expect(owned?.shown?.productID == 2)
        #expect(owned.map(DeckPage.accessibilityText) == "Twin, ×1, $3.00")
        let chosen = shownLine(DeckCard(cardKey: "twin", name: "Twin", section: "main", count: 1, productID: 1))
        #expect(chosen?.shown?.productID == 1)
        #expect(chosen.map(DeckPage.accessibilityText) == "Twin, ×1, $1.00")
    }

    // MARK: Sharing between decks (E4, E6)

    private func named(_ id: String, _ cards: [DeckCard], active: Bool = true) -> Deck {
        Deck(id: id, name: id, format: "standard", active: active, cards: cards)
    }

    /// The deck page's text of the deck's one Kai'Sa line, with the copies available to it among `decks`.
    private func kaisaText(_ deck: Deck, decks: [Deck], sharing: [String: Bool], read: DeckRead) throws -> String {
        let needs = DeckPage.needs(decks: decks, sharing: sharing, read: read)
        let content = DeckPage.content(deck, game: riftbound, read: read,
                                       available: DeckPage.available(to: deck, needs: needs, read: read), joinFailed: false,
                                       catalogHasProducts: true, catalogSettled: true, price: none)
        return DeckPage.countText(try #require(content.sections.flatMap { $0.groups.flatMap(\.lines) }.first))
    }

    private func sidebar(_ deck: Deck, decks: [Deck], sharing: [String: Bool], read: DeckRead) -> String? {
        let needs = DeckPage.needs(decks: decks, sharing: sharing, read: read)
        return DeckPage.sidebarCount(deck, read: read, available: DeckPage.available(to: deck, needs: needs, read: read))
    }

    /// E4: two active decks use a card ×2 and 2 are owned. Without an answer the decks are served in deck order: the first
    /// gets both copies, the second misses 2 (its page and its sidebar row say so). Shared: neither misses any. A deck that
    /// is not active counts all owned copies and has no sidebar count. Another deck order swaps the numbers.
    @Test func decksAreServedInDeckOrder() throws {
        let read = read(["kai sa rebel"], owned: ["kai sa rebel": 2])
        let first = named("Wind", [card("kai sa rebel", "main", 2)]), second = named("Cheap", [card("kai sa rebel", "main", 2)])
        let both = [first, second]
        #expect(try kaisaText(first, decks: both, sharing: [:], read: read) == "×2")
        #expect(try kaisaText(second, decks: both, sharing: [:], read: read) == "×2 · 2 missing")
        #expect(sidebar(first, decks: both, sharing: [:], read: read) == nil)
        #expect(sidebar(second, decks: both, sharing: [:], read: read) == "2")

        let shared = ["kai sa rebel": true]
        #expect(try kaisaText(first, decks: both, sharing: shared, read: read) == "×2")
        #expect(try kaisaText(second, decks: both, sharing: shared, read: read) == "×2")
        #expect(sidebar(second, decks: both, sharing: shared, read: read) == nil)

        // "Buy more" is served in deck order too.
        #expect(try kaisaText(second, decks: both, sharing: ["kai sa rebel": false], read: read) == "×2 · 2 missing")

        var idle = second
        idle.active = false
        #expect(try kaisaText(idle, decks: [first, idle], sharing: [:], read: read) == "×2")
        #expect(sidebar(idle, decks: [first, idle], sharing: [:], read: read) == nil)
        #expect(sidebar(first, decks: [first, idle], sharing: [:], read: read) == nil)

        let swapped = [second, first]
        #expect(try kaisaText(second, decks: swapped, sharing: [:], read: read) == "×2")
        #expect(try kaisaText(first, decks: swapped, sharing: [:], read: read) == "×2 · 2 missing")
        #expect(sidebar(second, decks: swapped, sharing: [:], read: read) == nil)
        #expect(sidebar(first, decks: swapped, sharing: [:], read: read) == "2")
    }

    /// A deck page's read covers only its own cards: a card it did not read counts 0 owned and is not basic (the page
    /// shows it pending, never missing); a basic card is never missing, whatever the other decks use.
    @Test func aCardTheReadDoesNotCoverCountsNoOwnedCopies() throws {
        let read = read(["calm rune"])
        let first = named("Wind", [card("calm rune", "runes", 12), card("new card", "main", 2)])
        let second = named("Cheap", [card("calm rune", "runes", 12), card("new card", "main", 2)])
        let needs = DeckPage.needs(decks: [first, second], sharing: [:], read: read)
        #expect(needs["new card"]?.owned == 0 && needs["new card"]?.isBasic == false)
        #expect(needs["calm rune"]?.isBasic == true && needs["calm rune"]?.pending == false)
        let available = DeckPage.available(to: second, needs: needs, read: read)
        #expect(available == ["calm rune": 12, "new card": 0])
        #expect(DeckPage.sidebarCount(second, read: read, available: available) == nil)
        // The page line of the card the read does not cover says its count only, never "missing".
        let content = DeckPage.content(second, game: riftbound, read: read, available: available, joinFailed: false,
                                       catalogHasProducts: true, catalogSettled: true, price: none)
        let newCard = try #require(content.sections.flatMap { $0.groups.flatMap(\.lines) }.first { $0.card.cardKey == "new card" })
        #expect(DeckPage.countText(newCard) == "×2")
    }

    /// Review Focus 4 on the deck page and the sidebar: a basic card (a rune) in three active decks with none owned: no
    /// "missing" on any page line, no sidebar count for any of the three decks.
    @Test func aBasicCardInThreeDecksIsNeverMissing() throws {
        let read = read(["calm rune"])
        let decks = ["Wind", "Cheap", "Third"].map { named($0, [card("calm rune", "runes", 6)]) }
        let needs = DeckPage.needs(decks: decks, sharing: [:], read: read)
        #expect(needs["calm rune"]?.pending == false && needs["calm rune"]?.fromDecks == 0)
        for deck in decks {
            let available = DeckPage.available(to: deck, needs: needs, read: read)
            let content = DeckPage.content(deck, game: riftbound, read: read, available: available, joinFailed: false,
                                           catalogHasProducts: true, catalogSettled: true, price: none)
            let lines = content.sections.flatMap { $0.groups.flatMap(\.lines) }
            #expect(lines.map(DeckPage.countText) == ["×6"])
            #expect(DeckPage.sidebarCount(deck, read: read, available: available) == nil)
        }
        #expect(DeckPage.pendingCount(decks: decks, sharing: [:], read: read) == 0)
    }

    /// E6: a drag's destination (an offset in the list before the move, `onMove`) as the index after the removal
    /// (`UserLibrary.moveDeck(to:)`).
    @Test func aDragsDestinationIsTheIndexAfterTheRemoval() {
        #expect(DeckPage.moveIndex(from: 1, to: 0) == 0)      // the second above the first
        #expect(DeckPage.moveIndex(from: 0, to: 2) == 1)      // the first below the second
        #expect(DeckPage.moveIndex(from: 0, to: 3) == 2)
        #expect(DeckPage.moveIndex(from: 2, to: 1) == 1)
        #expect(DeckPage.moveIndex(from: 1, to: 1) == 1)      // dropped where it was
        #expect(DeckPage.moveIndex(from: 1, to: 2) == 1)
    }

    /// E6: "Move Up" / "Move Down" give the deck's index one step up or down in the deck order; nil at the ends (the item is
    /// off) and for a deck that is not there.
    @Test func moveUpAndDownStopAtTheEnds() {
        let decks = [named("a", []), named("b", []), named("c", [])]
        #expect(DeckPage.movedIndex(of: "b", in: decks, by: -1) == 0)
        #expect(DeckPage.movedIndex(of: "b", in: decks, by: 1) == 2)
        #expect(DeckPage.movedIndex(of: "a", in: decks, by: -1) == nil)
        #expect(DeckPage.movedIndex(of: "c", in: decks, by: 1) == nil)
        #expect(DeckPage.movedIndex(of: "gone", in: decks, by: 1) == nil)
        #expect(DeckPage.movedIndex(of: "a", in: [named("a", [])], by: 1) == nil)
    }

    /// E7: the card page's sharing line: pending, the stored answer, or none (fewer than 2 active users, a basic card, no
    /// need).
    @Test func theCardPagesSharingLine() throws {
        func need(_ decks: [Deck], sharing: [String: Bool] = [:], owned: Int = 2, basic: Bool = false) -> CardNeed? {
            DeckNeeds.needs(decks: decks, sharing: sharing, owned: { _ in owned }, isBasic: { _ in basic })["x"]
        }
        let two = [named("a", [card("x", "main", 2)]), named("b", [card("x", "main", 2)])]
        #expect(DeckPage.sharingLine(need(two)) == .pending)
        #expect(DeckPage.sharingLine(need(two, sharing: ["x": true])) == .shared)
        #expect(DeckPage.sharingLine(need(two, sharing: ["x": false])) == .each)
        // An answer stays visible (and can be changed) when the card is not in conflict any more.
        #expect(DeckPage.sharingLine(need(two, sharing: ["x": false], owned: 9)) == .each)
        #expect(DeckPage.sharingLine(need([named("a", [card("x", "main", 2)])])) == nil)
        #expect(DeckPage.sharingLine(need([named("a", [card("x", "main", 2)]),
                                           named("b", [card("x", "main", 2)], active: false)])) == nil)
        #expect(DeckPage.sharingLine(need(two, basic: true)) == nil)
        #expect(DeckPage.sharingLine(nil) == nil)
        #expect(SharingLine.pending.text == "Decision pending")
        #expect(SharingLine.shared.text == "Shared between decks")
        #expect(SharingLine.each.text == "Bought for each deck")
    }

    /// E8's count: the pending cards among those the sidebar's read covers; nil without a read (owned copies unknown).
    @Test func thePendingCountCountsOnlyCardsTheReadCovers() {
        let decks = [named("a", [card("kai sa rebel", "main", 2), card("dockside lock up", "main", 2)]),
                     named("b", [card("kai sa rebel", "main", 2), card("dockside lock up", "main", 2)])]
        #expect(DeckPage.pendingCount(decks: decks, sharing: [:], read: nil) == nil)
        #expect(DeckPage.pendingCount(decks: decks, sharing: [:], read: read(["kai sa rebel"], owned: ["kai sa rebel": 1])) == 1)
        #expect(DeckPage.pendingCount(decks: decks, sharing: [:],
                                      read: read(["kai sa rebel", "dockside lock up"], owned: ["kai sa rebel": 1])) == 2)
        #expect(DeckPage.pendingCount(decks: decks, sharing: ["kai sa rebel": true],
                                      read: read(["kai sa rebel", "dockside lock up"], owned: ["kai sa rebel": 1])) == 1)
    }

    /// Final fix A3: a card the read looked up but has no printing of (the owner's rows of it point at products the read
    /// lacks), used by two active decks: its owned copies cannot be known, so it is never counted as pending.
    @Test func aCardWithoutAPrintingIsNeverCountedAsPending() {
        let decks = [named("a", [card("ghost", "main", 2)]), named("b", [card("ghost", "main", 2)])]
        #expect(DeckPage.pendingCount(decks: decks, sharing: [:], read: read(["ghost"])) == 0)
        #expect(DeckPage.pendingCount(decks: decks, sharing: [:], read: read(["ghost", "kai sa rebel"])) == 0)
    }
}
