import Foundation
import SwiftData

// The versions of the catalog schema. A store records the hashes of the entities it was written with; SwiftData opens
// it as the version whose models give the same hashes and migrates it from there. The entity name is the class name,
// so every version names its classes `CatalogSet` and `CatalogProduct`.

/// The schema phase 1 shipped without a version (`Schema([CatalogSet.self, CatalogProduct.self])`, recorded as 1.0.0).
/// Never change these two classes: a phase 1 store is recognised by their exact shape.
nonisolated enum CatalogSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [CatalogSet.self, CatalogProduct.self] }

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
}

/// Phase 2A: a set keeps the rules version of its products (P3); a product keeps its type facets only in `facetText`
/// (P5: the encoded array was 37.6 MB of the 243 MB store).
nonisolated enum CatalogSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [CatalogSet.self, CatalogProduct.self] }

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
        /// `CatalogRules.version` when the set's products were stored. The default is what a set migrated from V1
        /// gets: its products were stored under the phase 1 rules.
        var rulesVersion: Int = 1

        init(groupID: Int, gameID: String, name: String, abbreviation: String, publishedOn: Date?,
             fetchedAt: Date? = nil, failed: Bool = false, rulesVersion: Int) {
            self.groupID = groupID
            self.gameID = gameID
            self.name = name
            self.abbreviation = abbreviation
            self.publishedOn = publishedOn
            self.fetchedAt = fetchedAt
            self.failed = failed
            self.rulesVersion = rulesVersion
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
        var rulesText: String
        var url: String
        /// `CardName.searchKey(cardName)`: all printings of one card share it.
        var cardKey: String
        /// The type facets joined as `|a|b|`, so a filter can match `|Gear|`; empty for none.
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
            rulesText = record.rulesText
            url = record.url
            cardKey = CardName.searchKey(record.cardName)
            facetText = record.typeFacets.isEmpty ? "" : "|" + record.typeFacets.joined(separator: "|") + "|"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            fieldsJSON = (try? encoder.encode(record.fields)) ?? Data("{}".utf8)
        }

        /// The type facets read back from `facetText` (not stored: computed).
        var typeFacets: [String] {
            facetText.split(separator: "|").map(String.init)
        }

        var record: ProductRecord {
            ProductRecord(
                productID: productID, gameID: gameID, groupID: groupID, name: name, cardName: cardName,
                searchKey: searchKey, number: number, rarity: rarity, cardType: cardType,
                typeFacets: typeFacets, rulesText: rulesText, url: url,
                fields: (try? JSONDecoder().decode([String: String].self, from: fieldsJSON)) ?? [:])
        }
    }
}

/// V1 → V2 is lightweight: `rulesVersion` is added with its default (1), `typeFacets` is dropped.
nonisolated enum CatalogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CatalogSchemaV1.self, CatalogSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: CatalogSchemaV1.self, toVersion: CatalogSchemaV2.self)]
    }
}
