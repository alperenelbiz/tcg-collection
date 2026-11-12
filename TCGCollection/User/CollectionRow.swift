import Foundation

/// One printing of a card: a catalog product and a finish.
nonisolated struct PrintingKey: Hashable, Sendable, Codable {
    let productID: Int
    let finish: String
}

/// One owned printing. The stored JSON has exactly five keys; `key` and `id` are computed.
nonisolated struct CollectionRow: Codable, Sendable, Equatable, Identifiable {
    var productID: Int
    var finish: String
    var count: Int
    var condition: String
    var name: String

    var key: PrintingKey { PrintingKey(productID: productID, finish: finish) }
    var id: PrintingKey { key }

    init(productID: Int, finish: String, count: Int, condition: String, name: String) {
        self.productID = productID
        self.finish = finish
        self.count = count
        self.condition = condition
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case productID, finish, count, condition, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productID = try c.decode(Int.self, forKey: .productID)
        finish = try c.decode(String.self, forKey: .finish)
        count = try c.decode(Int.self, forKey: .count)
        condition = try c.decodeIfPresent(String.self, forKey: .condition) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}
