import Foundation

/// The products of each set of one game, in card-number order (F3, F4): what the Sets screen counts, so it never scans
/// the catalog. Derived from the store, like the filter lists: kept in `sets-<game>.json` and made again at the end of a
/// catalog step that changed the game, and at launch for a game with products and no file. A set with no product is not
/// in it (F5).
///
/// The file is `{"version": 1, "sets": {"<groupID>": [productID, …]}}`, with string keys (Codable would write a
/// dictionary keyed by `Int` as an array of pairs) and sorted keys, so its bytes are stable.
nonisolated struct SetIndex: Codable, Sendable, Equatable {
    static let version = 1

    /// Group id -> the set's product ids in card-number order.
    var sets: [Int: [Int]]

    init(sets: [Int: [Int]]) {
        self.sets = sets
    }

    /// The set's product ids in card-number order; empty for a set the index does not hold.
    func products(of groupID: Int) -> [Int] { sets[groupID] ?? [] }

    /// Product id -> its set.
    var groupOf: [Int: Int] {
        var map: [Int: Int] = [:]
        for (group, products) in sets {
            for product in products { map[product] = group }
        }
        return map
    }

    /// Nil when the file does not exist, cannot be decoded, or is of another version (it then counts as none).
    static func read(_ url: URL) -> SetIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SetIndex.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private enum CodingKeys: String, CodingKey { case version, sets }

    private struct VersionMismatch: Error {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.version else { throw VersionMismatch() }
        var sets: [Int: [Int]] = [:]
        for (key, products) in try container.decode([String: [Int]].self, forKey: .sets) {
            guard let group = Int(key) else {
                throw DecodingError.dataCorruptedError(forKey: .sets, in: container, debugDescription: "set key \(key) is not a number")
            }
            sets[group] = products
        }
        self.sets = sets
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(Dictionary(uniqueKeysWithValues: sets.map { (String($0.key), $0.value) }), forKey: .sets)
    }
}

/// Card-number order (F4): by the product's number, compared piece by piece (runs of digits as numbers, other runs as
/// text, ignoring case; a digit run before a text run): `1, 2, 10, 10a, BETB-EN001, BETB-EN002, T-01`. A product without
/// a number comes after those with one. Equal numbers (`2` and `02`, `t-01` and `T-01`) go by name (ignoring case,
/// then as written), then by product id, so the order is total and the same on every run.
nonisolated enum SetOrder {
    static func precedes(_ a: (number: String, name: String, id: Int), _ b: (number: String, name: String, id: Int)) -> Bool {
        if a.number.isEmpty != b.number.isEmpty { return b.number.isEmpty }
        let byNumber = compareNumbers(a.number, b.number)
        if byNumber != .orderedSame { return byNumber == .orderedAscending }
        let foldedA = a.name.lowercased(), foldedB = b.name.lowercased()
        if foldedA != foldedB { return foldedA < foldedB }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    private enum Piece {
        case digits(String)     // without leading zeros ("" for zero)
        case text(String)       // lowercased
    }

    private static func pieces(_ number: String) -> [Piece] {
        var result: [Piece] = []
        var run = ""
        var runIsDigits = false
        func close() {
            guard !run.isEmpty else { return }
            if runIsDigits {
                result.append(.digits(String(run.drop { $0 == "0" })))
            } else {
                result.append(.text(run.lowercased()))
            }
            run = ""
        }
        for character in number {
            let isDigit = character.isASCII && character.isNumber
            if !run.isEmpty && isDigit != runIsDigits { close() }
            runIsDigits = isDigit
            run.append(character)
        }
        close()
        return result
    }

    private static func compareNumbers(_ a: String, _ b: String) -> ComparisonResult {
        let left = pieces(a), right = pieces(b)
        for (x, y) in zip(left, right) {
            switch (x, y) {
            case (.digits(let p), .digits(let q)):
                // Compared as numbers of any length: the shorter run of significant digits is the smaller.
                if p.count != q.count { return p.count < q.count ? .orderedAscending : .orderedDescending }
                if p != q { return p < q ? .orderedAscending : .orderedDescending }
            case (.text(let p), .text(let q)):
                if p != q { return p < q ? .orderedAscending : .orderedDescending }
            case (.digits, .text):
                return .orderedAscending
            case (.text, .digits):
                return .orderedDescending
            }
        }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}
