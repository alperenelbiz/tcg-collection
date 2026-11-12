import Foundation
import Testing
@testable import TCGCollection2

struct CatalogReportTests {
    @Test func aCollisionIsOneKeyWithTwoCardTypes() {
        let a = product(id: 1, name: "Calm Rune", cardType: "Rune"), b = product(id: 2, name: "Calm Rune (R02a)", cardType: "Rune")
        let c = product(id: 3, name: "Fire (Showcase)", cardType: "Instant"), d = product(id: 4, name: "Fire", cardType: "Land")
        let found = CatalogReport.collisions([a, b, c, d])
        #expect(found.count == 1); #expect(found[0].cardKey == "fire"); #expect(found[0].cardTypes.sorted() == ["Instant", "Land"])
    }

    @Test func oneKeyInTwoGamesIsNoCollision() {
        let found = CatalogReport.collisions([product(id: 1, game: "riftbound", name: "Fire", cardType: "Spell"),
                                              product(id: 2, game: "cyberpunk", name: "Fire", cardType: "Program")])
        #expect(found.isEmpty)
    }

    /// Yu-Gi-Oh! printings against cardinfo-sample.json: "A Case for K9" has the set code JUSH-EN040,
    /// "Dark Magician" is known by name only, the token is not in the sample.
    @Test func theTextCountsPicturesPricesAndCards() async throws {
        let store = try CatalogStore(url: URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/catalog.store"))
        let cards = [product(id: 1, game: "yu-gi-oh", groupID: 5, name: "A Case for K9", number: "JUSH-EN040", cardType: "Spell Card"),
                     product(id: 2, game: "yu-gi-oh", groupID: 5, name: "Dark Magician (Starlight Rare)", number: "XXXX-EN999", cardType: "Normal Monster"),
                     product(id: 3, game: "yu-gi-oh", groupID: 5, name: "Token: Unknown", number: "TKN5-EN052", cardType: "Token"),
                     product(id: 4, game: "yu-gi-oh", groupID: 5, name: "Dark Magician", number: "", cardType: "Normal Monster")]
        try await store.replaceProducts(of: 5, with: cards, at: .now)
        let prices = ["yu-gi-oh": GamePrices(day: "2026-11-10", finishes: ["Normal"], rows: [
            1: [0: Price(market: 1.5, low: 1, mid: nil, high: nil)],
            2: [0: Price(market: nil, low: 0.5, mid: nil, high: nil)],
            9: [0: Price(market: 20, low: 18, mid: nil, high: nil)]])]
        let ygo = try YGOPictureIndex(cardinfo: fixture("cardinfo-sample.json"))

        let text = try await CatalogReport.text(store: store, prices: prices, ygo: ygo)

        #expect(text.contains("== Yu-Gi-Oh! (yu-gi-oh)"))
        #expect(text.contains("sets: 1 total, 1 fetched, 0 failed"))
        #expect(text.contains("products kept: 4"))
        #expect(text.contains("cards (distinct card key): 3"))
        #expect(text.contains("empty number: 1, empty rarity: 4, empty rules text: 4"))
        #expect(text.contains("collisions: 0"))
        #expect(text.contains("prices of 2026-11-10: 2 printings with no price row, 1 with a low price only, 1 priced product not in the catalog"))
        #expect(text.contains("pictures: 1 by set code, 2 by name, 1 not matched"))
        #expect(text.contains("Token: Unknown (TKN5-EN052)"))
        #expect(text.contains("search \"dragon\""))
    }

    @Test func sealedLookingNamesAreFound() {
        #expect(CatalogReport.sealedLooking(["Fairy Box", "Pot of Greed", "Beyond the Brave Booster Pack [1st Edition]", "Deck Devastation Virus"])
                == ["Fairy Box", "Beyond the Brave Booster Pack [1st Edition]", "Deck Devastation Virus"])
    }

    /// A sealed word must be a whole word: `Tinker` and `Boxer` are not `Tin` and `Box`.
    @Test func aSealedWordIsAWholeWord() {
        #expect(CatalogReport.sealedLooking(["Goblin Tinker", "Boxer", "Mystery Tin", "Kit Kat (Playmat)"]) == ["Mystery Tin", "Kit Kat (Playmat)"])
    }

