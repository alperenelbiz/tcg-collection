import Foundation

nonisolated struct SetRecord: Sendable, Equatable {
    let groupID: Int
    let gameID: String
    let name: String
    let abbreviation: String
    let publishedOn: Date?
}

nonisolated struct ProductRecord: Sendable, Equatable {
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

nonisolated enum ProductParser {
    static func sets(_ data: Data, game: GameDefinition) throws -> [SetRecord] {
        try JSONDecoder().decode(TCGResults<TCGGroup>.self, from: data).results.map {
            SetRecord(groupID: $0.groupId, gameID: game.id, name: $0.name,
                      abbreviation: $0.abbreviation ?? "", publishedOn: TCGDate.date($0.publishedOn))
        }
    }

    /// Keeps the products that have a card type. Every other product (boxes, packs, bundles) counts in `dropped`.
    static func products(_ data: Data, game: GameDefinition) throws -> (cards: [ProductRecord], dropped: Int) {
        let products = try JSONDecoder().decode(TCGResults<TCGProduct>.self, from: data).results
        var cards: [ProductRecord] = []
        var dropped = 0
        for product in products {
            // When a field name appears twice, the first one wins.
            let fields = Dictionary(product.extendedData.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
            let cardType = (fields[game.typeField] ?? "").trimmingCharacters(in: .whitespaces)
            guard !cardType.isEmpty else {
                dropped += 1
                continue
            }
            let cardName = CardName.base(product.name)
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
