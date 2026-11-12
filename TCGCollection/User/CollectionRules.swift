import Foundation

/// Pure rules over collection rows.
nonisolated enum CollectionRules {
    /// Sets the count of one printing. Count <= 0 removes the row; a new row is appended with no condition.
    static func setting(_ rows: [CollectionRow], count: Int, for key: PrintingKey, name: String) -> [CollectionRow] {
        var rows = rows
        if let i = rows.firstIndex(where: { $0.key == key }) {
            if count <= 0 { rows.remove(at: i) } else { rows[i].count = count }
        } else if count > 0 {
            rows.append(CollectionRow(productID: key.productID, finish: key.finish, count: count, condition: "", name: name))
        }
        return rows
    }

    static func count(_ rows: [CollectionRow], for key: PrintingKey) -> Int {
        rows.first(where: { $0.key == key })?.count ?? 0
    }

    static func copies(_ rows: [CollectionRow]) -> Int {
        rows.reduce(0) { $0 + $1.count }
    }

    /// Copies per card over all its printings. Rows whose product is unknown are left out.
    static func copiesPerCard(_ rows: [CollectionRow], cardKeyOf: (Int) -> String?) -> [String: Int] {
        var result: [String: Int] = [:]
        for row in rows {
            guard let card = cardKeyOf(row.productID) else { continue }
            result[card, default: 0] += row.count
        }
        return result
    }

    /// The finishes the card page offers for one product (B5): the price table's finishes in its order, or `Normal` when
    /// it has none; then each owned finish it does not list (a CSV's unusual `Printing`), in the order given.
    static func finishes(priced: [String], owned: [String]) -> [String] {
        var result = priced.isEmpty ? ["Normal"] : priced
        for finish in owned where !result.contains(finish) { result.append(finish) }
        return result
    }

    nonisolated enum PlaysetFilter: Sendable { case any, moreThanAPlayset, aPlaysetOrFewer }

    static func matches(_ filter: PlaysetFilter, copiesOfCard: Int, playset: Int) -> Bool {
        switch filter {
        case .any: true
        case .moreThanAPlayset: copiesOfCard > playset
        case .aPlaysetOrFewer: copiesOfCard <= playset
        }
    }
}

nonisolated enum PriceFilter: Sendable, CaseIterable {
    case any, under1, from1, from5, from20

    func matches(_ price: Double?) -> Bool {
        guard self != .any else { return true }
        guard let price else { return false }
        switch self {
        case .any: return true
        case .under1: return price < 1
        case .from1: return price >= 1
        case .from5: return price >= 5
        case .from20: return price >= 20
        }
    }
}

nonisolated enum CollectionSort: String, Sendable, CaseIterable {
    case name, priceHigh, priceLow, count
}
