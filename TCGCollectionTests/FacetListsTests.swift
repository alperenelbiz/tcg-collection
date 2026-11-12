import Foundation
import Testing
@testable import TCGCollection2

struct FacetListsTests {
    @Test func listsRoundTripAndComeSorted() async throws {
        let lists = try await filledStore().facetLists(game: "riftbound")
        #expect(lists.types == lists.types.sorted()); #expect(lists.types.contains("Gear")); #expect(!lists.rarities.isEmpty)
        #expect(lists.rarities == lists.rarities.sorted())
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".json"); try lists.write(to: url)
        #expect(FacetLists.read(url) == lists); #expect(FacetLists.read(URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test func magicTypesKeepTheirOrder() async throws {
        let types = try await filledStore().facetLists(game: "magic-the-gathering").types
        #expect(!types.isEmpty); #expect(types == MagicTypes.all.filter(types.contains)); #expect(types.contains("Planeswalker"))
    }

    /// A migrated Magic row that was not fetched again still carries an old word; the menu must not show it.
    @Test func aMagicTypeThatIsNotACurrentFacetIsLeftOut() async throws {
        let store = try await filledStore()
        let old = ProductRecord(productID: 900_001, gameID: "magic-the-gathering", groupID: 24684, name: "Old", cardName: "Old",
                                searchKey: "old", number: "", rarity: "", cardType: "Summon Goblin", typeFacets: ["Summon"],
                                rulesText: "", url: "", fields: [:])
        try await store.replaceProducts(of: 24684, with: [old], at: .now)
        #expect(try await store.facetLists(game: "magic-the-gathering").types.isEmpty)
    }
}
