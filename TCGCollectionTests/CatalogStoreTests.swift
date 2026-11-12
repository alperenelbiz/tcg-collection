import Foundation
import Testing
@testable import TCGCollection2

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

    /// I5: search pages by key, not by offset. Rows inserted out of key order, with product ids out of key order and
    /// names that sort one way as text and another way as numbers ("2" and "10"), give the same cards in every
    /// batch size, and no card twice.
    @Test func searchPagesByKeyInEveryBatchSize() async throws {
        let s = try await filledStore()
        func record(_ id: Int, _ name: String) -> ProductRecord {
            ProductRecord(productID: id, gameID: "riftbound", groupID: 24819, name: name, cardName: name,
                          searchKey: CardName.searchKey(name), number: "", rarity: "", cardType: "Unit",
                          typeFacets: ["Unit"], rulesText: "", url: "", fields: [:])
        }
        let rows = [record(9, "Zz Card 10"), record(3, "Zz Card 2"), record(8, "Zz Bee"), record(1, "Zz Card 10"),
                    record(7, "Zz Ant"), record(2, "Zz Card 2"), record(6, "Zz Bee"), record(5, "Zz Ant"),
                    record(4, "Zz Card 1")]
        try await s.replaceProducts(of: 24819, with: rows, at: .now)

        let whole = try await s.search(game: "riftbound", text: "zz", filter: .init(), limit: 50)
        #expect(whole.count == 5); #expect(whole.map(\.printings).reduce(0, +) == rows.count)
        for size in [1, 2, 3] {
            let paged = try await s.search(game: "riftbound", text: "zz", filter: .init(), limit: 50, batchSize: size)
            #expect(paged == whole)
            #expect(Set(paged.map(\.id)).count == paged.count)                      // no card id twice
        }
    }

    @Test func productLookupKeepsEveryField() async throws {
        let s = try await filledStore()
        let (cards, _) = try ProductParser.products(fixture("products-1.json"), game: Games.game("magic-the-gathering")!)
        let expected = try #require(cards.first { $0.productID == 692994 })
        #expect(try await s.product(692994) == expected)
        #expect(try await s.product(1) == nil)
    }

    /// Only the given game's products: a row whose id belongs to another game is an unknown printing (fix round 1, item 7).
    @Test func productsByID() async throws {
        let s = try await filledStore()
        let found = try await s.products(ids: [721334, 719684, 999_999], game: "riftbound")
        #expect(Set(found.keys) == [721334])
        #expect(found[721334]?.name == "Dockside Lock-Up")
        #expect(Set(try await s.products(ids: [721334, 719684, 999_999], game: "cyberpunk").keys) == [719684])
    }

    /// More ids than one batch of 500 holds, repeated ids, and the ids the store has in the third batch.
    @Test func productsByIDReadsInBatches() async throws {
        let s = try await filledStore()
        let found = try await s.products(ids: Array(1...1_000) + [722282, 721334, 721334], game: "riftbound")
        #expect(Set(found.keys) == [722282, 721334])
        #expect(try await s.products(ids: [], game: "riftbound").isEmpty)
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

    /// P3: a set filled now holds the current rules version, and so does a set that only `upsertSets` made (it has no
    /// products to be stale). A set row that `replaceProducts` creates holds it too.
    @Test func everySetWrittenNowHoldsTheCurrentRulesVersion() async throws {
        let s = try await filledStore()                    // 24819 is filled, the other 13 Riftbound sets only upserted
        let riftbound = try await s.rulesVersions(game: "riftbound")
        #expect(riftbound.count == 14); #expect(riftbound.values.allSatisfy { $0 == CatalogRules.version })
        #expect(try await s.rulesVersions(game: "cyberpunk") == [24884: CatalogRules.version])   // made by replaceProducts
        try await s.markFailed(24832)
        #expect(try await s.rulesVersions(game: "riftbound")[24832] == CatalogRules.version)
    }

    /// The views read through a second store on the writer's container (AppModel.reader).
    @Test func aReaderOnTheWritersContainerSeesWhatTheWriterSavedLater() async throws {
        let writer = try CatalogStore(url: URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/catalog.store"))
        let reader = CatalogStore(modelContainer: writer.modelContainer)
        func set(_ name: String) -> SetRecord {
            SetRecord(groupID: 7, gameID: "riftbound", name: name, abbreviation: "", publishedOn: nil)
        }
        #expect(try await reader.product(1) == nil)                        // the reader has read before the writer saves
        try await writer.upsertSets([set("Old name")])
        #expect(try await reader.sets(game: "riftbound").map(\.name) == ["Old name"])
        try await writer.replaceProducts(of: 7, with: [product(id: 1, groupID: 7, name: "Calm Rune", cardType: "Rune")], at: .now)
        try await writer.upsertSets([set("New name")])
        #expect(try await reader.product(1)?.cardName == "Calm Rune")
        #expect(try await reader.search(game: "riftbound", text: "calm", filter: .init(), limit: 5).map(\.name) == ["Calm Rune"])
        #expect(try await reader.sets(game: "riftbound").map(\.name) == ["New name"])   // a row read before is not stale
        #expect(try await reader.progress(game: "riftbound") == SetProgress(total: 1, fetched: 1, failed: 0))
    }

    /// The views call the stores from the main actor; the work must still run on each store's own queue.
    @MainActor @Test func aStoreNeverRunsOnTheMainThread() async throws {
        let writer = try CatalogStore(url: URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/catalog.store"))
        let reader = CatalogStore(modelContainer: writer.modelContainer)
        #expect(await writer.runsOnMainThread() == false)
        #expect(await reader.runsOnMainThread() == false)
    }

    /// The writer is busy with one long set; a read through the reader ends before that write does.
    @Test func aLongWriteDoesNotHoldUpTheReader() async throws {
        let writer = try CatalogStore(url: URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/catalog.store"))
        try await writer.replaceProducts(of: 1, with: [product(id: 1, name: "Calm Rune", cardType: "Rune")], at: .now)
        let reader = CatalogStore(modelContainer: writer.modelContainer)
        let many = (2...20_001).map { product(id: $0, groupID: 2, name: "Card \($0)", cardType: "Unit") }
        let write = Task {
            try await writer.replaceProducts(of: 2, with: many, at: .now)
            return ContinuousClock.now
        }
        try await Task.sleep(for: .milliseconds(20))                       // the write has started
        let found = try await reader.product(1)
        let readEnded = ContinuousClock.now
        let writeEnded = try await write.value
        #expect(found?.cardName == "Calm Rune")
        #expect(readEnded < writeEnded)
    }

    @Test func eraseAllEmptiesTheStore() async throws {
        let s = try await filledStore()
        try await s.eraseAll()
        #expect(try await s.progress(game: "riftbound") == SetProgress(total: 0, fetched: 0, failed: 0))
        #expect(try await s.search(game: "riftbound", text: "", filter: .init(), limit: 5).isEmpty)
    }

    @Test func historyIsDeleted() async throws {
        let store = try await filledStore()
        #expect(try await store.historyCount() > 0)                                 // else the test proves nothing
        try await store.deleteHistory()
        #expect(try await store.historyCount() == 0)
    }
    @Test func removeSetsDeletesTheRowsAndTheirProducts() async throws {
        let store = try await filledStore()
        try await store.removeSets([24819, 999_999])
        #expect(try await store.sets(game: "riftbound").map(\.groupID).contains(24819) == false)
        #expect(try await store.search(game: "riftbound", text: "", filter: .init(groupID: 24819), limit: 10).isEmpty)
        #expect(try await store.sets(game: "riftbound").count == 13)
        #expect(try await store.search(game: "magic-the-gathering", text: "", filter: .init(), limit: 10).isEmpty == false)
    }
}
