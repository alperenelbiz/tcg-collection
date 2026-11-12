import Foundation

nonisolated enum GameUserFileError: Error, Equatable {
    case newerVersion(Int)
    case notAnObject
}

/// The decoded top-level JSON object, kept so that keys this app does not know survive a rewrite.
/// Never mutated after creation, so sharing it between threads is safe.
nonisolated private final class JSONObjectBox: @unchecked Sendable {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }
}

/// One game's user file (`<game id>.json`): `version`, `collection`, and whatever else a newer app wrote.
nonisolated struct GameUserFile: Sendable, Equatable {
    static let currentVersion = 1

    var collection: [CollectionRow]
    private let raw: JSONObjectBox

    init() {
        collection = []
        raw = JSONObjectBox([:])
    }

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameUserFileError.notAnObject
        }
        let version = object["version"].flatMap(Self.integer) ?? 1
        if version > Self.currentVersion { throw GameUserFileError.newerVersion(version) }
        let rawRows = object["collection"] as? [Any] ?? []
        collection = Self.clean(rawRows.compactMap(Self.row))
        raw = JSONObjectBox(object)
    }

    /// UTF-8, pretty-printed, sorted keys, ending with a newline.
    func data() throws -> Data {
        var object = raw.object
        object["version"] = Self.currentVersion
        object["collection"] = try collection.map { row in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
        }
        var out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        return out
    }

    static func == (lhs: GameUserFile, rhs: GameUserFile) -> Bool {
        lhs.collection == rhs.collection && (try? lhs.data()) == (try? rhs.data())
    }

    // MARK: Reading

    /// A whole JSON number; not a boolean, not a fraction.
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d == d.rounded(), abs(d) < 9e15 else { return nil }
        return number.intValue
    }

    private static func row(_ value: Any) -> CollectionRow? {
        guard let o = value as? [String: Any],
              let productID = o["productID"].flatMap(integer),
              let finish = o["finish"] as? String,
              let count = o["count"].flatMap(integer) else { return nil }
        return CollectionRow(productID: productID, finish: finish, count: count,
                             condition: o["condition"] as? String ?? "", name: o["name"] as? String ?? "")
    }

    /// Drops rows with count < 1; merges rows of one printing (first position wins).
    private static func clean(_ rows: [CollectionRow]) -> [CollectionRow] {
        var result: [CollectionRow] = []
        var index: [PrintingKey: Int] = [:]
        for row in rows where row.count >= 1 {
            if let i = index[row.key] {
                result[i].count += row.count
                if result[i].condition.isEmpty { result[i].condition = row.condition }
                if result[i].name.isEmpty { result[i].name = row.name }
            } else {
                index[row.key] = result.count
                result.append(row)
            }
        }
        return result
    }
}
