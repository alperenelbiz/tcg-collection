import Foundation

/// One target of a master set (A26): one printing of the set in one finish.
nonisolated struct SetTarget: Sendable, Hashable, Identifiable {
    let productID: Int
    let finish: String
    var key: PrintingKey { PrintingKey(productID: productID, finish: finish) }
    var id: PrintingKey { key }
}

/// The numbers of one set: its targets owned and in all (F2), and the price of the missing ones (F6): `missingSum`, the
/// summed own prices of the missing targets that have one (nil when none has), and `missingUnpriced`, those without.
nonisolated struct SetNumbers: Sendable, Equatable {
    var owned: Int
    var total: Int
    var missingSum: Double?
    var missingUnpriced: Int
    var isComplete: Bool { owned >= total }
}

/// One row of the Sets list: a set and its numbers. Its id is the set's group id.
nonisolated struct SetRow: Sendable, Equatable, Identifiable {
    let set: SetRecord
    let numbers: SetNumbers
    var id: Int { self.set.groupID }
}

/// "My sets" (the sets with an owned target) or "All sets" (A27).
nonisolated enum SetScope: String, Sendable { case mine, all }
/// The Sets list's sort: Newest (the default), Name, Most complete, Cost to complete.
nonisolated enum SetSort: String, Sendable, CaseIterable { case newest, name, complete, cost }
/// A set page's filter: All, Missing, Owned.
nonisolated enum SetFilter: String, Sendable, CaseIterable { case all, missing, owned }

