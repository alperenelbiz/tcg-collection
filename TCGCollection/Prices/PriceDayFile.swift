import Foundation

// The price day file (phase 5B, K1, K2): every price row of one archive day, compact and binary, in
// `support/price-days/<yyyy-MM-dd>.prices`. Written atomically, once; never rewritten.
//
// Layout, version 1. Every integer is little-endian and unsigned. Offsets are from the start of the file.
//
//   0   5 bytes   magic: ASCII "TCGPD"
//   5   UInt8     version (1)
//   6   10 bytes  the day, ASCII "yyyy-MM-dd"
//   16  UInt16    section count
//   18  sections, one after the other, each:
//         UInt32    category id (tcgcsv's)
//         UInt8     finish count F (at most 255)
//         F times:  UInt8 byte length L, then L bytes of the finish name in UTF-8 (L at most 255)
//         UInt32    row count R
//         R rows of 9 bytes each, sorted by (product id, finish index), no two rows with the same pair:
//           UInt32  product id
//           UInt8   finish index into this section's finish names (0-based)
//           UInt32  the shown price in whole cents (bits 0–30, 1 ... 2^31 − 1) and the low mark (bit 31: the price
//                   is the low price, `ShownPrice.isLow`)
//   The file ends exactly after the last section.
//
// The writer orders sections by `Games.all` first, then any other category ascending; finish names ascending (Unicode
// order); a row whose product id does not fit a UInt32, whose price is not a price (`PriceHistory.isPrice`) or rounds
// to 0 cents or over 2^31 − 1 cents ($21,474,836.47), or whose finish name is longer than 255 bytes, is not stored; of
// two rows with the same product and finish the first given is stored. A category with more than 255 finish names
// keeps the first 255 in order; rows of the others are not stored.
//
// The reader keeps the file's bytes (memory-mapped) and the sections' small directory; a lookup is a binary search of
// one section's rows.

nonisolated struct PriceDayRow: Sendable, Equatable {
    let productID: Int
    let finish: String
    let price: ShownPrice
}

nonisolated enum PriceDayFileError: Error, Equatable {
    /// The magic is wrong, the day is not `yyyy-MM-dd`, the version is 0, a finish name is not UTF-8, or bytes follow
    /// the last section. (Rows are not checked on open: a finish index out of range is skipped by a lookup.)
    case notADayFile
    /// The version byte is over `PriceDayFile.version`.
    case newerVersion
    /// The file ends before its header or a section does.
    case truncated
}

