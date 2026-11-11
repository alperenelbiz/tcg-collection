import Foundation

/// A tcgcsv response: `{"success":…,"errors":[…],"results":[…],"totalItems":…}`.
nonisolated struct TCGResults<T: Decodable & Sendable>: Decodable, Sendable {
    let results: [T]
}

nonisolated struct TCGGroup: Decodable, Sendable {
    let groupId: Int
    let name: String
    let abbreviation: String?
    let publishedOn: String
    let categoryId: Int
}

nonisolated struct TCGProduct: Decodable, Sendable {
    let productId: Int
    let name: String
    let groupId: Int
    let url: String
    let imageUrl: String?
    let extendedData: [Field]

    struct Field: Decodable, Sendable {
        let name: String
        let value: String
    }
}

nonisolated enum TCGDate {
    /// Reads `2026-10-02T00:00:00` and `2026-10-13T14:05:57.413`, both as UTC.
    static func date(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
