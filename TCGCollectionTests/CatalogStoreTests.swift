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
        #expect(all.map(\.printings).reduce(0, +) == 4)   // token + 2 printings of the warrior + Stardust Dragon
    }

    @Test func filtersNarrowTheResult() async throws {
        let s = try await filledStore()
        #expect(try await s.search(game: "riftbound", text: "", filter: .init(typeFacet: "Gear"), limit: 50).map(\.cover.productID) == [721334])
        #expect(try await s.search(game: "riftbound", text: "", filter: .init(groupID: 1), limit: 50).isEmpty)
        #expect(try await s.search(game: "yu-gi-oh", text: "", filter: .init(rarity: "Starlight Rare"), limit: 50).map(\.cover.productID) == [719835])
        #expect(try await s.typeFacets(game: "yu-gi-oh").contains("Token"))
        #expect(try await s.rarities(game: "yu-gi-oh") == ["Starlight Rare", "Super Rare", "Ultra Rare"])
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

    /// Phase 2B task 8 changed the search query for speed. These results were taken from the query before the change:
    /// the same cards in the same order, each with the same printings (in product id order) and the same cover, for
    /// every batch size. A card's line is `<card key> [<product ids>] <cover product id>`.
    /// Final fix B2: two names whose key is empty (`_____` and `______`, as the real Magic catalog has) are one card with
    /// the empty key, first in key order; its two rows lie in two batches at batch size 1.
    @Test func searchResultsArePinned() async throws {
        let s = try CatalogStore(url: URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/catalog.store"))
        try await s.upsertSets(try ProductParser.sets(fixture("groups-89.json"), game: Games.game("riftbound")!))
        func record(_ id: Int, _ name: String, group: Int, rarity: String, type: String) -> ProductRecord {
            ProductRecord(productID: id, gameID: "riftbound", groupID: group, name: name, cardName: name,
                          searchKey: CardName.searchKey(name), number: "", rarity: rarity, cardType: type,
                          typeFacets: [type], rulesText: "", url: "", fields: [:])
        }
        // Sets by date: 24832 (2027-01-29) newest, then 24819 (2026-10-23), then 24344 (2025-10-31). Rows go in out of
        // key order and out of id order.
        let newest = [record(50, "Lightning Dragon", group: 24832, rarity: "Rare", type: "Unit"),
                      record(20, "Dragon Whelp", group: 24832, rarity: "Common", type: "Unit")]
        let middle = [record(44, "Shivan Dragon", group: 24819, rarity: "Rare", type: "Unit"),
                      record(1, "Zap", group: 24819, rarity: "Common", type: "Spell"),
                      record(41, "Card 2", group: 24819, rarity: "Common", type: "Gear"),
                      record(33, "Dragon Whelp", group: 24819, rarity: "Rare", type: "Unit"),
                      record(12, "Ancient Dragon", group: 24819, rarity: "Rare", type: "Unit"),
                      record(11, "The Dragon's Hoard", group: 24819, rarity: "Common", type: "Gear"),
                      record(9, "Lightning Bolt", group: 24819, rarity: "Rare", type: "Spell"),
                      record(8, "Dragonlord", group: 24819, rarity: "Common", type: "Unit"),
                      record(5, "Bolt of Lightning", group: 24819, rarity: "Common", type: "Spell"),
                      record(70, "_____", group: 24819, rarity: "Common", type: "Unit")]
        let oldest = [record(15, "______", group: 24344, rarity: "Common", type: "Unit"),
                      record(60, "Thermal Bolt", group: 24344, rarity: "Common", type: "Spell"),
                      record(40, "Card 10", group: 24344, rarity: "Common", type: "Gear"),
                      record(35, "Lightning Bolt", group: 24344, rarity: "Common", type: "Spell"),
                      record(31, "Ancient Dragon", group: 24344, rarity: "Common", type: "Unit"),
                      record(7, "Dragon Whelp", group: 24344, rarity: "Common", type: "Unit"),
                      record(3, "Shivan Dragon", group: 24344, rarity: "Common", type: "Unit"),
                      record(2, "Card 10", group: 24344, rarity: "Common", type: "Gear")]
        for (group, rows) in [(24819, middle), (24344, oldest), (24832, newest)] {
            try await s.replaceProducts(of: group, with: rows, at: .now)
        }
        let all = [" [15, 70] 70", "ancient dragon [12, 31] 12", "bolt of lightning [5] 5", "card 10 [2, 40] 40", "card 2 [41] 41",
                   "dragon whelp [7, 20, 33] 20", "dragonlord [8] 8", "lightning bolt [9, 35] 9",
                   "lightning dragon [50] 50", "shivan dragon [3, 44] 44", "the dragon s hoard [11] 11",
                   "thermal bolt [60] 60", "zap [1] 1"]
        let dragon = ["ancient dragon [12, 31] 12", "dragon whelp [7, 20, 33] 20", "dragonlord [8] 8",
                      "lightning dragon [50] 50", "shivan dragon [3, 44] 44", "the dragon s hoard [11] 11"]
        let cases: [(text: String, filter: CardFilter, limit: Int, expected: [String])] = [
            ("", .init(), 50, all),
            ("", .init(), 3, Array(all.prefix(3))),                         // the limit ends the scan after a whole card
            ("", .init(), 1, [" [15, 70] 70"]),                             // the empty key is a whole card too
            ("dragon", .init(), 50, dragon),
            ("dragon", .init(), 2, Array(dragon.prefix(2))),
            ("a", .init(), 50, all.filter { !$0.hasPrefix(" ") && !$0.hasPrefix("bolt of") && !$0.hasPrefix("lightning bolt") }),
            ("the", .init(), 50, ["the dragon s hoard [11] 11", "thermal bolt [60] 60"]),
            ("lightning bolt", .init(), 50, ["bolt of lightning [5] 5", "lightning bolt [9, 35] 9"]),
            ("bolt lightning", .init(), 50, ["bolt of lightning [5] 5", "lightning bolt [9, 35] 9"]),
            ("DRAGON  whelp", .init(), 50, ["dragon whelp [7, 20, 33] 20"]),
            ("wyrm", .init(), 50, []),
            ("dragon", .init(rarity: "Rare"), 50, ["ancient dragon [12] 12", "dragon whelp [33] 33",
                                                   "lightning dragon [50] 50", "shivan dragon [44] 44"]),
            ("", .init(typeFacet: "Spell"), 50, ["bolt of lightning [5] 5", "lightning bolt [9, 35] 9",
                                                 "thermal bolt [60] 60", "zap [1] 1"]),
            ("dragon", .init(groupID: 24344), 50, ["ancient dragon [31] 31", "dragon whelp [7] 7", "shivan dragon [3] 3"]),
        ]
        for item in cases {
            for size in [1, 2, 3, 5, 400] {
                let found = try await s.search(game: "riftbound", text: item.text, filter: item.filter, limit: item.limit,
                                               batchSize: size)
                let lines = found.map { "\($0.id) \($0.productIDs) \($0.cover.productID)" }
                #expect(lines == item.expected, "text \"\(item.text)\", \(item.filter), limit \(item.limit), batch \(size)")
            }
        }
    }

    /// The search matches its words in the stored card key, which finds the rows `searchKey` would only while the two are
    /// equal in every stored row (phase 2B task 8; final fix B1). Parsed products of the name rules that change a card
    /// name go through the parser and the store: a Yu-Gi-Oh! Skill printing without the bracket (A5), one with the kept
    /// `(Skill Card)` bracket, an official whole name (A3), a `//` split name and an accented name.
    @Test func everyStoredRowsSearchKeyIsItsCardKey() async throws {
        let s = try CatalogStore(url: URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/catalog.store"))
        func json(_ items: [(id: Int, name: String, type: String)], group: Int, typeField: String) throws -> Data {
            let results: [[String: Any]] = items.map { item in
                ["productId": item.id, "name": item.name, "groupId": group, "url": "",
                 "extendedData": [["name": typeField, "value": item.type], ["name": "Number", "value": "\(item.id)"],
                                  ["name": "Rarity", "value": "Common"]]]
            }
            return try JSONSerialization.data(withJSONObject: ["success": true, "results": results])
        }
        let yugioh = try #require(Games.game("yu-gi-oh")), magic = try #require(Games.game("magic-the-gathering"))
        let (skills, _) = try ProductParser.products(json([(1, "Power of Dark", "Skill"), (2, "Power Bond (Skill Card)", "Skill")],
                                                          group: 900, typeField: yugioh.typeField), game: yugioh)
        let (cards, _) = try ProductParser.products(json([(3, "Erase (Not the Urza's Legacy One)", "Enchantment"),
                                                          (4, "Fire // Ice", "Instant"), (5, "Jötun Grunt", "Creature")],
                                                         group: 901, typeField: magic.typeField), game: magic)
        try await s.replaceProducts(of: 900, with: skills, at: .now)
        try await s.replaceProducts(of: 901, with: cards, at: .now)
        let stored = try await s.storedKeys()
        #expect(stored.map(\.cardKey) == ["power of dark skill card", "power bond skill card",
                                          "erase not the urza s legacy one", "fire ice", "jotun grunt"])
        for row in stored { #expect(row.searchKey == row.cardKey, "\(row.name)") }
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

    /// Fix round 2, item 1: whether a game has any product (a set fetched without a card does not count).
    @Test func whetherAGameHasProducts() async throws {
        let s = try await filledStore()
        #expect(try await s.hasProducts(game: "riftbound"))
        try await s.replaceProducts(of: 24819, with: [], at: .now)                 // the set is fetched, without cards
        #expect(try await !s.hasProducts(game: "riftbound"))
        #expect(try await s.progress(game: "riftbound").fetched == 1)
        #expect(try await s.hasProducts(game: "cyberpunk"))
    }

    /// More ids than one batch of 500 holds, repeated ids, and the ids the store has in the third batch.
    @Test func productsByIDReadsInBatches() async throws {
        let s = try await filledStore()
        let found = try await s.products(ids: Array(1...1_000) + [722282, 721334, 721334], game: "riftbound")
        #expect(Set(found.keys) == [722282, 721334])
        #expect(try await s.products(ids: [], game: "riftbound").isEmpty)
    }

    /// Phase 2C task 4: the printings of many cards at once (Wanted), by card key, each card's in the order the card page
    /// reads them (`printings(game:cardKey:)`, newest set first). Only the game's own products; a key the store has no
    /// product for is left out; repeated keys and more keys than one batch of 500 holds.
    @Test func printingsOfManyCards() async throws {
        let s = try await filledStore()
        let warrior = "swiftwind panther warrior", token = "token joey and red eyes black dragon"
        let found = try await s.printings(game: "yu-gi-oh", cardKeys: [warrior, token, "gone card", warrior, "dockside lock up"])
        #expect(Set(found.keys) == [warrior, token])
        #expect(found[warrior] == (try await s.printings(game: "yu-gi-oh", cardKey: warrior)))
        #expect(found[warrior]?.map(\.productID) == [719835, 719834])           // one set: the higher id first
        #expect(found[token]?.map(\.productID) == [719829])
        #expect(try await s.printings(game: "riftbound", cardKeys: [warrior]).isEmpty)   // another game's card
        #expect(try await s.printings(game: "riftbound", cardKeys: []).isEmpty)
        let many = try await s.printings(game: "riftbound", cardKeys: (1...1_000).map { "card \($0)" } + ["calm rune", "dockside lock up"])
        #expect(Set(many.keys) == ["calm rune", "dockside lock up"])
        #expect(many["calm rune"]?.map(\.productID) == [722282])
    }

    /// Fix round 1: one card key in two games (a Riftbound card named as a Yu-Gi-Oh! one): each game gets only its own
    /// printings.
    @Test func printingsOfManyCardsStayInTheirGame() async throws {
        let s = try await filledStore()
        try await s.replaceProducts(of: 24819, with: [product(id: 5, groupID: 24819, name: "Swiftwind Panther Warrior")], at: .now)
        let warrior = "swiftwind panther warrior"
        #expect(try await s.printings(game: "yu-gi-oh", cardKeys: [warrior])[warrior]?.map(\.productID) == [719835, 719834])
        #expect(try await s.printings(game: "riftbound", cardKeys: [warrior])[warrior]?.map(\.productID) == [5])
        #expect(try await s.printings(game: "cyberpunk", cardKeys: [warrior]).isEmpty)
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

    // MARK: Pasting a deck (phase 3A task 7)

    /// Exact card keys of one game to the card's name and a printing's type (the first printing with a type, newest
    /// first); keys of another game or of no card are left out; more keys than one batch of 500.
    @Test func cardsByExactKey() async throws {
        let s = try await filledStore()
        let found = try await s.cards(game: "yu-gi-oh", keys: ["stardust dragon", "swiftwind panther warrior", "calm rune", "nothing"])
        #expect(found == ["stardust dragon": CatalogCard(cardKey: "stardust dragon", name: "Stardust Dragon", cardType: "Synchro Monster"),
                          "swiftwind panther warrior": CatalogCard(cardKey: "swiftwind panther warrior",
                                                                   name: "Swiftwind Panther Warrior", cardType: "Effect Monster")])
        let many = try await s.cards(game: "riftbound", keys: (1...1_200).map { "card \($0)" } + ["calm rune", "kai sa rebel"])
        #expect(Set(many.keys) == ["calm rune", "kai sa rebel"])
        #expect(many["kai sa rebel"] == CatalogCard(cardKey: "kai sa rebel", name: "Kai'Sa, Rebel", cardType: "Champion Unit"))
        #expect(try await s.cards(game: "riftbound", keys: []).isEmpty)
        // The newest printing has no type: the type of the next one.
        try await s.replaceProducts(of: 99, with: [product(id: 9002, groupID: 99, name: "Twin"),
                                                   product(id: 9001, groupID: 99, name: "Twin", cardType: "Unit")], at: .now)
        #expect(try await s.cards(game: "riftbound", keys: ["twin"])["twin"]?.cardType == "Unit")
    }

    /// The nearest names of a text in one game: distinct cards, nearest first, at most `limit`; a typo in the first word
    /// is found through the longest word; an empty text has none.
    @Test func nearestNamesRankByDistanceInTheGame() async throws {
        let s = try await filledStore()
        let names = ["Ash Blossom & Joyous Spring", "Ash Hound", "Ash Barrage", "Ashen Rider", "Blossom Bombardment", "Ash Zealot", "Flash"]
        try await s.replaceProducts(of: 98, with: names.enumerated().map { product(id: 9100 + $0.offset, game: "yu-gi-oh", groupID: 98, name: $0.element) }
            + [product(id: 9200, game: "yu-gi-oh", groupID: 98, name: "Ash Blossom & Joyous Spring (Secret Rare)")], at: .now)
        try await s.replaceProducts(of: 97, with: [product(id: 9300, groupID: 97, name: "Ash Blosom")], at: .now)   // Riftbound
        let found = try await s.nearestNames(game: "yu-gi-oh", to: "Ash Blosom", limit: 5)
        #expect(found.first == Suggestion(cardKey: "ash blossom joyous spring", name: "Ash Blossom & Joyous Spring"))
        #expect(found.count == 5 && Set(found.map(\.cardKey)).count == 5)
        #expect(!found.contains { $0.cardKey == "ash blosom" })
        #expect(try await s.nearestNames(game: "yu-gi-oh", to: "Ahs Blossom", limit: 5).first?.name == "Ash Blossom & Joyous Spring")
        #expect(try await s.nearestNames(game: "yu-gi-oh", to: "Ash Blosom", limit: 2).count == 2)
        #expect(try await s.nearestNames(game: "yu-gi-oh", to: "", limit: 5).isEmpty)
        #expect(try await s.nearestNames(game: "yu-gi-oh", to: " , ", limit: 5).isEmpty)
        #expect(try await s.nearestNames(game: "yu-gi-oh", to: "Qqq Zzz", limit: 5).isEmpty)
    }
}
