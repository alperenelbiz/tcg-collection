import Foundation

nonisolated enum GameUserFileError: Error, Equatable {
    case newerVersion(Int)
    case notAnObject
    case malformedVersion
    case malformedCollection
    /// `wanted`, `forSale` or `sold` (the name) is neither an array nor null.
    case malformedList(String)
}

/// The raw JSON of one list: each parsed entry's own object, by the entry's key, and the elements that could not be
/// parsed, in their order.
nonisolated private struct RawList<Key: Hashable> {
    var objects: [Key: [String: Any]] = [:]
    var unparseable: [Any] = []
}

/// The decoded top-level JSON object, kept so that keys this app does not know survive a rewrite.
/// It also keeps each parsed entry's raw object and the array elements that could not be parsed, for every list.
/// Never mutated after creation, so sharing it between threads is safe.
nonisolated private final class JSONObjectBox: @unchecked Sendable {
    let object: [String: Any]
    let collection: RawList<PrintingKey>
    let wanted: RawList<String>
    let forSale: RawList<PrintingKey>
    /// The sold log is never merged, so two records can be equal: each parsed record keeps its object, in file order.
    let sold: [(record: SoldRecord, object: [String: Any])]
    let soldUnparseable: [Any]

    init(_ object: [String: Any], collection: RawList<PrintingKey> = .init(), wanted: RawList<String> = .init(),
         forSale: RawList<PrintingKey> = .init(), sold: [(record: SoldRecord, object: [String: Any])] = [],
         soldUnparseable: [Any] = []) {
        self.object = object
        self.collection = collection
        self.wanted = wanted
        self.forSale = forSale
        self.sold = sold
        self.soldUnparseable = soldUnparseable
    }
}

