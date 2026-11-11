import Foundation
import Testing
@testable import TCGCollection2

/// A store in a fresh temporary directory: the 14 Riftbound sets of groups-89.json, and each game's
/// fixture products in its set (Magic 24684, Yu-Gi-Oh! 24815, Riftbound 24819, Cyberpunk 24884).
/// Cyberpunk and the others have no row in groups-89.json, so `replaceProducts` creates their set rows.
private func filledStore() async throws -> CatalogStore {
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.store")
    let store = try CatalogStore(url: url)
    try await store.upsertSets(try ProductParser.sets(fixture("groups-89.json"), game: Games.game("riftbound")!))
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    for (file, game, group) in [("products-1.json", "magic-the-gathering", 24684), ("products-2.json", "yu-gi-oh", 24815),
                                ("products-89.json", "riftbound", 24819), ("products-92.json", "cyberpunk", 24884)] {
        let (cards, _) = try ProductParser.products(fixture(file), game: Games.game(game)!)
        try await store.replaceProducts(of: group, with: cards, at: date)
    }
    return store
}

struct CatalogStoreTests {
    @Test func searchFindsACardByAnyWordOrder() async throws {
        let s = try await filledStore()
        #expect(try await s.search(game: "magic-the-gathering", text: "compliance chandra", filter: .init(), limit: 50).map(\.name) == ["Chandra, Chill of Compliance"])
        #expect(try await s.search(game: "cyberpunk", text: "KERRY", filter: .init(), limit: 50).first?.cover.productID == 719684)
        #expect(try await s.search(game: "yu-gi-oh", text: "chandra", filter: .init(), limit: 50).isEmpty)   // other game
    }

    // The Magic fixture has no card with two printings; Swiftwind Panther Warrior (Yu-Gi-Oh!) has two.
    @Test func printingsOfOneCardAreOneResult() async throws {
        let s = try await filledStore()
        let hits = try await s.search(game: "yu-gi-oh", text: "swiftwind panther", filter: .init(), limit: 50)
        #expect(hits.count == 1); #expect(hits[0].printings == 2)
        #expect(Set(hits[0].productIDs) == [719834, 719835])
        let printings = try await s.printings(game: "yu-gi-oh", cardKey: hits[0].id)
        #expect(printings.count == hits[0].printings)
        #expect(Set(printings.map(\.productID)) == [719834, 719835])
    }

    @Test func aBracketOnlyNameBecomesOneCard() async throws {
        let s = try await filledStore()
        let hits = try await s.search(game: "magic-the-gathering", text: "stingcaster", filter: .init(), limit: 50)
        #expect(hits.map(\.name) == ["Stingcaster Mage"]); #expect(hits[0].cover.productID == 692997)
    }

    @Test func emptyTextListsCardsByName() async throws {
        let s = try await filledStore()
        let all = try await s.search(game: "riftbound", text: "  ", filter: .init(), limit: 2)
        #expect(all.count == 2); #expect(all.map(\.name) == all.map(\.name).sorted())
    }

    @Test func limitCountsCardsNotProducts() async throws {
        let s = try await filledStore()
        let one = try await s.search(game: "yu-gi-oh", text: "", filter: .init(), limit: 1)
        #expect(one.count == 1)
        let all = try await s.search(game: "yu-gi-oh", text: "", filter: .init(), limit: 50)
        #expect(all.map(\.printings).reduce(0, +) == 3)   // token + 2 printings of the warrior
    }

    @Test func filtersNarrowTheResult() async throws {
        let s = try await filledStore()
        #expect(try await s.search(game: "riftbound", text: "", filter: .init(typeFacet: "Gear"), limit: 50).map(\.cover.productID) == [721334])
        #expect(try await s.search(game: "riftbound", text: "", filter: .init(groupID: 1), limit: 50).isEmpty)
        #expect(try await s.search(game: "yu-gi-oh", text: "", filter: .init(rarity: "Starlight Rare"), limit: 50).map(\.cover.productID) == [719835])
        #expect(try await s.typeFacets(game: "yu-gi-oh").contains("Token"))
        #expect(try await s.rarities(game: "yu-gi-oh") == ["Starlight Rare", "Super Rare"])
    }

