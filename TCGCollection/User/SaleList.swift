import Foundation

/// For Sale's list: the for-sale printings as `CollectionEntry`s, so the screen uses the Collection's cell, search and sort
/// (A10). Pure; the view joins the collection with the catalog once (`RowsJoin`) and maps it here on every render.
nonisolated enum SaleList {
    /// One entry per for-sale printing, in the order of `sale`. Its `row.count` is the for-sale count; product, set,
    /// price and condition are the printing's collection entry's. A printing with no collection entry gets one from its
    /// saved name: no product, no price. The library keeps every for-sale printing owned (C8, also on a read), so that
    /// happens only while `collection` is older than `sale` (a change or a reload since the last join; the next join has
    /// it). The saved name is the for-sale entry's, else the collection row's.
    static func entries(sale: [SaleEntry], collection: [CollectionEntry]) -> [CollectionEntry] {
        let owned = Dictionary(collection.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sale.map { entry in
            guard let mine = owned[entry.key] else {
                return CollectionEntry(row: CollectionRow(productID: entry.productID, finish: entry.finish, count: entry.count,
                                                          condition: "", name: entry.name),
                                       product: nil, setName: "", price: nil, copiesOfCard: entry.count)
            }
            var row = mine.row
            row.count = entry.count
            if !entry.name.isEmpty { row.name = entry.name }
            return CollectionEntry(row: row, product: mine.product, setName: mine.setName, price: mine.price,
                                   copiesOfCard: mine.copiesOfCard)
        }
    }

    /// `3 copies · 2 printings · $41.50`: the copies, the printings and the summed price of the copies (price × count; a
    /// low price counts as its amount). Printings without a price are left out of the sum and counted after it:
    /// `… · $10.24 + 1 without a price`. "" for an empty list.
    static func totals(_ entries: [CollectionEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let copies = entries.reduce(0) { $0 + $1.row.count }
        let sum = entries.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.row.count) }
        let unpriced = entries.filter { $0.price == nil }.count
        var text = "\(copies) \(copies == 1 ? "copy" : "copies") · \(entries.count) \(entries.count == 1 ? "printing" : "printings")"
        text += " · " + CardFacts.priceText(ShownPrice(amount: sum, isLow: false))
        if unpriced > 0 { text += " + \(unpriced) without a price" }
        return text
    }
}
