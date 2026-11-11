import Foundation
import SwiftData

@Model
nonisolated final class CatalogSet {
    #Unique<CatalogSet>([\.groupID])

    var groupID: Int
    var gameID: String
    var name: String
    var abbreviation: String
    var publishedOn: Date?
    var fetchedAt: Date?
    var failed: Bool

    init(groupID: Int, gameID: String, name: String, abbreviation: String, publishedOn: Date?,
         fetchedAt: Date? = nil, failed: Bool = false) {
        self.groupID = groupID
        self.gameID = gameID
        self.name = name
        self.abbreviation = abbreviation
        self.publishedOn = publishedOn
        self.fetchedAt = fetchedAt
        self.failed = failed
    }
}

@Model
nonisolated final class CatalogProduct {
    #Unique<CatalogProduct>([\.productID])
    #Index<CatalogProduct>([\.gameID, \.searchKey], [\.gameID, \.cardKey], [\.groupID])

    var productID: Int
    var gameID: String
    var groupID: Int
    var name: String
    var cardName: String
    var searchKey: String
    var number: String
    var rarity: String
    var cardType: String
    var typeFacets: [String]
    var rulesText: String
    var url: String
    /// `CardName.searchKey(cardName)`: all printings of one card share it.
    var cardKey: String
    /// The type facets joined as `|a|b|`, so a filter can match `|Gear|`.
    var facetText: String
    var fieldsJSON: Data

    init(_ record: ProductRecord) {
        productID = record.productID
        gameID = record.gameID
        groupID = record.groupID
        name = record.name
        cardName = record.cardName
        searchKey = record.searchKey
        number = record.number
        rarity = record.rarity
        cardType = record.cardType
        typeFacets = record.typeFacets
        rulesText = record.rulesText
        url = record.url
        cardKey = CardName.searchKey(record.cardName)
        facetText = record.typeFacets.isEmpty ? "" : "|" + record.typeFacets.joined(separator: "|") + "|"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fieldsJSON = (try? encoder.encode(record.fields)) ?? Data("{}".utf8)
    }

    var record: ProductRecord {
        ProductRecord(
            productID: productID, gameID: gameID, groupID: groupID, name: name, cardName: cardName,
            searchKey: searchKey, number: number, rarity: rarity, cardType: cardType,
            typeFacets: typeFacets, rulesText: rulesText, url: url,
            fields: (try? JSONDecoder().decode([String: String].self, from: fieldsJSON)) ?? [:])
    }
}
