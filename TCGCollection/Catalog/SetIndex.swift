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
    var sets: [Int: [Int]] {
        didSet { groupOf = Self.groups(of: sets) }
    }

    /// Product id -> its set. Made once from `sets` (at init, at a read, and when `sets` changes), not per access.
    private(set) var groupOf: [Int: Int]

    init(sets: [Int: [Int]]) {
        self.sets = sets
        groupOf = Self.groups(of: sets)
    }

    static func == (a: SetIndex, b: SetIndex) -> Bool { a.sets == b.sets }

    private static func groups(of sets: [Int: [Int]]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (group, products) in sets {
            for product in products { map[product] = group }
        }
        return map
    }

    /// The set's product ids in card-number order; empty for a set the index does not hold.
    func products(of groupID: Int) -> [Int] { sets[groupID] ?? [] }

    /// Nil when the file does not exist, cannot be decoded, is of another version, or has a set key that is not a
    /// canonical decimal number (`"01"`, `"+1"`, `" 1"` would name a set twice): it then counts as none.
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
            guard let group = Int(key), String(group) == key else {
                throw DecodingError.dataCorruptedError(forKey: .sets, in: container, debugDescription: "set key \(key) is not a canonical number")
            }
            sets[group] = products
        }
        self.init(sets: sets)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(Dictionary(uniqueKeysWithValues: sets.map { (String($0.key), $0.value) }), forKey: .sets)
    }
}

/// Card-number order (F4): by the product's number, compared piece by piece (runs of digits as numbers, other runs as
/// text, ignoring case; a digit run before a text run): `1, 2, 10, 10a, BETB-EN001, BETB-EN002, T-01`. The number is
/// trimmed of white space; a product without a number (empty or only spaces) comes after those with one. Equal numbers
/// (`2` and `02`, `t-01` and `T-01`) go by name (ignoring case, then as written), then by product id, so the order is
/// total and the same on every run.
nonisolated enum SetOrder {
    static func precedes(_ a: (number: String, name: String, id: Int), _ b: (number: String, name: String, id: Int)) -> Bool {
        Key(a) < Key(b)
    }

    /// The ids in card-number order: each entry's key (its number's pieces, its folded name) is made once, then sorted.
    static func sorted(_ entries: [(number: String, name: String, id: Int)]) -> [Int] {
        entries.map(Key.init).sorted(by: <).map(\.id)
    }

    private enum Piece {
        case digits(String)     // without leading zeros ("" for zero)
        case text(String)       // lowercased
    }

    private struct Key {
        let pieces: [Piece]
        let foldedName: String
        let name: String
        let id: Int

        init(_ entry: (number: String, name: String, id: Int)) {
            pieces = SetOrder.pieces(entry.number.trimmingCharacters(in: .whitespacesAndNewlines))
            foldedName = entry.name.lowercased()
            name = entry.name
            id = entry.id
        }

        static func < (a: Key, b: Key) -> Bool {
            if a.pieces.isEmpty != b.pieces.isEmpty { return b.pieces.isEmpty }
            let byNumber = SetOrder.compare(a.pieces, b.pieces)
            if byNumber != .orderedSame { return byNumber == .orderedAscending }
            if a.foldedName != b.foldedName { return a.foldedName < b.foldedName }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
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

    private static func compare(_ left: [Piece], _ right: [Piece]) -> ComparisonResult {
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
