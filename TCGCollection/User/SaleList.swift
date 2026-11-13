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
    /// `… · $10.24 + 1 without a price`; with no priced printing, `… · 2 without a price`. With `all` (the search text is
    /// on), the Collection's form for the shown part: `1 of 3 copies · 1 of 2 printings · $5.12`; the sum is of the shown
    /// printings. "" for an empty list.
    static func totals(_ entries: [CollectionEntry], of all: [CollectionEntry]? = nil) -> String {
        guard !(all ?? entries).isEmpty else { return "" }
        let priced = entries.filter { $0.price != nil }
        let sum = priced.isEmpty ? nil : priced.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.row.count) }
        let tail = CollectionList.priceTail(sum: sum, unpriced: entries.count - priced.count)
        return ([CollectionList.totals(entries, of: all)] + [tail].compactMap { $0 }).joined(separator: " · ")
    }

    /// C7: what the Sold dialog of a printing offers for its live for-sale count: "Sold 1", and "Sold all <n>" when more
    /// than one copy is for sale. Nil when none is (the dialog closes).
    static func soldDialog(name: String, forSale count: Int) -> SoldDialog? {
        guard count > 0 else { return nil }
        var choices = [SoldChoice(label: "Sold 1", count: 1)]
        if count > 1 { choices.append(SoldChoice(label: "Sold all \(count)", count: count)) }
        return SoldDialog(title: "Sold \(count) of \(name)?", choices: choices)
    }

    /// The system's dialog does not redraw while it is open (an alert sheet on the Mac). An open Sold dialog made for the
    /// count `shown` stays while the live count is the same, opens again with the live count when it changed (a reload,
    /// another window), and closes when nothing is for sale any more.
    static func follow(shown: Int, live: Int) -> SoldDialogStep {
        if live <= 0 { return .close }
        return live == shown ? .keep : .reopen(live)
    }
}

/// What an open Sold dialog does when the live for-sale count of its printing changed (`SaleList.follow`).
nonisolated enum SoldDialogStep: Equatable, Sendable {
    case keep
    case reopen(Int)
    case close
}

/// The Sold dialog of one printing (C7): "Sold <n> of <name>?" and its choices.
nonisolated struct SoldDialog: Equatable, Sendable {
    let title: String
    let choices: [SoldChoice]
}

/// One button of the Sold dialog: its label and the copies it sells.
nonisolated struct SoldChoice: Equatable, Hashable, Sendable {
    let label: String
    let count: Int
}