    /// Riftbound: a basic rune (plain and alt-art printing), a gear, and a kept product with no card type whose name has
    /// a sealed word; its facets file is next to the store. Magic: a plain and a numbered Forest (two card keys), a type
    /// line that maps to no type, a serial printing with no card type; no facets file. Yu-Gi-Oh!: a printing with no
    /// card type that cardinfo-sample.json knows by name.
    @Test func theTextShowsTypelessCardsBasicsAndTheTypeMenu() async throws {
        let folder = tempDir()
        let store = try CatalogStore(url: folder.appending(path: "catalog.store"))
        let rift = [product(id: 1, groupID: 7, name: "Calm Rune", number: "R02", rarity: "Common", cardType: "Rune"),
                    product(id: 2, groupID: 7, name: "Calm Rune (R02a)", number: "R02a", rarity: "Showcase", cardType: "Rune"),
                    product(id: 3, groupID: 7, name: "Dockside Lock-Up", number: "100", rarity: "Rare", cardType: "Gear"),
                    product(id: 4, groupID: 7, name: "Vault Bundle Card", number: "200", rarity: "Promo")]
        let magic = [product(id: 11, game: "magic-the-gathering", groupID: 8, name: "Forest", rarity: "L", cardType: "Basic Land — Forest"),
                     product(id: 12, game: "magic-the-gathering", groupID: 8, name: "Forest (0276) - Full Art", rarity: "L",
                             cardType: "Basic Land — Forest"),
                     product(id: 13, game: "magic-the-gathering", groupID: 8, name: "Hero of Nowhere", number: "1", rarity: "S",
                             cardType: "Hero — Thing"),
                     product(id: 14, game: "magic-the-gathering", groupID: 8, name: "Bloodline Recollector (Serial Numbered)",
                             number: "402", rarity: "M")]
        let ygo = [product(id: 21, game: "yu-gi-oh", groupID: 9, name: "Dark Magician", number: "LC2-EN001", rarity: "Ultra Rare")]
        try await store.replaceProducts(of: 7, with: rift.map(withFacets), at: .now)
        try await store.replaceProducts(of: 8, with: magic.map(withFacets), at: .now)
        try await store.replaceProducts(of: 9, with: ygo.map(withFacets), at: .now)
        try FacetLists(rarities: ["Common", "Promo", "Rare", "Showcase"], types: ["Gear", "Rune"])
            .write(to: folder.appending(path: "facets-riftbound.json"))

        let text = try await CatalogReport.text(store: store, prices: [:],
                                                ygo: try YGOPictureIndex(cardinfo: fixture("cardinfo-sample.json")))
        // Every section starts with "== <title>" on a line of its own.
        let sections = Dictionary(uniqueKeysWithValues: ("\n" + text).components(separatedBy: "\n== ").map {
            (String($0.prefix { $0 != "\n" }), $0)
        })
        let riftbound = try #require(sections["Riftbound (riftbound)"])
        #expect(riftbound.contains("cards with an empty card type: 1\n  Vault Bundle Card — 200 — Promo\n"))
        #expect(riftbound.contains("of those, with a sealed word in the name: 1\n  Vault Bundle Card\n"))
        #expect(riftbound.contains("basic cards: 1, basic printings: 1\n  calm rune\n"))
        #expect(riftbound.contains("type menu (2): Gear, Rune\n"))
        #expect(riftbound.contains("facets-riftbound.json: the same lists\n"))
        #expect(riftbound.contains("printings with no type facet: 1 (1 with an empty card type)\n"))

        let mtg = try #require(sections["Magic: The Gathering (magic-the-gathering)"])
        #expect(mtg.contains("cards with an empty card type: 1\n  Bloodline Recollector (Serial Numbered) — 402 — M\n"))
        #expect(mtg.contains("of those, with a sealed word in the name: 0\n"))
        #expect(mtg.contains("basic cards: 2, basic printings: 2\n  forest\n  forest 0276 full art\n"))
        #expect(mtg.contains("printings with no type facet: 2 (1 with an empty card type)\n"))
        #expect(mtg.contains("words of the type lines with no type facet (20 most common): Hero 1\n"))
        #expect(mtg.contains("type menu (1): Land\n"))
        #expect(mtg.contains("facets-magic-the-gathering.json: no file\n"))

        let yugioh = try #require(sections["Yu-Gi-Oh! (yu-gi-oh)"])
        #expect(yugioh.contains("pictures of the printings with an empty card type: 0 by set code, 1 by name, 0 not matched\n"))
        #expect(yugioh.contains("basic cards: 0, basic printings: 0\n"))
        #expect(text.contains("facets-riftbound.json: 0.1 KB, read and decode"))
    }

    /// The record as the parser makes it: with the type facets of its game (the shared helper leaves them empty).
    private func withFacets(_ p: ProductRecord) -> ProductRecord {
        ProductRecord(productID: p.productID, gameID: p.gameID, groupID: p.groupID, name: p.name, cardName: p.cardName,
                      searchKey: p.searchKey, number: p.number, rarity: p.rarity, cardType: p.cardType,
                      typeFacets: Games.game(p.gameID)!.typeFacets(p.cardType), rulesText: p.rulesText, url: p.url,
                      fields: p.fields)
    }
}