/// The numbers and texts of the Sets list and of a set's page, pure: no catalog, library, clock, locale or file access.
nonisolated enum SetMaths {
    /// The targets of one product: its finishes by F1 (the card page's finish lines, `CollectionRules.finishes`).
    static func targets(productID: Int, priced: [String], owned: [String]) -> [SetTarget] {
        CollectionRules.finishes(priced: priced, owned: owned).map { SetTarget(productID: productID, finish: $0) }
    }

    /// The numbers of one set from its product ids. A target is owned at an owned count of 1 or more (F2); a missing
    /// target's own price goes into the sum, or it counts as without a price (F6).
    static func numbers(products: [Int], priced: (Int) -> [String], ownedCount: (PrintingKey) -> Int,
                        ownedFinishes: (Int) -> [String], price: (PrintingKey) -> ShownPrice?) -> SetNumbers {
        var owned = 0, total = 0, unpriced = 0
        var sum: Double?
        for product in products {
            for target in targets(productID: product, priced: priced(product), owned: ownedFinishes(product)) {
                total += 1
                if ownedCount(target.key) >= 1 {
                    owned += 1
                } else if let shown = price(target.key) {
                    sum = (sum ?? 0) + shown.amount
                } else {
                    unpriced += 1
                }
            }
        }
        return SetNumbers(owned: owned, total: total, missingSum: sum, missingUnpriced: unpriced)
    }

    /// One row per set that has a product in the index (F5), in the order of `sets`. `rows` is every collection row of
    /// the game; a row with a count under 1 is not owned, and a row of a product in no set counts nowhere.
    static func rows(sets: [SetRecord], index: SetIndex, rows: [CollectionRow], priced: (Int) -> [String],
                     price: (PrintingKey) -> ShownPrice?) -> [SetRow] {
        var counts: [PrintingKey: Int] = [:]
        var finishes: [Int: [String]] = [:]
        for row in rows where row.count >= 1 {
            if counts[row.key] == nil { finishes[row.productID, default: []].append(row.finish) }
            counts[row.key, default: 0] += row.count
        }
        return sets.compactMap { set in
            let products = index.products(of: set.groupID)
            guard !products.isEmpty else { return nil }
            let counted = numbers(products: products, priced: priced, ownedCount: { counts[$0] ?? 0 },
                                  ownedFinishes: { finishes[$0] ?? [] }, price: price)
            return SetRow(set: set, numbers: counted)
        }
    }

    /// A27: "My sets" only while some set has an owned target; else all sets.
    static func scope(_ asked: SetScope, rows: [SetRow]) -> SetScope {
        asked == .mine && rows.contains(where: { $0.numbers.owned > 0 }) ? .mine : .all
    }

    /// The rows of the scope whose name or abbreviation holds every folded word of `text` (each word in either), sorted.
    static func shown(_ rows: [SetRow], scope: SetScope, text: String, sort: SetSort) -> [SetRow] {
        let words = CardName.searchKey(text).split(separator: " ")
        let kept = rows.filter { row in
            guard scope == .all || row.numbers.owned > 0 else { return false }
            guard !words.isEmpty else { return true }
            let name = CardName.searchKey(row.set.name), abbreviation = CardName.searchKey(row.set.abbreviation)
            return words.allSatisfy { name.contains($0) || abbreviation.contains($0) }
        }
        return sorted(kept, by: sort)
    }

    /// Newest: release date descending, undated last. Most complete: owned ÷ total descending. Cost: the missing sum
    /// ascending; sets whose missing targets have no price after them; complete sets last. Every tie goes by name.
    private static func sorted(_ rows: [SetRow], by sort: SetSort) -> [SetRow] {
        let keyed = rows.map { (row: $0, name: CardName.searchKey($0.set.name)) }
        func byName(_ a: (row: SetRow, name: String), _ b: (row: SetRow, name: String)) -> Bool {
            if a.name != b.name { return a.name < b.name }
            if a.row.set.name != b.row.set.name { return a.row.set.name < b.row.set.name }
            return a.row.id < b.row.id
        }
        // 0: priced and missing, 1: missing without any price, 2: complete.
        func costRank(_ n: SetNumbers) -> Int { n.isComplete ? 2 : n.missingSum == nil ? 1 : 0 }
        return keyed.sorted { a, b in
            let x = a.row.numbers, y = b.row.numbers
            switch sort {
            case .name:
                break
            case .newest:
                switch (a.row.set.publishedOn, b.row.set.publishedOn) {
                case let (p?, q?) where p != q: return p > q
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            case .complete:
                // owned / total compared without division (total is at least 1 for a listed set).
                let left = x.owned * max(y.total, 1), right = y.owned * max(x.total, 1)
                if left != right { return left > right }
            case .cost:
                let p = costRank(x), q = costRank(y)
                if p != q { return p < q }
                if p == 0, let s = x.missingSum, let t = y.missingSum, s != t { return s < t }
            }
            return byName(a, b)
        }.map(\.row)
    }

    /// `187 / 412`.
    static func countText(_ n: SetNumbers) -> String { "\(n.owned) / \(n.total)" }

    /// The price of the missing targets (`CollectionList.priceTail`): `$1,240.50`, `$310.00 + 3 without a price`,
    /// `12 without a price`; nil for a complete set.
    static func costText(_ n: SetNumbers) -> String? {
        guard !n.isComplete else { return nil }
        return CollectionList.priceTail(sum: n.missingSum, unpriced: n.missingUnpriced)
    }

    /// `12 sets`, `1 set`; while the search text is on, `3 of 12 sets` (the noun follows the whole).
    static func subtitle(shown: Int, of all: Int, searching: Bool) -> String {
        func sets(_ n: Int) -> String { n == 1 ? "set" : "sets" }
        return searching ? "\(shown) of \(all) \(sets(all))" : "\(shown) \(sets(shown))"
    }

    /// `187 of 412 · $1,240.50 to complete`, `187 of 412 · $310.00 to complete + 3 without a price`, `187 of 412 · 12
    /// without a price`; `412 of 412` for a complete set (the deck page's form of the tail).
    static func pageSubtitle(_ n: SetNumbers) -> String {
        let head = "\(n.owned) of \(n.total)"
        guard !n.isComplete else { return head }
        let money = CollectionList.priceTail(sum: n.missingSum, unpriced: 0).map { "\($0) to complete" }
        let tail = [money, CollectionList.priceTail(sum: nil, unpriced: n.missingUnpriced)].compactMap { $0 }
            .joined(separator: " + ")
        return tail.isEmpty ? head : "\(head) · \(tail)"
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    /// `November 2025`: the English month and year of the date in the Gregorian calendar, in UTC (not the device's
    /// locale or time zone); "" for nil.
    static func releaseText(_ date: Date?) -> String {
        guard let date else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month, months.indices.contains(month - 1) else { return "" }
        return "\(months[month - 1]) \(year)"
    }

    /// A set page's filter: missing at an owned count of 0, owned at 1 or more.
    static func filtered(_ targets: [SetTarget], filter: SetFilter, ownedCount: (PrintingKey) -> Int) -> [SetTarget] {
        switch filter {
        case .all: targets
        case .missing: targets.filter { ownedCount($0.key) < 1 }
        case .owned: targets.filter { ownedCount($0.key) >= 1 }
        }
    }

    /// A set cell's left text: owned `×2`, `×2 · Foil`; missing `Foil`, nothing for Normal.
    static func leftText(count: Int, finish: String) -> String {
        let isNormal = finish == "Normal"
        guard count >= 1 else { return isNormal ? "" : finish }
        return isNormal ? "×\(count)" : "×\(count) · \(finish)"
    }
}