nonisolated enum PriceDayFile {
    static let version: UInt8 = 1
    static let magic: [UInt8] = Array("TCGPD".utf8)
    static let headerSize = 18
    static let rowSize = 9
    static let lowBit: UInt32 = 1 << 31
    static let maxCents = Int(Int32.max)

    /// The whole cents of a shown price (K2), or nil when it is not stored.
    static func cents(_ price: ShownPrice) -> UInt32? {
        guard PriceHistory.isPrice(price.amount) else { return nil }
        let cents = Int((price.amount * 100).rounded())
        guard cents >= 1, cents <= maxCents else { return nil }
        return UInt32(cents)
    }

    /// The file's bytes for one day. `rows`: category → rows.
    static func data(day: String, rows: [Int: [PriceDayRow]]) -> Data {
        let order = Games.all.map(\.categoryID)
        let categories = rows.keys.filter { $0 >= 0 && $0 <= Int(UInt32.max) }.sorted { a, b in
            switch (order.firstIndex(of: a), order.firstIndex(of: b)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        var dayBytes = Array(day.utf8.prefix(10))
        dayBytes += [UInt8](repeating: 0x20, count: 10 - dayBytes.count)
        out.append(contentsOf: dayBytes)
        append(UInt16(min(categories.count, Int(UInt16.max))), to: &out)
        for category in categories.prefix(Int(UInt16.max)) {
            let list = rows[category] ?? []
            let names = Array(Set(list.map(\.finish)).filter { $0.utf8.count <= 255 }.sorted().prefix(255))
            let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, UInt8($0.offset)) })
            var seen = Set<UInt64>()
            var packed: [(id: UInt32, finish: UInt8, cents: UInt32)] = []
            for row in list {
                guard row.productID >= 0, row.productID <= Int(UInt32.max), let finish = index[row.finish],
                      let cents = cents(row.price) else { continue }
                let id = UInt32(row.productID)
                guard seen.insert(UInt64(id) << 8 | UInt64(finish)).inserted else { continue }
                packed.append((id, finish, cents | (row.price.isLow ? lowBit : 0)))
            }
            packed.sort { ($0.id, $0.finish) < ($1.id, $1.finish) }
            append(UInt32(category), to: &out)
            out.append(UInt8(names.count))
            for name in names {
                out.append(UInt8(name.utf8.count))
                out.append(contentsOf: Array(name.utf8))
            }
            append(UInt32(packed.count), to: &out)
            out.reserveCapacity(out.count + packed.count * rowSize)
            for row in packed {
                append(row.id, to: &out)
                out.append(row.finish)
                append(row.cents, to: &out)
            }
        }
        return out
    }

    /// The file name of a day: `<yyyy-MM-dd>.prices`.
    static func fileName(day: String) -> String { "\(day).prices" }

    /// The days of the day files in `folder`: every regular file named `yyyy-MM-dd.prices` of a real calendar day. Any
    /// other name, a hidden file or a folder is ignored; a folder that is not there has none. (Whether a file reads is
    /// not checked.)
    static func days(in folder: URL) -> Set<String> {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var days = Set<String>()
        for url in urls {
            guard let match = url.lastPathComponent.wholeMatch(of: /(\d{4}-\d{2}-\d{2})\.prices/),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let day = String(match.1)
            guard PriceDay.after(PriceDay.before(day)) == day, PriceDay.before(day) != day else { continue }
            days.insert(day)
        }
        return days
    }

    /// A shown price as a `Price` (the market price, or the low price when it is marked low): `Price.shown` gives it back.
    static func price(_ shown: ShownPrice) -> Price {
        Price(market: shown.isLow ? nil : shown.amount, low: shown.isLow ? shown.amount : nil, mid: nil, high: nil)
    }

    /// Writes the file atomically; makes its folder when it is missing (`support/price-days`, never the user folder).
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// One day file, read for lookups. The bytes stay in the (memory-mapped) `Data`; only the sections' directory is
/// decoded on open.
nonisolated struct PriceDayReader: Sendable {
    private struct Section: Sendable {
        let category: Int
        let finishes: [String]
        /// The byte offset of the first row in the file.
        let rows: Int
        let count: Int
    }

    let day: String
    private let bytes: Data
    private let sections: [Section]

    /// Reads the file at `url`. An IO error (no file, no permission) is thrown as it is; a file that does not read as a
    /// day file throws `PriceDayFileError`.
    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        let (day, sections) = try data.withUnsafeBytes { try Self.directory($0) }
        self.day = day
        self.bytes = data
        self.sections = sections
    }

    /// The day and the sections of a file's bytes (indexed from 0).
    private static func directory(_ bytes: UnsafeRawBufferPointer) throws -> (String, [Section]) {
        let n = bytes.count
        let magic = PriceDayFile.magic
        guard n >= magic.count else {
            if Array(bytes) == Array(magic.prefix(n)) { throw PriceDayFileError.truncated }
            throw PriceDayFileError.notADayFile
        }
        guard Array(bytes[0..<magic.count]) == magic else { throw PriceDayFileError.notADayFile }
        guard n >= 6 else { throw PriceDayFileError.truncated }
        let version = bytes[5]
        if version == 0 { throw PriceDayFileError.notADayFile }
        if version > PriceDayFile.version { throw PriceDayFileError.newerVersion }
        guard n >= 16 else { throw PriceDayFileError.truncated }
        guard let day = String(bytes: bytes[6..<16], encoding: .ascii),
              day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { throw PriceDayFileError.notADayFile }
        guard n >= PriceDayFile.headerSize else { throw PriceDayFileError.truncated }

        func uint(_ offset: Int, _ size: Int) -> Int {
            var value = 0
            for i in 0..<size { value |= Int(bytes[offset + i]) << (8 * i) }
            return value
        }
        var at = PriceDayFile.headerSize
        let sectionCount = uint(16, 2)
        var sections: [Section] = []
        for _ in 0..<sectionCount {
            guard n >= at + 5 else { throw PriceDayFileError.truncated }
            let category = uint(at, 4)
            let finishCount = Int(bytes[at + 4])
            at += 5
            var finishes: [String] = []
            for _ in 0..<finishCount {
                guard n >= at + 1 else { throw PriceDayFileError.truncated }
                let length = Int(bytes[at])
                guard n >= at + 1 + length else { throw PriceDayFileError.truncated }
                guard let name = String(bytes: bytes[(at + 1)..<(at + 1 + length)], encoding: .utf8) else {
                    throw PriceDayFileError.notADayFile
                }
                finishes.append(name)
                at += 1 + length
            }
            guard n >= at + 4 else { throw PriceDayFileError.truncated }
            let count = uint(at, 4)
            at += 4
            guard n - at >= count * PriceDayFile.rowSize else { throw PriceDayFileError.truncated }
            sections.append(Section(category: category, finishes: finishes, rows: at, count: count))
            at += count * PriceDayFile.rowSize
        }
        guard at == n else { throw PriceDayFileError.notADayFile }
        return (day, sections)
    }

    /// The categories the file has a section of, in the file's order.
    var categories: [Int] { sections.map(\.category) }

    /// The number of rows stored for a category (0 for one the file lacks), out-of-range finish indexes included.
    func rowCount(category: Int) -> Int { sections.filter { $0.category == category }.reduce(0) { $0 + $1.count } }

    /// Every row of one category in the file's order (product id, then finish index); none for a category the file
    /// lacks. A row whose finish index is out of range is skipped. (Phase 5B task 2: the price table of a day whose
    /// archive is gone, and the 5A pass's day-file adapter.)
    func rows(category: Int) -> [PriceDayRow] {
        guard let section = sections.first(where: { $0.category == category }) else { return [] }
        return bytes.withUnsafeBytes { raw -> [PriceDayRow] in
            var out: [PriceDayRow] = []
            out.reserveCapacity(section.count)
            for i in 0..<section.count {
                let offset = section.rows + i * PriceDayFile.rowSize
                let id = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let finish = Int(raw[offset + 4])
                let value = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 5, as: UInt32.self))
                guard finish < section.finishes.count else { continue }
                out.append(PriceDayRow(productID: Int(id), finish: section.finishes[finish],
                                       price: ShownPrice(amount: Double(value & ~PriceDayFile.lowBit) / 100,
                                                         isLow: value & PriceDayFile.lowBit != 0)))
            }
            return out
        }
    }

    /// Finish → shown price of one product on this day; `[:]` when the file has no row of it.
    func prices(category: Int, productID: Int) -> [String: ShownPrice] {
        guard productID >= 0, productID <= Int(UInt32.max),
              let section = sections.first(where: { $0.category == category }) else { return [:] }
        let target = UInt32(productID)
        return bytes.withUnsafeBytes { raw -> [String: ShownPrice] in
            func id(_ i: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: section.rows + i * PriceDayFile.rowSize, as: UInt32.self))
            }
            // The first row whose product id is not below the target.
            var low = 0, high = section.count
            while low < high {
                let mid = (low + high) / 2
                if id(mid) < target { low = mid + 1 } else { high = mid }
            }
            var found: [String: ShownPrice] = [:]
            var i = low
            while i < section.count, id(i) == target {
                let offset = section.rows + i * PriceDayFile.rowSize
                let finish = Int(raw[offset + 4])
                let value = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 5, as: UInt32.self))
                if finish < section.finishes.count {
                    let cents = value & ~PriceDayFile.lowBit
                    found[section.finishes[finish]] = ShownPrice(amount: Double(cents) / 100,
                                                                 isLow: value & PriceDayFile.lowBit != 0)
                }
                i += 1
            }
            return found
        }
    }
}
