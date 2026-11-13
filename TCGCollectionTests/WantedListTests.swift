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
        WantedList.cards(wanted, printings: ["twin": twin, "other card": other],
                         price: WantedList.price(try table(), game: "riftbound"), ownedByCard: ownedByCard)
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
        // A pinned finish without a price: no price, though the printing and the card have one.
        let none = try #require(try cards([entry(pin: PrintingKey(productID: 3, finish: "Foil"))]).first)
        #expect(none.shown?.productID == 3 && none.price == nil && none.showsPin)
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
        let card = WantedList.cards([entry()], printings: ["twin": twin], price: { _, _ in nil }, ownedByCard: [:])
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
        WantedList.content(wanted, rows: [], read: read, joinFailed: failed, catalogHasProducts: hasProducts,
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
}
