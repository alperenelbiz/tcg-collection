import Foundation

nonisolated struct SetRecord: Sendable, Equatable {
    let groupID: Int
    let gameID: String
    let name: String
    let abbreviation: String
    let publishedOn: Date?
}

nonisolated struct ProductRecord: Sendable, Hashable {
    let productID: Int
    let gameID: String
    let groupID: Int
    let name: String
    let cardName: String
    let searchKey: String
    let number: String
    let rarity: String
    let cardType: String
    let typeFacets: [String]
    let rulesText: String
    let url: String
    let fields: [String: String]
}

nonisolated enum ProductParserError: Error, Equatable {
    /// The body says `"success":false`: its `results` cannot be trusted, even when empty.
    case unsuccessful
}

nonisolated enum ProductParser {
    private static func results<T: Decodable & Sendable>(_ type: T.Type, in data: Data) throws -> [T] {
        let body = try JSONDecoder().decode(TCGResults<T>.self, from: data)
        guard body.success != false else { throw ProductParserError.unsuccessful }
        return body.results
    }

    static func sets(_ data: Data, game: GameDefinition) throws -> [SetRecord] {
        try results(TCGGroup.self, in: data).map {
            SetRecord(groupID: $0.groupId, gameID: game.id, name: $0.name,
                      abbreviation: $0.abbreviation ?? "", publishedOn: TCGDate.date($0.publishedOn))
        }
    }

    /// Keeps the products that are cards (see `GameDefinition.isCard`). Every other product (boxes, packs, bundles) counts in `dropped`.
    static func products(_ data: Data, game: GameDefinition) throws -> (cards: [ProductRecord], dropped: Int) {
        let products = try results(TCGProduct.self, in: data)
        var cards: [ProductRecord] = []
        var dropped = 0
        for product in products {
            // When a field name appears twice, the first one wins.
            let fields = Dictionary(product.extendedData.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
            let cardType = (fields[game.typeField] ?? "").trimmingCharacters(in: .whitespaces)
            guard game.isCard(fields: fields) else {
                dropped += 1
                continue
            }
            let cardName = CardName.base(product.name, game: game)
            cards.append(ProductRecord(
                productID: product.productId, gameID: game.id, groupID: product.groupId,
                name: product.name, cardName: cardName, searchKey: CardName.searchKey(cardName),
                number: fields["Number"] ?? "", rarity: fields["Rarity"] ?? "",
                cardType: cardType, typeFacets: game.typeFacets(cardType),
                rulesText: RulesText.plain(fields[game.textField] ?? ""),
                url: product.url, fields: fields))
        }
        return (cards, dropped)
    }
}