    @Test func coverIsThePrintingFromTheNewestSet() async throws {
        let s = try await filledStore()
        func record(_ id: Int, group: Int) -> ProductRecord {
            ProductRecord(productID: id, gameID: "riftbound", groupID: group, name: "Twin", cardName: "Twin",
                          searchKey: "twin", number: "", rarity: "", cardType: "Unit", typeFacets: ["Unit"],
                          rulesText: "", url: "", fields: [:])
        }
        try await s.replaceProducts(of: 24819, with: [record(1, group: 24819)], at: .now)   // set published 2026-10-23
        let older = try #require(try await s.sets(game: "riftbound").first { $0.groupID != 24819 && $0.publishedOn != nil })
        try await s.replaceProducts(of: older.groupID, with: [record(2, group: older.groupID)], at: .now)
        let hit = try #require(try await s.search(game: "riftbound", text: "twin", filter: .init(), limit: 5).first)
        let newest = try await s.sets(game: "riftbound").first { $0.groupID == 24819 || $0.groupID == older.groupID }!
        #expect(hit.printings == 2)
        #expect(hit.cover.groupID == newest.groupID)
        #expect(try await s.printings(game: "riftbound", cardKey: "twin").first?.groupID == newest.groupID)
    }

    @Test func searchPagesAcrossBatches() async throws {
        let s = try await filledStore()
        func record(_ id: Int, _ name: String) -> ProductRecord {
            ProductRecord(productID: id, gameID: "riftbound", groupID: 24819, name: name, cardName: name,
                          searchKey: CardName.searchKey(name), number: "", rarity: "", cardType: "Unit",
                          typeFacets: ["Unit"], rulesText: "", url: "", fields: [:])
        }
        // Key order with productID: ant(1) ant(2) ant(3) | bee(4) bee(5) | cat red(6) cat red(7) | dog(8)
        // With batchSize 2 the batches are [1,2] [3,4] [5,6] [7,8]: ant and bee and cat red all straddle a boundary.
        let rows = [record(1, "Zz Ant"), record(2, "Zz Ant"), record(3, "Zz Ant"), record(4, "Zz Bee"),
                    record(5, "Zz Bee"), record(6, "Zz Cat Red"), record(7, "Zz Cat Red"), record(8, "Zz Dog")]
        try await s.replaceProducts(of: 24819, with: rows, at: .now)

        let all = try await s.search(game: "riftbound", text: "zz", filter: .init(), limit: 50, batchSize: 2)
        #expect(all.map(\.name) == ["Zz Ant", "Zz Bee", "Zz Cat Red", "Zz Dog"])
        #expect(all.map(\.printings) == [3, 2, 2, 1])

        let two = try await s.search(game: "riftbound", text: "zz", filter: .init(), limit: 2, batchSize: 2)   // stops mid-scan
        #expect(two.map(\.name) == ["Zz Ant", "Zz Bee"]); #expect(two.map(\.printings) == [3, 2])

        let words = try await s.search(game: "riftbound", text: "zz red", filter: .init(), limit: 50, batchSize: 2)   // extra word in memory
        #expect(words.map(\.name) == ["Zz Cat Red"]); #expect(words[0].printings == 2)
        #expect(try await s.search(game: "riftbound", text: "zz", filter: .init(), limit: 50) == all)   // same as default batch
    }

    @Test func productLookupKeepsEveryField() async throws {
        let s = try await filledStore()
        let (cards, _) = try ProductParser.products(fixture("products-1.json"), game: Games.game("magic-the-gathering")!)
        let expected = try #require(cards.first { $0.productID == 692994 })
        #expect(try await s.product(692994) == expected)
        #expect(try await s.product(1) == nil)
    }

    @Test func replaceProductsIsRepeatableAndRecordsTheDate() async throws {
        let s = try await filledStore(); let d = Date(timeIntervalSince1970: 1_800_000_000)
        let (cards, _) = try ProductParser.products(fixture("products-92.json"), game: Games.game("cyberpunk")!)
        try await s.replaceProducts(of: 24884, with: cards, at: d); try await s.replaceProducts(of: 24884, with: cards, at: d)
        #expect(try await s.search(game: "cyberpunk", text: "", filter: .init(), limit: 50).count == cards.count)
        #expect(try await s.fetchDates(game: "cyberpunk")[24884] == d)
    }

    @Test func upsertSetsKeepsFetchDatesAndProgressCounts() async throws {
        let s = try await filledStore()                    // filledStore upserts groups-89 and fills set 24819
        try await s.upsertSets(try ProductParser.sets(fixture("groups-89.json"), game: Games.game("riftbound")!))
        try await s.markFailed(24832)
        #expect(try await s.progress(game: "riftbound") == SetProgress(total: 14, fetched: 1, failed: 1))
        try await s.markFailed(24819)                      // keeps its fetch date
        #expect(try await s.fetchDates(game: "riftbound")[24819] != nil)
        try await s.replaceProducts(of: 24819, with: [], at: .now)   // success clears `failed`
        #expect(try await s.progress(game: "riftbound").failed == 1)
    }

    @Test func eraseAllEmptiesTheStore() async throws {
        let s = try await filledStore()
        try await s.eraseAll()
        #expect(try await s.progress(game: "riftbound") == SetProgress(total: 0, fetched: 0, failed: 0))
        #expect(try await s.search(game: "riftbound", text: "", filter: .init(), limit: 5).isEmpty)
    }
}
