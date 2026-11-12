import Foundation

/// One owned printing as the Collection shows it: the row, its catalog product (nil when the catalog does not have it any
/// more, Review Focus 4), its set's name, its own price and the copies of its card over every printing.
nonisolated struct CollectionEntry: Sendable, Identifiable, Equatable {
    let row: CollectionRow
    let product: ProductRecord?
    let setName: String
    /// The printing's own price for its finish (market, else low with the mark); not the card's cheapest.
    let price: ShownPrice?
    /// The copies of this card over all its rows, for the playset filter. A row of an unknown product counts only itself.
    let copiesOfCard: Int

    var id: PrintingKey { row.key }

    /// The card key (`CatalogProduct.cardKey`, the folded card name, which is the product's search key); for an unknown
    /// product, the folded saved name.
    var cardKey: String { product?.searchKey ?? CardName.searchKey(row.name) }

    /// What the gallery shows: the card's name; for an unknown product the saved name, or its product id when the row has
    /// none.
    var name: String {
        if let product { return product.cardName }
        return row.name.isEmpty ? "Product \(row.productID)" : row.name
    }
}

/// The Collection's list: rows joined with the catalog, then filtered, sorted and counted in memory. Pure; the view joins
/// once per change of the rows or the catalog and filters on every keystroke.
nonisolated enum CollectionList {
    /// One entry per row, in the order of `rows`. `price` is asked for each printing.
    static func entries(rows: [CollectionRow], products: [Int: ProductRecord], setNames: [Int: String],
                        price: (PrintingKey) -> ShownPrice?) -> [CollectionEntry] {
        let perCard = CollectionRules.copiesPerCard(rows) { products[$0]?.searchKey }
        return rows.map { row in
            let product = products[row.productID]
            return CollectionEntry(row: row, product: product, setName: product.flatMap { setNames[$0.groupID] } ?? "",
                                   price: price(row.key),
                                   copiesOfCard: product.flatMap { perCard[$0.searchKey] } ?? row.count)
        }
    }

    /// The entries that pass every filter, in their order. `text` matches when every folded word of it is in the card's
    /// search key (the catalog search's rule), or for an unknown product in its folded saved name. A set or rarity filter
    /// leaves out unknown products; a price filter other than `.any` leaves out entries without a price. The playset filter
    /// counts a card over all its printings (`copiesOfCard`).
    static func filtered(_ entries: [CollectionEntry], text: String, groupID: Int?, rarity: String?, price: PriceFilter,
                         playset: CollectionRules.PlaysetFilter, playsetSize: Int) -> [CollectionEntry] {
        let words = CardName.searchKey(text).split(separator: " ")
        return entries.filter { entry in
            if let groupID, entry.product?.groupID != groupID { return false }
            if let rarity, entry.product?.rarity != rarity { return false }
            guard price.matches(entry.price?.amount),
                  CollectionRules.matches(playset, copiesOfCard: entry.copiesOfCard, playset: playsetSize) else { return false }
            guard !words.isEmpty else { return true }
            let key = entry.cardKey
            return words.allSatisfy { key.contains($0) }
        }
    }

    /// Name: by card key, then set name, then finish. Price high to low and low to high: entries without a price last.
    /// Count: high to low. Every tie goes by the name order; the product id ends a tie of equal names.
    static func sorted(_ entries: [CollectionEntry], by sort: CollectionSort) -> [CollectionEntry] {
        // The card key of an unknown product is computed from its name: once per entry, not once per comparison.
        let keyed = entries.map { (entry: $0, key: $0.cardKey) }
        func byName(_ a: (entry: CollectionEntry, key: String), _ b: (entry: CollectionEntry, key: String)) -> Bool {
            if a.key != b.key { return a.key < b.key }
            if a.entry.setName != b.entry.setName { return a.entry.setName < b.entry.setName }
            if a.entry.row.finish != b.entry.row.finish { return a.entry.row.finish < b.entry.row.finish }
            return a.entry.row.productID < b.entry.row.productID
        }
        let ordered: [(entry: CollectionEntry, key: String)]
        switch sort {
        case .name:
            ordered = keyed.sorted(by: byName)
        case .priceHigh, .priceLow:
            let high = sort == .priceHigh
            ordered = keyed.sorted { a, b in
                switch (a.entry.price?.amount, b.entry.price?.amount) {
                case let (x?, y?) where x != y: return high ? x > y : x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        case .count:
            ordered = keyed.sorted { a, b in
                a.entry.row.count != b.entry.row.count ? a.entry.row.count > b.entry.row.count : byName(a, b)
            }
        }
        return ordered.map(\.entry)
    }

    /// `120 copies · 74 printings`, `1 copy · 1 printing`. With `all` (a filter or search text is on), the shown part of
    /// it: `12 of 120 copies · 9 of 74 printings`; the noun then follows the whole.
    static func totals(_ entries: [CollectionEntry], of all: [CollectionEntry]? = nil) -> String {
        func part(_ shown: Int, _ whole: Int?, _ one: String, _ many: String) -> String {
            guard let whole else { return "\(shown) \(shown == 1 ? one : many)" }
            return "\(shown) of \(whole) \(whole == 1 ? one : many)"
        }
        let copies = entries.reduce(0) { $0 + $1.row.count }
        let allCopies = all.map { $0.reduce(0) { $0 + $1.row.count } }
        return part(copies, allCopies, "copy", "copies") + " · " + part(entries.count, all?.count, "printing", "printings")
    }
}
