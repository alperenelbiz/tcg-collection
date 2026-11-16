import Foundation
import Testing
@testable import TCGCollection2

@MainActor
struct WantedListTests {
    /// Three printings of the card "Twin", newest set first as the store gives them (`CatalogStore.printings`).
    private let twin = [product(id: 1, groupID: 10, name: "Twin"), product(id: 2, groupID: 11, name: "Twin (Showcase)"),
                        product(id: 3, groupID: 12, name: "Twin")]
    /// Another card of one printing.
    private let other = [product(id: 7, groupID: 10, name: "Other Card")]
    private let setNames = [10: "Set A", 11: "Set B", 12: "Set C"]

    /// The price table: Twin 1 Normal $4.00; Twin 2 Normal $1.50 and Foil $9.00; Twin 3 Normal only a low ~$0.50 (a market
    /// price is cheaper than any low one, C12); Other Card Normal $10.20.
    private func table() throws -> PriceTable {
        let table = PriceTable()
        let prices = GamePrices(day: "2026-01-02", finishes: ["Normal", "Foil"], rows: [
            1: [0: Price(market: 4, low: 3, mid: nil, high: nil)],
            2: [0: Price(market: 1.5, low: 1, mid: nil, high: nil), 1: Price(market: 9, low: 8, mid: nil, high: nil)],
            3: [0: Price(market: nil, low: 0.5, mid: nil, high: nil)],
            7: [0: Price(market: 10.2, low: nil, mid: nil, high: nil)],
        ])
        try table.replace("riftbound", with: prices, paths: AppPaths(root: tempRoot()))
        return table
    }

    private func entry(_ key: String = "twin", name: String = "Twin", count: Int = 1, pin: PrintingKey? = nil) -> WantedEntry {
        WantedEntry(cardKey: key, name: name, count: count, pinProductID: pin?.productID, pinFinish: pin?.finish)
    }

    private func cards(_ wanted: [WantedEntry], ownedByCard: [String: Int] = [:]) throws -> [WantedCard] {
        WantedList.cards(wanted, needs: [:], printings: ["twin": twin, "other card": other], ownedByCard: ownedByCard,
                         price: WantedList.price(try table(), game: "riftbound"))
    }

    /// No pin: the card shows its cheapest printing (market prices first) and that price (C12).
    @Test func aCardWithoutAPinShowsItsCheapestPrinting() throws {
        let card = try #require(try cards([entry(count: 2)]).first)
        #expect(card.shown?.productID == 2)
        #expect(card.price == ShownPrice(amount: 1.5, isLow: false))
        #expect(card.name == "Twin" && card.id == "twin" && card.entry.count == 2)
        #expect(!card.showsPin)
    }

    /// A pin shows that printing and the price of the pinned finish, not the printing's cheapest finish nor the card's.
    @Test func aPinShowsThatPrintingAndThatFinishsPrice() throws {
        let foil = try #require(try cards([entry(pin: PrintingKey(productID: 2, finish: "Foil"))]).first)
        #expect(foil.shown?.productID == 2 && foil.price == ShownPrice(amount: 9, isLow: false) && foil.showsPin)
        let first = try #require(try cards([entry(pin: PrintingKey(productID: 1, finish: "Normal"))]).first)
        #expect(first.shown?.productID == 1 && first.price == ShownPrice(amount: 4, isLow: false))
        let low = try #require(try cards([entry(pin: PrintingKey(productID: 3, finish: "Normal"))]).first)
        #expect(low.shown?.productID == 3 && low.price == ShownPrice(amount: 0.5, isLow: true))
    }

    /// Final fix B4 (C12: the price is that printing's): a pinned finish without a price, on a printing with prices in
    /// other finishes, takes that printing's cheapest finish, not the card's cheapest; the pin stays as it is. A pinned
    /// printing without any price has none.
    @Test func aPinnedFinishWithoutAPriceTakesThatPrintingsCheapestFinish() throws {
        let foil = PrintingKey(productID: 1, finish: "Foil")              // Twin 1 has only Normal $4.00
        let card = try #require(try cards([entry(pin: foil)]).first)
        #expect(card.shown?.productID == 1 && card.showsPin)
        #expect(card.price == ShownPrice(amount: 4, isLow: false))       // not the card's cheapest, $1.50
        #expect(card.entry.pin == foil)
        let lowOnly = try #require(try cards([entry(pin: PrintingKey(productID: 3, finish: "Foil"))]).first)
        #expect(lowOnly.price == ShownPrice(amount: 0.5, isLow: true))
        let unpriced = [product(id: 4, groupID: 13, name: "Twin")]
        let none = WantedList.cards([entry(pin: PrintingKey(productID: 4, finish: "Foil"))], needs: [:],
                                    printings: ["twin": twin + unpriced], ownedByCard: [:],
                                    price: WantedList.price(try table(), game: "riftbound"))
        #expect(none.map(\.shown?.productID) == [4] && none.map(\.price) == [nil])
    }

