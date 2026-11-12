import Foundation

nonisolated enum GameUserFileError: Error, Equatable {
    case newerVersion(Int)
    case notAnObject
    case malformedVersion
    case malformedCollection
}

/// The decoded top-level JSON object, kept so that keys this app does not know survive a rewrite.
/// It also keeps each parsed row's raw object (by printing) and the array elements that could not be parsed.
/// Never mutated after creation, so sharing it between threads is safe.
nonisolated private final class JSONObjectBox: @unchecked Sendable {
    let object: [String: Any]
    let rowObjects: [PrintingKey: [String: Any]]
    let unparseable: [Any]
    init(_ object: [String: Any], rowObjects: [PrintingKey: [String: Any]] = [:], unparseable: [Any] = []) {
        self.object = object
        self.rowObjects = rowObjects
        self.unparseable = unparseable
    }
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
        if let value = object["version"] {
            guard let version = Self.integer(value), version >= 1 else { throw GameUserFileError.malformedVersion }
            if version > Self.currentVersion { throw GameUserFileError.newerVersion(version) }
        }
        var rawRows: [Any] = []
        if let value = object["collection"], !(value is NSNull) {
            guard let array = value as? [Any] else { throw GameUserFileError.malformedCollection }
            rawRows = array
        }
        var parsed: [(CollectionRow, [String: Any])] = []
        var unparseable: [Any] = []
        for element in rawRows {
            if let row = Self.row(element) { parsed.append((row, element as! [String: Any])) } else { unparseable.append(element) }
        }
        let (rows, objects) = Self.clean(parsed)
        collection = rows
        raw = JSONObjectBox(object, rowObjects: objects, unparseable: unparseable)
    }

    /// UTF-8, pretty-printed, sorted keys, ending with a newline.
    func data() throws -> Data {
        var object = raw.object
        object["version"] = Self.currentVersion
        var rows: [Any] = try collection.map { row in
            var merged = raw.rowObjects[row.key] ?? [:]
            let known = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any] ?? [:]
            merged.merge(known) { _, new in new }
            return merged
        }
        rows.append(contentsOf: raw.unparseable)
        object["collection"] = rows
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
              let rawFinish = o["finish"] as? String,
              let count = o["count"].flatMap(integer) else { return nil }
        let trimmed = rawFinish.trimmingCharacters(in: .whitespacesAndNewlines)
        let finish = trimmed.isEmpty ? "Normal" : trimmed
        return CollectionRow(productID: productID, finish: finish, count: count,
                             condition: o["condition"] as? String ?? "", name: o["name"] as? String ?? "")
    }

    /// Drops rows with count < 1; merges rows of one printing (first position and raw object win).
    private static func clean(_ rows: [(CollectionRow, [String: Any])]) -> ([CollectionRow], [PrintingKey: [String: Any]]) {
        var result: [CollectionRow] = []
        var objects: [PrintingKey: [String: Any]] = [:]
        var index: [PrintingKey: Int] = [:]
        for (row, object) in rows where row.count >= 1 {
            if let i = index[row.key] {
                result[i].count += row.count
                if result[i].condition.isEmpty { result[i].condition = row.condition }
                if result[i].name.isEmpty { result[i].name = row.name }
            } else {
                index[row.key] = result.count
                objects[row.key] = object
                result.append(row)
            }
        }
        return (result, objects)
    }
}
