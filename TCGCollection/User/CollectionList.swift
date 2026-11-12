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

    /// The cell's name: the printing's product name, so two printings of one card differ (`Calm Rune (R02a)`); for an
    /// unknown product the saved name, or its product id when the row has none.
    var name: String {
        if let product { return product.name }
        return row.name.isEmpty ? "Product \(row.productID)" : row.name
    }

    /// The cell's count line: `×3`, or `×3 · Foil` for any finish other than Normal, as written.
    var countText: String {
        let count = "×\(row.count)"
        return row.finish.caseInsensitiveCompare("Normal") == .orderedSame ? count : "\(count) · \(row.finish)"
    }

    /// What VoiceOver and the UI tests read for a cell: name, count, finish (Normal too), set (when known) and price.
    var accessibilityText: String {
        [name, "×\(row.count)", row.finish, setName, price.map { CardFacts.priceText($0) } ?? "no price"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// What the Collection lists, given the state of the catalog (`CollectionList.content`).
nonisolated struct CollectionContent: Equatable {
    let entries: [CollectionEntry]
    /// True when the entries come from a join with the catalog's products: they have sets, rarities and prices, so the Set
    /// and Rarity choices apply. False: the rows alone (saved names, no picture, no price).
    let joined: Bool
    /// True when the game's catalog is settled (its catalog step is not running or still due in this run, and the game
    /// has products): only then is a product the catalog lacks "not in the catalog any more" (Review Focus 4).
    let settled: Bool
    /// One muted line above the gallery that says what the catalog cannot give; nil when it gives everything.
    let note: String?

    /// Where a cell opens: its card page when the catalog has its product; the page of a printing that left the catalog
    /// when the catalog is settled; else nowhere (pending).
    func link(for entry: CollectionEntry) -> CollectionCellLink {
        if entry.product != nil { return .card }
        return settled ? .unknownPrinting : .none
    }
}

/// Where a Collection cell opens (`CollectionContent.link(for:)`).
nonisolated enum CollectionCellLink: Equatable {
    case card, unknownPrinting
    /// Pending: the catalog cannot say yet what this row is.
    case none
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

    static let catalogDownloading = "The catalog is still downloading. Pictures and prices come when it is ready."
    static let catalogEmpty = "The catalog is empty. Pictures and prices need the catalog."
    static let catalogUnreadable = "The catalog could not be read."
    static let catalogUnreadableKept = "The catalog could not be read. Showing what was read before."

    /// What the Collection lists.
    /// - `joined`: the last join that succeeded on a catalog with this game's products (nil when none did yet).
    /// - `joinFailed`: the latest join threw.
    /// - `catalogHasProducts`: the catalog has products of this game.
    /// - `catalogSettled`: the game's catalog step is not running or still due in this run (`AppModel.catalogSettled`); a
    ///   step that ended with failed sets counts as ended.
    /// A missing product is "not in the catalog any more" only on a settled catalog with products; otherwise its row is
    /// pending, with the downloading line. Without products the rows are listed alone; a failed join keeps the last good
    /// entries, whose missing products are then pending (the read could not confirm them).
    static func content(rows: [CollectionRow], joined: [CollectionEntry]?, joinFailed: Bool, catalogHasProducts: Bool,
                        catalogSettled: Bool) -> CollectionContent {
        let alone = rows.map { CollectionEntry(row: $0, product: nil, setName: "", price: nil, copiesOfCard: $0.count) }
        if joinFailed {
            if let joined, !joined.isEmpty {
                return CollectionContent(entries: joined, joined: true, settled: false, note: catalogUnreadableKept)
            }
            return CollectionContent(entries: alone, joined: false, settled: false, note: catalogUnreadable)
        }
        guard catalogHasProducts, let joined else {
            return CollectionContent(entries: alone, joined: false, settled: false,
                                     note: catalogSettled ? catalogEmpty : catalogDownloading)
        }
        let pending = !catalogSettled && joined.contains { $0.product == nil }
        return CollectionContent(entries: joined, joined: true, settled: catalogSettled, note: pending ? catalogDownloading : nil)
    }

    /// The gallery's entries: `content`'s entries filtered and sorted. A Set or Rarity choice applies only to joined
    /// entries: the rows alone have neither, and the choice would hide every row (it stays stored).
    static func shown(_ content: CollectionContent, text: String, groupID: Int?, rarity: String?, price: PriceFilter,
                      playset: CollectionRules.PlaysetFilter, playsetSize: Int, sort: CollectionSort) -> [CollectionEntry] {
        sorted(filtered(content.entries, text: text, groupID: content.joined ? groupID : nil,
                        rarity: content.joined ? rarity : nil, price: price, playset: playset, playsetSize: playsetSize),
               by: sort)
    }

    /// A Set or Rarity choice, or nil ("All") when the collection no longer has that value. Only on a settled catalog:
    /// while it downloads, a set or rarity that is not in yet is no proof, and the choice stays.
    static func validChoice<T: Hashable>(_ choice: T?, among available: Set<T>, settled: Bool) -> T? {
        guard settled else { return choice }
        return choice.flatMap { available.contains($0) ? $0 : nil }
    }

    /// True when the Collection must join again: what the join reads changed since the last one, or the last one failed
    /// (tried again at the next appearance of the screen; the failure changes nothing the join reads, so it never loops).
    static func joinIsDue<Key: Equatable>(_ key: Key, last: Key?, lastFailed: Bool) -> Bool {
        last != key || lastFailed
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