    /// A pin whose product left the catalog: the card falls back to its cheapest printing and price; the entry keeps its
    /// pin (nothing is removed without the user's own action).
    @Test func aPinThatLeftTheCatalogFallsBackAndIsKept() throws {
        let gone = PrintingKey(productID: 99, finish: "Normal")
        let card = try #require(try cards([entry(pin: gone)]).first)
        #expect(card.shown?.productID == 2 && card.price == ShownPrice(amount: 1.5, isLow: false))
        #expect(card.entry.pin == gone && !card.showsPin)
    }

    /// Review Focus 4: a card key with no printing (the card left the catalog, a rule renamed it) has no printing, no
    /// price and its saved name; with no saved name, its key.
    @Test func aCardWithNoPrintingKeepsItsSavedName() throws {
        let list = try cards([entry("gone card", name: "Gone Card", count: 3), entry("lost", name: "")])
        #expect(list.map(\.shown) == [nil, nil] && list.map(\.price) == [nil, nil])
        #expect(list.map(\.name) == ["Gone Card", "lost"])
        #expect(list[0].entry.count == 3 && list[0].owned == 0)
    }

    /// No printing has a price: the newest printing (the card page's first) is shown, with no price.
    @Test func withNoPriceTheNewestPrintingIsShown() {
        let card = WantedList.cards([entry()], needs: [:], printings: ["twin": twin], ownedByCard: [:], price: { _, _ in nil })
        #expect(card.map(\.shown?.productID) == [1] && card.map(\.price) == [nil])
    }

