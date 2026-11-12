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
    }

    /// Fix round 1, item 3: a collection cell tells printings and finishes apart. The name is the printing's product name
    /// (an unknown product's saved name, or its id); the count line names a finish other than Normal; the accessibility
    /// text always has the name, the count, the finish, the set and the price.
    @Test func cellTexts() {
        let e = entries()
        #expect(e.map(\.name) == ["Calm Rune (R02a)", "Calm Rune (R02a)", "Calm Rune (R02b)", "Dockside Lock-Up",
                                  "Dockside Lock-Up (Alternate Art)", "Gone Card"])
        #expect(entry(7, count: 1).name == "Product 7")
        #expect(e.map(\.countText) == ["×1", "×2 · Foil", "×1", "×1", "×1 · Foil", "×5"])
        #expect(entry(7, count: 3, finish: "1st Edition").countText == "×3 · 1st Edition")
        #expect(entry(7, count: 3, finish: "normal").countText == "×3")
        #expect(e[0].accessibilityText == "Calm Rune (R02a), ×1, Normal, Alpha, $0.50")
        #expect(e[4].accessibilityText == "Dockside Lock-Up (Alternate Art), ×1, Foil, Beta, ~$0.50")
        #expect(e[5].accessibilityText == "Gone Card, ×5, Normal, no price")
    }

    /// Fix round 1, item 2: what the Collection lists depends on the catalog. Joined only when the game has fetched sets;
    /// otherwise the rows alone (saved names, no product, no price) with one line that says why; a failed join keeps the
    /// last good entries.
    @Test func contentFollowsTheCatalog() {
        let joined = entries()
        let rowsOnly = rows.map { CollectionEntry(row: $0, product: nil, setName: "", price: nil, copiesOfCard: $0.count) }
        // The catalog has this game's sets: the join, with unknown products as they are (Review Focus 4).
        #expect(CollectionList.content(rows: rows, joined: joined, joinFailed: false, catalogHasSets: true, syncing: true)
                == CollectionContent(entries: joined, linked: true, note: nil))
        // No fetched set yet: the rows alone, nothing opens, and no row is "not in the catalog any more".
        #expect(CollectionList.content(rows: rows, joined: joined, joinFailed: false, catalogHasSets: false, syncing: true)
                == CollectionContent(entries: rowsOnly, linked: false,
                                     note: "The catalog is still downloading. Pictures and prices come when it is ready."))
        #expect(CollectionList.content(rows: rows, joined: nil, joinFailed: false, catalogHasSets: false, syncing: false)
                == CollectionContent(entries: rowsOnly, linked: false, note: "The catalog is empty. Pictures and prices need the catalog."))
        // The join threw: the last good entries stay, or the rows alone when there are none.
        #expect(CollectionList.content(rows: rows, joined: joined, joinFailed: true, catalogHasSets: true, syncing: false)
                == CollectionContent(entries: joined, linked: true, note: "The catalog could not be read. Showing what was read before."))
        #expect(CollectionList.content(rows: rows, joined: nil, joinFailed: true, catalogHasSets: false, syncing: false)
                == CollectionContent(entries: rowsOnly, linked: false, note: "The catalog could not be read."))
        #expect(CollectionList.content(rows: rows, joined: [], joinFailed: true, catalogHasSets: true, syncing: false)
                == CollectionContent(entries: rowsOnly, linked: false, note: "The catalog could not be read."))
        #expect(CollectionList.content(rows: [], joined: nil, joinFailed: false, catalogHasSets: false, syncing: true).entries.isEmpty)
    }

    /// Fix round 1, item 5: a Set or Rarity choice that the collection no longer has goes back to "All".
    @Test func aChoiceTheCollectionNoLongerHasGoesBackToAll() {
        #expect(CollectionList.validChoice(10, among: [10, 20]) == 10)
        #expect(CollectionList.validChoice(30, among: [10, 20]) == nil)
        #expect(CollectionList.validChoice(Int?.none, among: [10]) == nil)
        #expect(CollectionList.validChoice("Rare", among: ["Rare", "Epic"]) == "Rare")
        #expect(CollectionList.validChoice("Showcase", among: Set<String>()) == nil)
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
    private func entry(_ id: Int, count: Int, finish: String = "Normal") -> CollectionEntry {
        CollectionEntry(row: CollectionRow(productID: id, finish: finish, count: count, condition: "", name: ""),
                        product: nil, setName: "", price: nil, copiesOfCard: count)
    }
}