/// One game's user file (`<game id>.json`): `version`, `collection`, `wanted`, `forSale`, `sold`, and whatever else a
/// newer app wrote. The version stays 1 (C1): a phase 2B build keeps the three lists as unknown keys.
/// - A list key the file has (even `[]` or null) is written back; one it does not have is written only once its list
///   has an entry, so a phase 2B file keeps its bytes through a read and a rewrite.
/// - Each entry keeps the keys this app does not know; entries that cannot be parsed are kept, in their order, after
///   the parsed ones. Wanted and for-sale entries of one key are merged on read, as collection rows are; sold records
///   never are.
/// - A for-sale count over the owned count is read as it is (Review Focus 2); `UserLibrary` clamps it at the next change.
nonisolated struct GameUserFile: Sendable, Equatable {
    static let currentVersion = 1

    var collection: [CollectionRow]
    var wanted: [WantedEntry]
    var forSale: [SaleEntry]
    var sold: [SoldRecord]
    private let raw: JSONObjectBox

    init() {
        collection = []
        wanted = []
        forSale = []
        sold = []
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
        let rows = Self.split(try Self.array(object, "collection", else: .malformedCollection), Self.row)
        let wanted = Self.split(try Self.array(object, "wanted", else: .malformedList("wanted")), Self.wantedEntry)
        let forSale = Self.split(try Self.array(object, "forSale", else: .malformedList("forSale")), Self.saleEntry)
        let sold = Self.split(try Self.array(object, "sold", else: .malformedList("sold")), Self.soldRecord)

        let (cleanRows, rowObjects) = Self.merged(rows.parsed, key: \.key, count: \.count) { first, later in
            first.count += later.count
            if first.condition.isEmpty { first.condition = later.condition }
            if first.name.isEmpty { first.name = later.name }
        }
        // The first entry's pin stays.
        let (cleanWanted, wantedObjects) = Self.merged(wanted.parsed, key: \.cardKey, count: \.count) { first, later in
            first.count += later.count
            if first.name.isEmpty { first.name = later.name }
        }
        let (cleanForSale, saleObjects) = Self.merged(forSale.parsed, key: \.key, count: \.count) { first, later in
            first.count += later.count
            if first.name.isEmpty { first.name = later.name }
        }
        collection = cleanRows
        self.wanted = cleanWanted
        self.forSale = cleanForSale
        self.sold = sold.parsed.map { $0.0 }
        raw = JSONObjectBox(object,
                            collection: RawList(objects: rowObjects, unparseable: rows.unparseable),
                            wanted: RawList(objects: wantedObjects, unparseable: wanted.unparseable),
                            forSale: RawList(objects: saleObjects, unparseable: forSale.unparseable),
                            sold: sold.parsed.map { (record: $0.0, object: $0.1) },
                            soldUnparseable: sold.unparseable)
    }

    /// UTF-8, pretty-printed, sorted keys, ending with a newline.
    func data() throws -> Data {
        let encoder = JSONEncoder()
        var object = raw.object
        object["version"] = Self.currentVersion
        // Every key of a collection row is always written.
        object["collection"] = try Self.objects(collection.map { ($0, raw.collection.objects[$0.key]) }, owned: [], encoder: encoder)
            + raw.collection.unparseable
        // Each sold record takes the first unused object read for an equal record, so equal records keep their own keys.
        var unusedSold = raw.sold
        let soldPairs = sold.map { record -> (SoldRecord, [String: Any]?) in
            guard let i = unusedSold.firstIndex(where: { $0.record == record }) else { return (record, nil) }
            return (record, unusedSold.remove(at: i).object)
        }
        let lists: [(String, [Any])] = [
            ("wanted", try Self.objects(wanted.map { ($0, raw.wanted.objects[$0.cardKey]) }, owned: WantedEntry.storedKeys,
                                        encoder: encoder) + raw.wanted.unparseable),
            ("forSale", try Self.objects(forSale.map { ($0, raw.forSale.objects[$0.key]) }, owned: SaleEntry.storedKeys,
                                         encoder: encoder) + raw.forSale.unparseable),
            ("sold", try Self.objects(soldPairs, owned: SoldRecord.storedKeys, encoder: encoder) + raw.soldUnparseable),
        ]
        // A key the file did not have stays out while its list is empty.
        for (key, elements) in lists where !elements.isEmpty || raw.object[key] != nil {
            object[key] = elements
        }
        var out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        return out
    }

    /// The four lists are equal (what the app reads and changes); keys it does not know are not compared.
    func hasSameLists(as other: GameUserFile) -> Bool {
        collection == other.collection && wanted == other.wanted && forSale == other.forSale && sold == other.sold
    }

    /// Equal lists, and equal keys this app does not know. A copy of one read file differs only by its lists.
    static func == (lhs: GameUserFile, rhs: GameUserFile) -> Bool {
        lhs.hasSameLists(as: rhs) && (lhs.raw === rhs.raw || (try? lhs.data()) == (try? rhs.data()))
    }

    // MARK: Writing

    /// Each entry as a JSON object: the object it was read from (the keys this app does not know) with the entry's own
    /// keys written over it. The keys the entry owns are taken out first, so a nil pin or price leaves no key behind.
    private static func objects<Entry: Encodable>(_ entries: [(Entry, [String: Any]?)], owned: Set<String>,
                                                   encoder: JSONEncoder) throws -> [Any] {
        try entries.map { entry, object in
            var merged = (object ?? [:]).filter { !owned.contains($0.key) }
            let known = try JSONSerialization.jsonObject(with: encoder.encode(entry)) as? [String: Any] ?? [:]
            merged.merge(known.mapValues(shortest)) { _, new in new }
            return merged
        }
    }

    /// A fraction as Swift prints it (`0.07`). JSONSerialization would write 17 digits (`0.070000000000000007`), which
    /// does not read back as the same Double.
    private static func shortest(_ value: Any) -> Any {
        guard let number = value as? NSNumber, CFNumberIsFloatType(number) else { return value }
        let decimal = NSDecimalNumber(string: "\(number.doubleValue)", locale: Locale(identifier: "en_US_POSIX"))
        return decimal == .notANumber ? value : decimal
    }

    // MARK: Reading

    /// The array under `key`: none or null is empty; anything else that is not an array refuses the file.
    private static func array(_ object: [String: Any], _ key: String, else error: GameUserFileError) throws -> [Any] {
        guard let value = object[key], !(value is NSNull) else { return [] }
        guard let array = value as? [Any] else { throw error }
        return array
    }

    /// The elements `parse` reads, each with its object, and the others, in their order.
    private static func split<Entry>(_ elements: [Any], _ parse: ([String: Any]) -> Entry?)
        -> (parsed: [(Entry, [String: Any])], unparseable: [Any]) {
        var parsed: [(Entry, [String: Any])] = []
        var unparseable: [Any] = []
        for element in elements {
            if let object = element as? [String: Any], let entry = parse(object) {
                parsed.append((entry, object))
            } else {
                unparseable.append(element)
            }
        }
        return (parsed, unparseable)
    }

    /// Drops entries with count < 1; merges entries of one key into the first (its position and raw object win).
    private static func merged<Entry, Key: Hashable>(_ entries: [(Entry, [String: Any])], key: (Entry) -> Key,
                                                     count: (Entry) -> Int, into merge: (inout Entry, Entry) -> Void)
        -> ([Entry], [Key: [String: Any]]) {
        var result: [Entry] = []
        var objects: [Key: [String: Any]] = [:]
        var index: [Key: Int] = [:]
        for (entry, object) in entries where count(entry) >= 1 {
            let k = key(entry)
            if let i = index[k] {
                merge(&result[i], entry)
            } else {
                index[k] = result.count
                objects[k] = object
                result.append(entry)
            }
        }
        return (result, objects)
    }

    /// A whole JSON number; not a boolean, not a fraction.
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d == d.rounded(), abs(d) < 9e15 else { return nil }
        return number.intValue
    }

    /// A JSON number; not a boolean. JSONSerialization reads a number of many digits (`0.070000000000000007`, as a phase 2B
    /// build rewrites `0.07`) as an NSDecimalNumber, whose `doubleValue` is off (`0.07000000000000003`): its text is read
    /// as a Double instead, which gives the number that was written.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if let decimal = number as? NSDecimalNumber, let exact = Double(decimal.stringValue) { return exact }
        return number.doubleValue
    }

    /// Trimmed; empty is `Normal`.
    private static func finish(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Normal" : trimmed
    }

    private static func row(_ o: [String: Any]) -> CollectionRow? {
        guard let productID = o["productID"].flatMap(integer),
              let rawFinish = o["finish"] as? String,
              let count = o["count"].flatMap(integer) else { return nil }
        return CollectionRow(productID: productID, finish: finish(rawFinish), count: count,
                             condition: o["condition"] as? String ?? "", name: o["name"] as? String ?? "")
    }

    /// Needs `cardKey` and `count`; a pin needs both its fields.
    private static func wantedEntry(_ o: [String: Any]) -> WantedEntry? {
        guard let cardKey = o["cardKey"] as? String, let count = o["count"].flatMap(integer) else { return nil }
        let pinProductID = o["pinProductID"].flatMap(integer), pinFinish = o["pinFinish"] as? String
        let pinned = pinProductID != nil && pinFinish != nil
        return WantedEntry(cardKey: cardKey, name: o["name"] as? String ?? "", count: count,
                           pinProductID: pinned ? pinProductID : nil, pinFinish: pinned ? pinFinish.map(finish) : nil)
    }

    private static func saleEntry(_ o: [String: Any]) -> SaleEntry? {
        guard let productID = o["productID"].flatMap(integer),
              let rawFinish = o["finish"] as? String,
              let count = o["count"].flatMap(integer) else { return nil }
        return SaleEntry(productID: productID, finish: finish(rawFinish), count: count, name: o["name"] as? String ?? "")
    }

    /// Read as written: a record is never edited, not even its finish.
    private static func soldRecord(_ o: [String: Any]) -> SoldRecord? {
        guard let productID = o["productID"].flatMap(integer),
              let finish = o["finish"] as? String,
              let count = o["count"].flatMap(integer),
              let day = o["day"] as? String else { return nil }
        return SoldRecord(productID: productID, finish: finish, count: count, name: o["name"] as? String ?? "", day: day,
                          price: o["price"].flatMap(number), priceIsLow: o["priceIsLow"] as? Bool ?? false)
    }
}
