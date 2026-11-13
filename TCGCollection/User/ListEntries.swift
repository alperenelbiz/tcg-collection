import Foundation

/// A card on the Wanted list (C2): the catalog's card key, the saved name, a count, and optionally a pin, the printing
/// whose price stands for the card. The stored JSON has these five keys at most; a nil pin writes no pin key.
nonisolated struct WantedEntry: Codable, Sendable, Equatable, Identifiable {
    var cardKey: String
    var name: String
    var count: Int
    var pinProductID: Int?
    var pinFinish: String?

    var id: String { cardKey }
    /// The pinned printing: both pin fields, else none.
    var pin: PrintingKey? {
        guard let pinProductID, let pinFinish else { return nil }
        return PrintingKey(productID: pinProductID, finish: pinFinish)
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case cardKey, name, count, pinProductID, pinFinish }
    /// The JSON keys this type writes; the game file takes them out of the object it read before writing them.
    static let storedKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

/// A printing on the For Sale list (C3): same key and name rule as a collection row. Never over the owned count of its
/// printing in a written file (C8).
nonisolated struct SaleEntry: Codable, Sendable, Equatable, Identifiable {
    var productID: Int
    var finish: String
    var count: Int
    var name: String

    var key: PrintingKey { PrintingKey(productID: productID, finish: finish) }
    var id: PrintingKey { key }

    enum CodingKeys: String, CodingKey, CaseIterable { case productID, finish, count, name }
    /// The JSON keys this type writes; the game file takes them out of the object it read before writing them.
    static let storedKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

/// One Sold action (C4, A11): the printing, the copies, the day (`yyyy-MM-dd`, the device's calendar day) and the shown
/// price per copy that day (none: no `price` key). Records are appended, never merged or edited.
nonisolated struct SoldRecord: Codable, Sendable, Equatable {
    var productID: Int
    var finish: String
    var count: Int
    var name: String
    var day: String
    var price: Double?
    var priceIsLow: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case productID, finish, count, name, day, price, priceIsLow }
    /// The JSON keys this type writes; the game file takes them out of the object it read before writing them.
    static let storedKeys = Set(CodingKeys.allCases.map(\.rawValue))
}
