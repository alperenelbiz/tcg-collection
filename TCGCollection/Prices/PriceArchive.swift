import Foundation

nonisolated struct Price: Codable, Sendable, Equatable {
    let market: Double?
    let low: Double?
    let mid: Double?
    let high: Double?
}

/// The price to show for a printing: the market price, or the low price when there is no market price.
nonisolated struct ShownPrice: Sendable, Equatable {
    let amount: Double
    let isLow: Bool
}

nonisolated extension Price {
    /// A price of 0 counts as missing.
    var shown: ShownPrice? {
        if let market, market > 0 { return ShownPrice(amount: market, isLow: false) }
        if let low, low > 0 { return ShownPrice(amount: low, isLow: true) }
        return nil
    }
}

nonisolated struct PriceRow: Sendable, Equatable {
    let productID: Int
    let finish: String
    let price: Price
}

nonisolated enum PriceArchiveError: Error {
    case cannotOpen(String)
    case readFailed(String)
}

/// Reads tcgcsv's daily `prices-YYYY-MM-DD.ppmd.7z` with the system libarchive.
nonisolated enum PriceArchive {
    private struct Response: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let productId: Int
        let lowPrice: Double?
        let midPrice: Double?
        let highPrice: Double?
        let marketPrice: Double?
        let subTypeName: String?
    }

    /// Calls `each` for every `YYYY-MM-DD/<category>/<group>/prices` entry whose category is in
    /// `categories`. Other entries are skipped without being read.
    static func read(_ file: URL, categories: Set<Int>,
                     each: (_ category: Int, _ group: Int, _ rows: [PriceRow]) -> Void) throws {
        let archive = archive_read_new()
        defer { _ = archive_read_free(archive) }
        _ = archive_read_support_format_7zip(archive)
        _ = archive_read_support_filter_all(archive)
        guard archive_read_open_filename(archive, file.path, 1 << 16) == 0 else {
            throw PriceArchiveError.cannotOpen(message(archive))
        }
        var entry: OpaquePointer?
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var code = archive_read_next_header(archive, &entry)
        while code == 0 {
            let path = String(cString: archive_entry_pathname(entry))
            let parts = path.split(separator: "/")
            if parts.count == 4, parts[3] == "prices",
               let category = Int(parts[1]), categories.contains(category), let group = Int(parts[2]) {
                var data = Data()
                while true {
                    let count = archive_read_data(archive, &buffer, buffer.count)
                    if count < 0 { throw PriceArchiveError.readFailed(message(archive)) }
                    if count == 0 { break }
                    data.append(buffer, count: count)
                }
                let response: Response
                do { response = try JSONDecoder().decode(Response.self, from: data) }
                catch { throw PriceArchiveError.readFailed("bad JSON in \(path)") }
                let rows = response.results.map {
                    PriceRow(productID: $0.productId, finish: $0.subTypeName ?? "Normal",
                             price: Price(market: $0.marketPrice, low: $0.lowPrice, mid: $0.midPrice, high: $0.highPrice))
                }
                each(category, group, rows)
            } else if archive_read_data_skip(archive) != 0 {
                throw PriceArchiveError.readFailed(message(archive))
            }
            code = archive_read_next_header(archive, &entry)
        }
        guard code == 1 else { throw PriceArchiveError.readFailed(message(archive)) }
    }

    /// The day (`YYYY-MM-DD`) in the first entry's path, or nil when the file cannot be read.
    static func day(of file: URL) -> String? {
        let archive = archive_read_new()
        defer { _ = archive_read_free(archive) }
        _ = archive_read_support_format_7zip(archive)
        _ = archive_read_support_filter_all(archive)
        guard archive_read_open_filename(archive, file.path, 1 << 16) == 0 else { return nil }
        var entry: OpaquePointer?
        guard archive_read_next_header(archive, &entry) == 0 else { return nil }
        let first = String(cString: archive_entry_pathname(entry)).split(separator: "/").first.map(String.init)
        guard let first, first.count == 10, first.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        return first
    }

    private static func message(_ archive: OpaquePointer?) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unknown libarchive error"
    }
}
