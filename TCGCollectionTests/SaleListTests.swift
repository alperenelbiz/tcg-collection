import Testing
@testable import TCGCollection2

struct SaleListTests {
    /// The collection as the Collection's join gives it: Dockside Lock-Up Normal ×3 ($5.12), Calm Rune Foil ×2 (no price),
    /// Gone Card ×1 (its product is not in the catalog).
    private let collection = CollectionList.entries(
        rows: [CollectionRow(productID: 1, finish: "Normal", count: 3, condition: "Near Mint", name: "Dockside Lock-Up"),
               CollectionRow(productID: 2, finish: "Foil", count: 2, condition: "", name: "Calm Rune (R02a)"),
               CollectionRow(productID: 9, finish: "Normal", count: 1, condition: "", name: "Gone Card")],
        products: [1: product(id: 1, name: "Dockside Lock-Up"), 2: product(id: 2, name: "Calm Rune (R02a)")],
        setNames: [1: "Origins"]) { key in key.productID == 1 ? ShownPrice(amount: 5.12, isLow: false) : nil }

    /// One entry per for-sale printing, in the order of the For Sale list; its count is the for-sale count, the rest
    /// (product, set, price, condition) is the collection entry's. A printing unknown to the catalog keeps its saved name
    /// and has no price.
    @Test func entriesAreTheForSalePrintingsWithTheirForSaleCounts() {
        let sale = [SaleEntry(productID: 9, finish: "Normal", count: 1, name: "Gone Card"),
                    SaleEntry(productID: 1, finish: "Normal", count: 2, name: "Dockside Lock-Up")]
        let e = SaleList.entries(sale: sale, collection: collection)
        #expect(e.map(\.id) == sale.map(\.key))
        #expect(e.map(\.row.count) == [1, 2])
        #expect(e[1].product?.productID == 1 && e[1].setName == "Origins" && e[1].price == ShownPrice(amount: 5.12, isLow: false))
        #expect(e[1].row.condition == "Near Mint")
        #expect(e[1].countText == "×2")
        #expect(e[1].accessibilityText == "Dockside Lock-Up, ×2, Normal, Origins, $5.12")
        #expect(e[0].product == nil && e[0].price == nil && e[0].name == "Gone Card")
        #expect(e[0].accessibilityText == "Gone Card, ×1, Normal, no price")
        #expect(SaleList.entries(sale: [], collection: collection).isEmpty)
    }

    /// A for-sale printing with no collection entry (the join is older than the list) gets an entry from its saved name. An
    /// empty saved name takes the collection row's.
    @Test func aPrintingWithNoCollectionEntryGetsOneFromItsSavedName() {
        let e = SaleList.entries(sale: [SaleEntry(productID: 7, finish: "Foil", count: 2, name: "Hand Edited"),
                                        SaleEntry(productID: 9, finish: "Normal", count: 1, name: "")],
                                 collection: collection)
        #expect(e[0] == CollectionEntry(row: CollectionRow(productID: 7, finish: "Foil", count: 2, condition: "", name: "Hand Edited"),
                                        product: nil, setName: "", price: nil, copiesOfCard: 2))
        #expect(e[0].countText == "×2 · Foil")
        #expect(e[1].name == "Gone Card" && e[1].row.name == "Gone Card")
        // With no collection entry and no saved name: the product id, as the Collection shows it.
        #expect(SaleList.entries(sale: [SaleEntry(productID: 5, finish: "Normal", count: 1, name: "")], collection: []).map(\.name)
                == ["Product 5"])
    }

    /// Copies, printings and the summed price of the copies (price × count). Printings without a price are left out of the
    /// sum and counted after it; a low price (`~`) counts as its amount. An empty list says nothing.
    @Test func totals() {
        func entry(_ id: Int, count: Int, price: Double?, isLow: Bool = false) -> CollectionEntry {
            CollectionEntry(row: CollectionRow(productID: id, finish: "Normal", count: count, condition: "", name: "Card \(id)"),
                            product: nil, setName: "", price: price.map { ShownPrice(amount: $0, isLow: isLow) }, copiesOfCard: count)
        }
        #expect(SaleList.totals([]) == "")
        #expect(SaleList.totals([entry(1, count: 1, price: 5.12)]) == "1 copy · 1 printing · $5.12")
        #expect(SaleList.totals([entry(1, count: 2, price: 5.12), entry(2, count: 1, price: 31.26)]) == "3 copies · 2 printings · $41.50")
        #expect(SaleList.totals([entry(1, count: 2, price: 5.12), entry(2, count: 1, price: nil)])
                == "3 copies · 2 printings · $10.24 + 1 without a price")
        #expect(SaleList.totals([entry(1, count: 2, price: 5.12), entry(2, count: 1, price: 9.5, isLow: true)])
                == "3 copies · 2 printings · $19.74")
        #expect(SaleList.totals([entry(1, count: 1, price: nil), entry(2, count: 2, price: nil)])
                == "3 copies · 2 printings · $0.00 + 2 without a price")
        #expect(SaleList.totals([entry(1, count: 1200, price: 10)]) == "1200 copies · 1 printing · $12,000.00")
    }
}
