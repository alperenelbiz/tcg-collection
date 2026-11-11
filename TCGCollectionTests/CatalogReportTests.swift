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
}
