import Testing
@testable import TCGCollection2

struct CollectionListTests {
    @Test func entriesJoinRowsWithTheCatalog() {
        let rows = [CollectionRow(productID: 1, finish: "Foil", count: 2, condition: "", name: "Old Name"),
                    .init(productID: 9, finish: "Normal", count: 1, condition: "", name: "Gone Card")]
        let e = CollectionList.entries(rows: rows, products: [1: product(id: 1, game: "riftbound", name: "Calm Rune (R02a)")],
                                       setNames: [:]) { key in key.finish == "Foil" ? ShownPrice(amount: 3, isLow: false) : nil }
        #expect(e.count == 2); #expect(e[0].product?.productID == 1 && e[0].price?.amount == 3 && e[0].copiesOfCard == 2)
        #expect(e[1].product == nil && e[1].price == nil && e[1].row.name == "Gone Card")              // Review Focus 4
    }

    /// The set name comes from the product's set; the price is asked for the printing (product and finish), so two
    /// finishes of one product get their own prices; a card's copies are summed over all its rows.
    @Test func entriesTakeEachPrintingsOwnPriceAndCountTheCard() {
        let e = entries()
        #expect(e.map(\.setName) == ["Alpha", "Alpha", "Beta", "Alpha", "Beta", ""])
        #expect(e.map { $0.price?.amount } == [0.5, 6, 25, 3, 0.5, nil])
        #expect(e[4].price?.isLow == true)
        // Calm Rune: 1 + 2 + 1 over three rows; Dockside Lock-Up: 1 + 1; the unknown product only itself.
        #expect(e.map(\.copiesOfCard) == [4, 4, 4, 2, 2, 5])
        #expect(e.map(\.id) == rows.map(\.key))
        // The shown name: the card's; an unknown product's saved name, or its id when the row has no name.
        #expect(e.map(\.name) == ["Calm Rune", "Calm Rune", "Calm Rune", "Dockside Lock-Up", "Dockside Lock-Up", "Gone Card"])
        #expect(entry(7, count: 1).name == "Product 7")
    }

    @Test func totalsLine() {
        #expect(CollectionList.totals([]) == "0 copies · 0 printings")
        // 120 copies in 74 printings: 8 of one copy, one of 4, 64 of one copy, one of 44.
        let all = (0..<8).map { entry($0, count: 1) } + [entry(8, count: 4)] + (9..<73).map { entry($0, count: 1) }
            + [entry(73, count: 44)]
        #expect(CollectionList.totals(all) == "120 copies · 74 printings")
        #expect(CollectionList.totals([entry(1, count: 1)]) == "1 copy · 1 printing")
        #expect(CollectionList.totals([entry(1, count: 3)]) == "3 copies · 1 printing")
        // A filter or search text on: the shown part of all. The noun follows the whole.
        #expect(CollectionList.totals(Array(all.prefix(9)), of: all) == "12 of 120 copies · 9 of 74 printings")
        #expect(CollectionList.totals([], of: [entry(1, count: 1)]) == "0 of 1 copy · 0 of 1 printing")
    }