    /// `owned` is the card's copies over all its collection rows (every printing and finish); a row of another card or
    /// of a product the catalog does not have does not count. C5: it never lowers the wanted count.
    @Test func ownedIsTheCardsCopiesOverAllItsRows() throws {
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 2, condition: "", name: "Twin"),
                    CollectionRow(productID: 2, finish: "Foil", count: 1, condition: "", name: "Twin (Showcase)"),
                    CollectionRow(productID: 2, finish: "Normal", count: 1, condition: "", name: "Twin (Showcase)"),
                    CollectionRow(productID: 50, finish: "Normal", count: 3, condition: "", name: "Gone Card")]
        let owned = WantedList.ownedByCard(rows: rows, printings: ["twin": twin, "other card": other])
        #expect(owned == ["twin": 4])
        let list = try cards([entry(count: 2), entry("other card", name: "Other Card")], ownedByCard: owned)
        #expect(list.map(\.owned) == [4, 0])
        #expect(list.map(\.entry.count) == [2, 1])
    }

    private func card(_ key: String, count: Int, price: Double?, isLow: Bool = false) -> WantedCard {
        WantedCard(entry: entry(key, name: key.capitalized, count: count), shown: nil,
                   price: price.map { ShownPrice(amount: $0, isLow: isLow) }, owned: 0)
    }

    /// Name: by card key. Price high to low and low to high: cards without a price last, ties by name. Copies: the wanted
    /// count, high to low, ties by name.
    @Test func sortOrders() {
        let list = [card("delta", count: 1, price: 2), card("alpha", count: 3, price: nil), card("charlie", count: 1, price: 5),
                    card("bravo", count: 3, price: 2)]
        #expect(WantedList.sorted(list, by: .name).map(\.id) == ["alpha", "bravo", "charlie", "delta"])
        #expect(WantedList.sorted(list, by: .priceHigh).map(\.id) == ["charlie", "bravo", "delta", "alpha"])
        #expect(WantedList.sorted(list, by: .priceLow).map(\.id) == ["bravo", "delta", "charlie", "alpha"])
        #expect(WantedList.sorted(list, by: .count).map(\.id) == ["alpha", "bravo", "charlie", "delta"])
    }

    /// The search matches every folded word in the card's key (the catalog's rule), or for a card without a printing in
    /// its saved name.
    @Test func searchMatchesEveryWord() throws {
        let list = try cards([entry(), entry("other card", name: "Other Card"), entry("gone card", name: "Gone Cärd")])
        #expect(WantedList.filtered(list, text: "card").map(\.id) == ["other card", "gone card"])
        #expect(WantedList.filtered(list, text: "CARD gone").map(\.id) == ["gone card"])
        #expect(WantedList.filtered(list, text: "  ").map(\.id) == ["twin", "other card", "gone card"])
        #expect(WantedList.filtered(list, text: "twin other").isEmpty)
    }

    /// `5 copies · 3 cards · $18.20`: the copies, the cards and the summed price of the copies (price × count; a low
    /// price counts as its amount). Cards without a price are left out of the sum and counted after it, as on For Sale.
    /// While the search text is on, the shown part of the whole list. An empty list says nothing.
    @Test func totals() {
        #expect(WantedList.totals([]) == "")
        #expect(WantedList.totals([card("a", count: 2, price: 4), card("b", count: 1, price: 7.2), card("c", count: 2, price: 1.5)])
                == "5 copies · 3 cards · $18.20")
        #expect(WantedList.totals([card("a", count: 1, price: 4)]) == "1 copy · 1 card · $4.00")
        #expect(WantedList.totals([card("a", count: 2, price: 4), card("b", count: 1, price: nil)])
                == "3 copies · 2 cards · $8.00 + 1 without a price")
        #expect(WantedList.totals([card("a", count: 1, price: 0.5, isLow: true)]) == "1 copy · 1 card · $0.50")
        #expect(WantedList.totals([card("a", count: 1, price: nil), card("b", count: 2, price: nil)])
                == "3 copies · 2 cards · 2 without a price")
        let all = [card("a", count: 2, price: 4), card("b", count: 1, price: nil)]
        #expect(WantedList.totals([all[0]], of: all) == "2 of 3 copies · 1 of 2 cards · $8.00")
        #expect(WantedList.totals([], of: all) == "0 of 3 copies · 0 of 2 cards")
        #expect(WantedList.totals([], of: []) == "")
    }

    private func read(_ printings: [String: [ProductRecord]], keys: Set<String>) -> WantedRead {
        WantedRead(printings: printings, keys: keys, setNames: setNames)
    }

    private func content(_ wanted: [WantedEntry], read: WantedRead?, failed: Bool = false, hasProducts: Bool = true,
                         settled: Bool) throws -> WantedContent {
        WantedList.content(wanted, decks: [], sharing: [:], read: read, joinFailed: failed, catalogHasProducts: hasProducts,
                           catalogSettled: settled, price: WantedList.price(try table(), game: "riftbound"))
    }

    /// Wanted follows the catalog as the Collection does: the cards alone (saved names, no price) while the catalog has no
    /// product of the game; during a download a card without a printing is pending, with the downloading line; on a
    /// settled catalog it has left the catalog. A card the join did not look up (added since) is pending until the next
    /// join. A failed join keeps what the last one read, or lists the cards alone.
    @Test func wantedFollowsTheCatalogStates() throws {
        let wanted = [entry(count: 2), entry("gone card", name: "Gone Card")]
        let alone = try content(wanted, read: nil, hasProducts: false, settled: false)
        #expect(alone.cards.map(\.shown) == [nil, nil] && alone.cards.map(\.name) == ["Twin", "Gone Card"])
        #expect(alone.note == CollectionList.catalogDownloading && alone.cards.allSatisfy { alone.link(for: $0) == .none })
        #expect(try content(wanted, read: nil, hasProducts: false, settled: true).note == CollectionList.catalogEmpty)

        let both: Set<String> = ["twin", "gone card"]
        let during = try content(wanted, read: read(["twin": twin], keys: both), settled: false)
        #expect(during.cards.map(\.shown?.productID) == [2, nil])
        #expect(during.note == CollectionList.catalogDownloading)
        #expect(during.cards.map { during.link(for: $0) } == [.card, .none])

        let settled = try content(wanted, read: read(["twin": twin], keys: both), settled: true)
        #expect(settled.note == nil)
        #expect(settled.cards.map { settled.link(for: $0) } == [.card, .unknownCard])

        // "gone card" was added after the join: pending, also on a settled catalog.
        let uncovered = try content(wanted, read: read(["twin": twin], keys: ["twin"]), settled: true)
        #expect(uncovered.cards.map { uncovered.link(for: $0) } == [.card, .none] && uncovered.uncovered == ["gone card"])

        let kept = try content(wanted, read: read(["twin": twin], keys: both), failed: true, settled: true)
        #expect(kept.note == CollectionList.catalogUnreadableKept && kept.cards.map(\.shown?.productID) == [2, nil])
        #expect(kept.cards.map { kept.link(for: $0) } == [.card, .none])
        let unread = try content(wanted, read: nil, failed: true, settled: true)
        #expect(unread.note == CollectionList.catalogUnreadable && unread.cards.allSatisfy { $0.shown == nil })
        #expect(try content([], read: read([:], keys: []), settled: true).cards.isEmpty)
    }

    /// Fix round 1: `owned` comes from the join's read (counted once per join), not from the rows on every render; with no
    /// read it is 0.
    @Test func ownedComesFromTheRead() throws {
        var joined = read(["twin": twin], keys: ["twin"])
        joined.ownedByCard = ["twin": 4]
        #expect(try content([entry()], read: joined, settled: true).cards.map(\.owned) == [4])
        #expect(try content([entry()], read: nil, hasProducts: false, settled: true).cards.map(\.owned) == [0])
    }

    /// The cell's count line: `×2`; with a pin that is shown, `×1 · <its set>`. A pin that fell back shows `×1` only.
    @Test func theCountLineNamesThePinnedSet() throws {
        let wanted = [entry(count: 2), entry("other card", name: "Other Card", pin: PrintingKey(productID: 7, finish: "Normal")),
                      entry("third", name: "Third", pin: PrintingKey(productID: 99, finish: "Normal"))]
        let listed = try content(wanted, read: read(["twin": twin, "other card": other, "third": [product(id: 8, groupID: 11, name: "Third")]],
                                                    keys: ["twin", "other card", "third"]), settled: true)
        #expect(listed.cards.map { listed.countText(for: $0) } == ["×2", "×1 · Set A", "×1"])
        #expect(listed.cards.map { listed.accessibilityText(for: $0) }
                == ["Twin, ×2, $1.50", "Other Card, ×1, Set A, $10.20", "Third, ×1, no price"])
    }

    // MARK: Phase 3B task 5: the decks' missing copies on Wanted (E5, A17, A23, A24)

    private func deckCard(_ key: String, _ name: String, count: Int, productID: Int? = nil) -> DeckCard {
        DeckCard(cardKey: key, name: name, section: "main", count: count, productID: productID)
    }

    private func deck(_ name: String, active: Bool = true, _ cards: [DeckCard]) -> Deck {
        Deck(id: "id-\(name)", name: name, format: "standard", active: active, cards: cards)
    }

    /// The decks' needs as the screen makes them from a read: the read's owned copies and basic cards.
    private func needs(_ decks: [Deck], owned: [String: Int] = [:], basics: Set<String> = []) -> [String: CardNeed] {
        DeckNeeds.needs(decks: decks, sharing: [:], owned: { owned[$0] ?? 0 }, isBasic: { basics.contains($0) })
    }

    private func cards(_ wanted: [WantedEntry], decks: [Deck], owned: [String: Int] = [:],
                       basics: Set<String> = []) throws -> [WantedCard] {
        WantedList.cards(wanted, needs: needs(decks, owned: owned, basics: basics),
                         printings: ["twin": twin, "other card": other], ownedByCard: owned,
                         price: WantedList.price(try table(), game: "riftbound"))
    }

    /// E5: the union of the hand-added entries and the cards the active decks miss. A hand-added Twin ×1 that the decks
    /// miss 2 of: total 3, 2 for decks. A card only from decks (Bee): an entry of count 0 made in memory with the deck
    /// card's saved name, total 3. A card the decks use but own enough of, a basic card and a card of a deck that is not
    /// active are not listed. (`cards` lists the needs it is given; `WantedList.needs` leaves out a card without a printing,
    /// final fix A3, so on the screen Bee would need a printing.)
    @Test func wantedListsTheHandAddedAndTheDecksMissingCards() throws {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 2), deckCard("bee", "Bee Card", count: 3),
                                   deckCard("enough", "Enough", count: 1), deckCard("calm rune", "Calm Rune", count: 2)]),
                     deck("Off", active: false, [deckCard("sleeper", "Sleeper", count: 4)])]
        let list = try cards([entry(count: 1)], decks: decks, owned: ["enough": 1], basics: ["calm rune"])
        #expect(list.map(\.id) == ["twin", "bee"])
        #expect(list.map(\.total) == [3, 3] && list.map(\.forDecks) == [2, 3] && list.map(\.entry.count) == [1, 0])
        #expect(list[1].name == "Bee Card" && list[1].entry.name == "Bee Card" && list[1].entry.pin == nil)
        #expect(list[1].shown == nil && list[1].price == nil)
        #expect(list.map(\.pending) == [false, false])
        #expect(list[0].users.map(\.deckName) == ["Wind"] && list[0].users.map(\.missing) == [2])
        // A hand-added card no deck uses: forDecks 0, total its count.
        let alone = try cards([entry("other card", name: "Other Card", count: 2)], decks: [])
        #expect(alone.map(\.total) == [2] && alone.map(\.forDecks) == [0] && alone.map(\.users) == [[]])
    }

    /// A pending card (two active decks, more used than owned, no answer) carries `pending`; it counts the sum (E3).
    @Test func aPendingCardIsMarked() throws {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 2)]), deck("Cheap", [deckCard("twin", "Twin", count: 2)])]
        let list = try cards([], decks: decks, owned: ["twin": 1])
        #expect(list.map(\.pending) == [true] && list.map(\.forDecks) == [3] && list.map(\.total) == [3])
    }

    /// The cell's count line: `×<total>[ · <n> for decks][ · <set>]`.
    @Test func theCountLineSaysTheDecksPart() throws {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 2), deckCard("other card", "Other Card", count: 3)])]
        let wanted = [entry(count: 1), entry("third", name: "Third", count: 1)]
        let keys: Set<String> = ["twin", "other card", "third"]
        let listed = WantedList.content(wanted, decks: decks, sharing: [:], read: read(["twin": twin, "other card": other], keys: keys),
                                        joinFailed: false, catalogHasProducts: true, catalogSettled: true,
                                        price: WantedList.price(try table(), game: "riftbound"))
        #expect(listed.cards.map { listed.countText(for: $0) } == ["×3 · 2 for decks", "×1", "×3 · 3 for decks"])
        #expect(listed.cards.map { listed.accessibilityText(for: $0) }
                == ["Twin, ×3, 2 for decks, $1.50", "Third, ×1, no price", "Other Card, ×3, 3 for decks, $10.20"])
        let pinned = WantedList.content([entry(count: 1, pin: PrintingKey(productID: 1, finish: "Normal"))], decks: decks,
                                        sharing: [:], read: read(["twin": twin, "other card": other], keys: keys),
                                        joinFailed: false, catalogHasProducts: true, catalogSettled: true,
                                        price: WantedList.price(try table(), game: "riftbound"))
        #expect(pinned.countText(for: pinned.cards[0]) == "×3 · 2 for decks · Set A")
    }

    /// A23: the pin wins; else the printing the decks that miss the card chose, when they chose exactly one, with that
    /// printing's own cheapest finish price; two chosen, or one that left the catalog: the cheapest printing.
    @Test func theShownPrintingIsThePinThenTheDecksChoice() throws {
        // The decks chose Twin 1 ($4.00); the card's cheapest is Twin 2 ($1.50).
        let chose1 = [deck("Wind", [deckCard("twin", "Twin", count: 2, productID: 1)])]
        let pin3 = try #require(try cards([entry(count: 1, pin: PrintingKey(productID: 3, finish: "Normal"))], decks: chose1).first)
        #expect(pin3.shown?.productID == 3 && pin3.price == ShownPrice(amount: 0.5, isLow: true) && pin3.showsPin)
        let decksChoice = try #require(try cards([], decks: chose1).first)
        #expect(decksChoice.shown?.productID == 1 && decksChoice.price == ShownPrice(amount: 4, isLow: false))
        #expect(!decksChoice.showsPin)
        // A hand entry without a pin takes the decks' choice too.
        let handToo = try #require(try cards([entry(count: 1)], decks: chose1).first)
        #expect(handToo.shown?.productID == 1 && handToo.price == ShownPrice(amount: 4, isLow: false))
        // A hand entry whose decks chose a printing but miss nothing (2 owned of 2 used): the cheapest, not the decks'.
        let complete = try #require(try cards([entry(count: 1)], decks: chose1, owned: ["twin": 2]).first)
        #expect(complete.forDecks == 0)
        #expect(complete.shown?.productID == 2 && complete.price == ShownPrice(amount: 1.5, isLow: false))
        // The decks' chosen printing's price is its cheapest finish: Twin 2 has Normal $1.50 and Foil $9.00.
        let chose2 = try #require(try cards([], decks: [deck("Wind", [deckCard("twin", "Twin", count: 1, productID: 2)])]).first)
        #expect(chose2.shown?.productID == 2 && chose2.price == ShownPrice(amount: 1.5, isLow: false))
        // Two decks chose two printings: the cheapest.
        let two = [deck("Wind", [deckCard("twin", "Twin", count: 1, productID: 1)]),
                   deck("Cheap", [deckCard("twin", "Twin", count: 1, productID: 3)])]
        let both = try #require(try cards([], decks: two).first)
        #expect(both.shown?.productID == 2 && both.price == ShownPrice(amount: 1.5, isLow: false))
        // The chosen printing left the catalog: the cheapest.
        let gone = try #require(try cards([], decks: [deck("Wind", [deckCard("twin", "Twin", count: 1, productID: 99)])]).first)
        #expect(gone.shown?.productID == 2 && gone.price == ShownPrice(amount: 1.5, isLow: false))
    }

    /// Totals, the copies sort and the search use the total; the price sums are price × total.
    @Test func totalsSortAndSearchUseTheTotal() throws {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 2), deckCard("other card", "Other Card", count: 3)])]
        let list = try cards([entry(count: 1)], decks: decks)
        // Twin 3 × $1.50 + Other Card 3 × $10.20.
        #expect(WantedList.totals(list) == "6 copies · 2 cards · $35.10")
        let found = WantedList.filtered(list, text: "twin")
        #expect(found.map(\.id) == ["twin"])
        #expect(WantedList.totals(found, of: list) == "3 of 6 copies · 1 of 2 cards · $4.50")
        // Copies: Twin's total 3 (hand 1) is over Other Card's hand-only 2.
        let mixed = try cards([entry(count: 1), entry("other card", name: "Other Card", count: 2)],
                              decks: [deck("Wind", [deckCard("twin", "Twin", count: 2)])])
        #expect(WantedList.sorted(mixed, by: .count).map(\.id) == ["twin", "other card"])
        #expect(WantedList.sorted(mixed, by: .name).map(\.id) == ["other card", "twin"])
        #expect(WantedList.sorted(mixed, by: .priceHigh).map(\.id) == ["other card", "twin"])
        #expect(WantedList.sorted(mixed, by: .priceLow).map(\.id) == ["twin", "other card"])
    }

    /// Final fix A3 (it replaces Review Focus 3): a deck card whose printings the read lacks adds nothing to Wanted, in
    /// every catalog state: the copies owned of it cannot be known. Not listed, not pending, not in the totals; only the
    /// cards with a printing are. A deck card the join did not look up is left out until a join covers it.
    @Test func aDeckOnlyCardFollowsTheCatalogStates() throws {
        let decks = [deck("Wind", [deckCard("bee", "Bee Card", count: 2), deckCard("twin", "Twin", count: 1)])]
        func listed(keys: Set<String>, settled: Bool) throws -> WantedContent {
            WantedList.content([], decks: decks, sharing: [:], read: read(["twin": twin], keys: keys), joinFailed: false,
                               catalogHasProducts: true, catalogSettled: settled,
                               price: WantedList.price(try table(), game: "riftbound"))
        }
        let settled = try listed(keys: ["bee", "twin"], settled: true)
        #expect(settled.cards.map(\.id) == ["twin"] && settled.note == nil)
        #expect(settled.cards.map { settled.link(for: $0) } == [.card])
        #expect(WantedList.totals(settled.cards) == "1 copy · 1 card · $1.50")
        let during = try listed(keys: ["bee", "twin"], settled: false)
        #expect(during.cards.map(\.id) == ["twin"] && during.cards.map(\.pending) == [false])
        #expect(during.cards.map { during.link(for: $0) } == [.card])
        let uncovered = try listed(keys: ["twin"], settled: true)
        #expect(uncovered.cards.map(\.id) == ["twin"])
        // With no read (no products of the game yet) no deck card is listed.
        let none = WantedList.content([], decks: decks, sharing: [:], read: nil, joinFailed: false, catalogHasProducts: false,
                                      catalogSettled: false, price: { _, _ in nil })
        #expect(none.cards.isEmpty)
    }

    /// Final fix A3: two active decks use a card without a printing (the owner's rows of it point at products the read does
    /// not have): it is not pending and not listed; a hand-added entry of such a card is listed as in phase 2C, its count
    /// line the hand part only (`×1`, no "for decks").
    @Test func aDeckCardWithoutAPrintingHasNoDecksPart() throws {
        let decks = [deck("Wind", [deckCard("bee", "Bee Card", count: 2)]), deck("Cheap", [deckCard("bee", "Bee Card", count: 2)])]
        var joined = read(["twin": twin], keys: ["bee", "twin"])
        joined.ownedByCard = ["twin": 0]
        let price = WantedList.price(try table(), game: "riftbound")
        for settled in [true, false] {
            let fromDecks = WantedList.content([], decks: decks, sharing: [:], read: joined, joinFailed: false,
                                               catalogHasProducts: true, catalogSettled: settled, price: price)
            #expect(fromDecks.cards.isEmpty)
            #expect(WantedList.needs(decks: decks, sharing: [:], read: joined)["bee"] == nil)
            let hand = WantedList.content([entry("bee", name: "Bee Card", count: 1)], decks: decks, sharing: [:], read: joined,
                                          joinFailed: false, catalogHasProducts: true, catalogSettled: settled, price: price)
            #expect(hand.cards.map(\.id) == ["bee"] && hand.cards.map(\.forDecks) == [0] && hand.cards.map(\.pending) == [false])
            #expect(hand.countText(for: hand.cards[0]) == "×1")
            #expect(hand.link(for: hand.cards[0]) == (settled ? .unknownCard : .none))
        }
    }

    /// Final fix A5: `+` on a cell of a card only from decks saves the shown printing's card name when there is a printing,
    /// else the deck card's saved name; never the card key when a real name exists.
    @Test func plusOnADeckOnlyCardSavesTheCardsName() async throws {
        let library = UserLibrary(folder: tempDir(), watcher: nil)
        await library.load()
        // The deck line saved no name: the need's name is the card key.
        let decks = [deck("Wind", [deckCard("other card", "", count: 2)])]
        let price = WantedList.price(try table(), game: "riftbound")
        let listed = WantedList.content([], decks: decks, sharing: [:], read: read(["other card": other], keys: ["other card"]),
                                        joinFailed: false, catalogHasProducts: true, catalogSettled: true, price: price)
        let card = try #require(listed.cards.first)
        WantedView.step(by: 1, card: card, game: "riftbound", library: library)
        #expect(library.wanted(game: "riftbound").map(\.name) == ["Other Card"])
        // Without a printing the deck card's saved name (a hand entry of such a card, as the cell shows it).
        let unprinted = WantedCard(entry: WantedEntry(cardKey: "bee", name: "Bee Card", count: 0), shown: nil, price: nil, owned: 0)
        WantedView.step(by: 1, card: unprinted, game: "riftbound", library: library)
        #expect(library.wanted(game: "riftbound").first { $0.cardKey == "bee" }?.name == "Bee Card")
    }

    /// Final fix A6: the card page's need runs over that card's deck lines only; the numbers equal the unfiltered call's,
    /// for a card in two of three decks.
    @Test func theCardPagesNeedEqualsTheWholeDecksNeed() {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 3), deckCard("bee", "Bee", count: 4)]),
                     deck("Cheap", [deckCard("bee", "Bee", count: 1)]),
                     deck("Third", [deckCard("twin", "Twin", count: 2), deckCard("other", "Other", count: 1)])]
        for sharing in [[:], ["twin": true], ["twin": false]] as [[String: Bool]] {
            for owned in [0, 1, 4, 6] {
                let whole = DeckNeeds.needs(decks: decks, sharing: sharing, owned: { $0 == "twin" ? owned : 0 },
                                            isBasic: { _ in false })["twin"]
                let page = WantedList.need("twin", decks: decks, sharing: sharing, owned: owned, isBasic: false)
                #expect(page == whole)
                #expect(WantedList.forDecks("twin", decks: decks, sharing: sharing, owned: owned, isBasic: false)
                        == whole?.fromDecks)
            }
        }
    }

    /// The owned copies of the read count: own enough and the card leaves the list; own 2 of 3 and 1 is for decks.
    @Test func ownedCopiesFromTheReadLowerTheDecksPart() throws {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 3)])]
        var joined = read(["twin": twin], keys: ["twin"])
        joined.ownedByCard = ["twin": 2]
        let price = WantedList.price(try table(), game: "riftbound")
        let some = WantedList.content([entry(count: 1)], decks: decks, sharing: [:], read: joined, joinFailed: false,
                                      catalogHasProducts: true, catalogSettled: true, price: price)
        #expect(some.cards.map(\.forDecks) == [1] && some.countText(for: some.cards[0]) == "×2 · 1 for decks")
        joined.ownedByCard = ["twin": 3]
        let enough = WantedList.content([], decks: decks, sharing: [:], read: joined, joinFailed: false,
                                        catalogHasProducts: true, catalogSettled: true, price: price)
        #expect(enough.cards.isEmpty)
        // A basic card of the read is never on Wanted from a deck.
        joined.ownedByCard = [:]
        joined.basics = ["twin"]
        #expect(WantedList.content([], decks: decks, sharing: [:], read: joined, joinFailed: false, catalogHasProducts: true,
                                   catalogSettled: true, price: price).cards.isEmpty)
    }

    /// The join looks up the hand-added keys and every card key of the active decks (not of a deck that is not active), and
    /// reads the basic cards once (`DeckMaths.isBasic`, the deciding printing).
    @Test func theJoinCoversTheDecksCards() throws {
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 2), deckCard("calm rune", "Calm Rune", count: 1),
                                   deckCard("zero", "Zero", count: 0)]),
                     deck("Off", active: false, [deckCard("sleeper", "Sleeper", count: 4)])]
        #expect(WantedList.joinKeys(wanted: [entry("other card", name: "Other Card")], decks: decks)
                == ["other card", "twin", "calm rune"])
        let game = try #require(Games.game("riftbound"))
        let rune = [product(id: 20, groupID: 10, name: "Calm Rune")]
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 1, condition: "", name: "Twin")]
        let joined = WantedList.read(game: game, printings: ["twin": twin, "calm rune": rune], keys: ["twin", "calm rune"],
                                     rows: rows, setNames: setNames)
        #expect(joined.basics == ["calm rune"] && joined.ownedByCard == ["twin": 1] && joined.keys == ["twin", "calm rune"])
    }

    /// A24: the cell's control is the hand-added count. `+` on a card only from decks adds a hand entry with the deck card's
    /// name; `−` from 1 to 0 on a card the decks miss removes the entry and its pin, and the card stays listed with the
    /// decks' part and the decks' printing (Review Focus 5). Nothing a deck misses is written to the file.
    @Test func theCellsControlChangesOnlyTheHandAddedPart() async throws {
        let folder = tempDir()
        let json = """
        {"version": 1, "collection": [],
         "wanted": [{"cardKey": "twin", "name": "Twin", "count": 1, "pinProductID": 1, "pinFinish": "Normal"}],
         "decks": [{"id": "rb1", "name": "Wind", "format": "standard", "active": true,
                    "cards": [{"cardKey": "twin", "name": "Twin", "section": "main", "count": 2, "productID": 3},
                              {"cardKey": "other card", "name": "Other Card", "section": "main", "count": 3}]}]}
        """
        try Data(json.utf8).write(to: folder.appending(path: "riftbound.json"))
        let library = UserLibrary(folder: folder, watcher: nil)
        await library.load()
        let price = WantedList.price(try table(), game: "riftbound")
        func listed() -> WantedContent {
            WantedList.content(library.wanted(game: "riftbound"), decks: library.decks(game: "riftbound"),
                               sharing: library.sharing(game: "riftbound"),
                               read: read(["twin": twin, "other card": other], keys: ["twin", "other card"]),
                               joinFailed: false, catalogHasProducts: true, catalogSettled: true, price: price)
        }
        let before = listed()
        #expect(before.cards.map(\.id) == ["twin", "other card"] && before.cards.map(\.entry.count) == [1, 0])
        // A render writes nothing: the wanted list and the file are as they were.
        await library.flush()
        #expect(library.wanted(game: "riftbound").map(\.cardKey) == ["twin"])
        #expect(try Data(contentsOf: folder.appending(path: "riftbound.json")) == Data(json.utf8))

        WantedView.step(by: -1, card: before.cards[0], game: "riftbound", library: library)
        let after = listed()
        #expect(library.wanted(game: "riftbound").isEmpty)
        // Both are only from decks now, by card key.
        #expect(after.cards.map(\.id) == ["other card", "twin"] && after.cards.map(\.entry.count) == [0, 0])
        let twinAfter = try #require(after.cards.last)
        #expect(twinAfter.forDecks == 2 && twinAfter.shown?.productID == 3 && !twinAfter.showsPin)
        #expect(after.countText(for: twinAfter) == "×2 · 2 for decks")

        WantedView.step(by: 1, card: after.cards[0], game: "riftbound", library: library)
        #expect(library.wanted(game: "riftbound").map(\.cardKey) == ["other card"])
        #expect(library.wanted(game: "riftbound").map(\.name) == ["Other Card"])
        #expect(library.wanted(game: "riftbound").map(\.count) == [1])
        let added = listed()
        #expect(added.cards.first { $0.id == "other card" }.map { added.countText(for: $0) } == "×4 · 3 for decks")
        await library.flush()
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "riftbound.json")))
                                as? [String: Any])
        let stored = try #require(file["wanted"] as? [[String: Any]])
        #expect(stored.count == 1 && stored[0]["cardKey"] as? String == "other card" && stored[0]["count"] as? Int == 1)
    }

    /// The card page's Wanted line: `+ <n> for decks` when the decks miss the card, nothing else; `forDecks` from the
    /// library's decks and the page's owned copies.
    @Test func theCardPageSaysTheDecksPart() {
        #expect(WantedLine.forDecksText(2) == "+ 2 for decks")
        #expect(WantedLine.forDecksText(1) == "+ 1 for decks")
        #expect(WantedLine.forDecksText(0) == nil)
        let decks = [deck("Wind", [deckCard("twin", "Twin", count: 3)]), deck("Off", active: false, [deckCard("twin", "Twin", count: 5)])]
        #expect(WantedList.forDecks("twin", decks: decks, sharing: [:], owned: 1, isBasic: false) == 2)
        #expect(WantedList.forDecks("twin", decks: decks, sharing: [:], owned: 3, isBasic: false) == 0)
        #expect(WantedList.forDecks("twin", decks: decks, sharing: [:], owned: 0, isBasic: true) == 0)
        #expect(WantedList.forDecks("other", decks: decks, sharing: [:], owned: 0, isBasic: false) == 0)
    }

    /// Final fix A3 on the card page: a card without a printing (`UnknownCardPage`) has no decks' part, whatever the active
    /// decks use: no "+ n for decks". A card with a printing keeps it.
    @Test func aCardWithoutAPrintingHasNoDecksPartOnItsPage() {
        let decks = [deck("Wind", [deckCard("bee", "Bee", count: 3)]), deck("Cheap", [deckCard("bee", "Bee", count: 2)])]
        #expect(WantedLine.decksText("bee", decks: decks, sharing: [:], owned: 0, isBasic: false, hasPrinting: false) == nil)
        #expect(WantedLine.decksText("bee", decks: decks, sharing: ["bee": true], owned: 0, isBasic: false,
                                     hasPrinting: false) == nil)
        #expect(WantedLine.decksText("bee", decks: decks, sharing: [:], owned: 1, isBasic: false, hasPrinting: true)
                == "+ 4 for decks")
    }
}
