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

    private func line(count: Int, missing: Int, isBasic: Bool = false) -> DeckLine {
        DeckLine(card: card("kai sa rebel", "main", count), shown: kaisa, kind: nil, isBasic: isBasic, owned: count - missing,
                 missing: missing, price: nil)
    }

    // MARK: The sidebar

    /// A14, D7: an active deck shows its missing copies as a number; one that misses nothing, one that is not active, and
    /// one whose catalog read is not there yet show none.
    @Test func theSidebarCountIsForActiveDecksWithMissingCopies() {
        let three = read(["kai sa rebel", "dockside lock up"], owned: ["kai sa rebel": 2])
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 2)]), read: three) == nil)        // 0 missing
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3)]), read: three) == "1")
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3), card("dockside lock up", "main", 3),
                                            card("dockside lock up", "sideboard", 3)]), read: three) == "7")
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3)], active: false), read: three) == nil)
        #expect(DeckPage.sidebarCount(deck([card("kai sa rebel", "main", 3)]), read: nil) == nil)
        // A basic rune is never missing, a card the catalog lacks is not counted.
        #expect(DeckPage.sidebarCount(deck([card("calm rune", "runes", 12), card("gone", "main", 3)]),
                                      read: read(["calm rune", "gone"])) == nil)
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
        let listed = DeckPage.content(full, game: riftbound, read: read(["kai sa rebel"]), joinFailed: false,
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
        let legend = DeckSectionView(section: format.sections[0], count: 0, groups: [], warning: "1 card")
        #expect(DeckPage.warning(legend, deckHasCards: false) == nil)
        #expect(DeckPage.warning(legend, deckHasCards: true) == "1 card")
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
        let during = DeckPage.content(live, game: riftbound, read: joined, joinFailed: false, catalogHasProducts: true,
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
        #expect(!during.settled)

        let settled = DeckPage.content(live, game: riftbound, read: joined, joinFailed: false, catalogHasProducts: true,
                                       catalogSettled: true, price: none)
        #expect(settled.note == nil && settled.settled)
        #expect(settled.uncovered == ["new card"])
        #expect(DeckMaths.totals(settled.sections) == "20 cards · 1 missing · 1 without a price")

        // No product of the game: the cards alone, under their saved names.
        let alone = DeckPage.content(live, game: riftbound, read: nil, joinFailed: false, catalogHasProducts: false,
                                     catalogSettled: true, price: none)
        #expect(alone.note == CollectionList.catalogEmpty)
        #expect(alone.sections.flatMap { $0.groups.flatMap(\.lines) }.allSatisfy { $0.shown == nil && $0.missing == 0 })
        // A failed join keeps what it read before.
        let failed = DeckPage.content(live, game: riftbound, read: joined, joinFailed: true, catalogHasProducts: true,
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
                                       joinFailed: false, catalogHasProducts: true, catalogSettled: true, price: none)
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
        memory.keep(game: "cyberpunk")
        #expect(memory.state(game: "riftbound", deck: "a") !== a)
        #expect(memory.state(game: "cyberpunk", deck: "a") !== memory.state(game: "riftbound", deck: "a"))
    }

    /// The muted line under the sidebar's decks: nothing for 0, then "1 deck cannot be read." / "2 decks cannot be read.".
    @Test func theUnreadableDecksLine() {
        #expect(DeckPage.unreadableText(0) == nil)
        #expect(DeckPage.unreadableText(1) == "1 deck cannot be read.")
        #expect(DeckPage.unreadableText(2) == "2 decks cannot be read.")
    }
}