    /// Six entries over two cards and one unknown product (Riftbound: a playset is 3).
    @Test func filtersAndSorts() {
        let e = entries()
        func ids(_ list: [CollectionEntry]) -> [String] { list.map { "\($0.row.productID)-\($0.row.finish)" } }
        func filtered(text: String = "", groupID: Int? = nil, rarity: String? = nil, price: PriceFilter = .any,
                      playset: CollectionRules.PlaysetFilter = .any) -> [String] {
            ids(CollectionList.filtered(e, text: text, groupID: groupID, rarity: rarity, price: price, playset: playset,
                                        playsetSize: 3))
        }
        let all = ["1-Normal", "1-Foil", "2-Normal", "3-Normal", "4-Foil", "9-Normal"]
        #expect(filtered() == all)
        #expect(filtered(text: "  ") == all)
        // Text: every folded word, in any order, against the product's search key; an unknown product by its saved name.
        #expect(filtered(text: "rune") == ["1-Normal", "1-Foil", "2-Normal"])
        #expect(filtered(text: "LOCK dock") == ["3-Normal", "4-Foil"])
        #expect(filtered(text: "gone") == ["9-Normal"])
        #expect(filtered(text: "rune lock").isEmpty)
        // Set and rarity: an unknown product has neither.
        #expect(filtered(groupID: 20) == ["2-Normal", "4-Foil"])
        #expect(filtered(rarity: "Rare") == ["1-Normal", "1-Foil", "4-Foil"])
        // Price: the printing's own price; no price matches only "Any price".
        #expect(filtered(price: .under1) == ["1-Normal", "4-Foil"])
        #expect(filtered(price: .from1) == ["1-Foil", "2-Normal", "3-Normal"])
        #expect(filtered(price: .from5) == ["1-Foil", "2-Normal"])
        #expect(filtered(price: .from20) == ["2-Normal"])
        // Playset: Calm Rune has 4 copies over three printings, none of which has more than 2; the unknown product 5.
        #expect(filtered(playset: .moreThanAPlayset) == ["1-Normal", "1-Foil", "2-Normal", "9-Normal"])
        #expect(filtered(playset: .aPlaysetOrFewer) == ["3-Normal", "4-Foil"])
        // Two at once.
        #expect(filtered(groupID: 10, price: .from1) == ["1-Foil", "3-Normal"])
        #expect(filtered(rarity: "Rare", playset: .aPlaysetOrFewer) == ["4-Foil"])

        // Name: card key, then set, then finish. Price: entries without a price last, ties by name. Count: high to low.
        #expect(ids(CollectionList.sorted(e, by: .name)) == ["1-Foil", "1-Normal", "2-Normal", "3-Normal", "4-Foil", "9-Normal"])
        #expect(ids(CollectionList.sorted(e, by: .priceHigh)) == ["2-Normal", "1-Foil", "3-Normal", "1-Normal", "4-Foil", "9-Normal"])
        #expect(ids(CollectionList.sorted(e, by: .priceLow)) == ["1-Normal", "4-Foil", "3-Normal", "1-Foil", "2-Normal", "9-Normal"])
        #expect(ids(CollectionList.sorted(e, by: .count)) == ["9-Normal", "1-Foil", "1-Normal", "2-Normal", "3-Normal", "4-Foil"])
    }

    // MARK: Helpers

    /// Calm Rune (products 1 and 2) and Dockside Lock-Up (3 and 4) in the sets Alpha (10) and Beta (20); product 9 is
    /// not in the catalog.
    private let rows = [CollectionRow(productID: 1, finish: "Normal", count: 1, condition: "", name: "Calm Rune (R02a)"),
                        .init(productID: 1, finish: "Foil", count: 2, condition: "", name: "Calm Rune (R02a)"),
                        .init(productID: 2, finish: "Normal", count: 1, condition: "", name: "Calm Rune (R02b)"),
                        .init(productID: 3, finish: "Normal", count: 1, condition: "", name: "Dockside Lock-Up"),
                        .init(productID: 4, finish: "Foil", count: 1, condition: "", name: "Dockside Lock-Up (Alternate Art)"),
                        .init(productID: 9, finish: "Normal", count: 5, condition: "", name: "Gone Card")]

    private func entries() -> [CollectionEntry] {
        let products = [product(id: 1, groupID: 10, name: "Calm Rune (R02a)", rarity: "Rare"),
                        product(id: 2, groupID: 20, name: "Calm Rune (R02b)", rarity: "Epic"),
                        product(id: 3, groupID: 10, name: "Dockside Lock-Up", rarity: "Common"),
                        product(id: 4, groupID: 20, name: "Dockside Lock-Up (Alternate Art)", rarity: "Rare")]
        let prices: [PrintingKey: ShownPrice] = [.init(productID: 1, finish: "Normal"): .init(amount: 0.5, isLow: false),
                                                 .init(productID: 1, finish: "Foil"): .init(amount: 6, isLow: false),
                                                 .init(productID: 2, finish: "Normal"): .init(amount: 25, isLow: false),
                                                 .init(productID: 3, finish: "Normal"): .init(amount: 3, isLow: false),
                                                 .init(productID: 4, finish: "Foil"): .init(amount: 0.5, isLow: true)]
        return CollectionList.entries(rows: rows, products: Dictionary(uniqueKeysWithValues: products.map { ($0.productID, $0) }),
                                      setNames: [10: "Alpha", 20: "Beta"]) { prices[$0] }
    }

    /// An entry of an unknown product with `count` copies.
    private func entry(_ id: Int, count: Int) -> CollectionEntry {
        CollectionEntry(row: CollectionRow(productID: id, finish: "Normal", count: count, condition: "", name: ""),
                        product: nil, setName: "", price: nil, copiesOfCard: count)
    }
}
