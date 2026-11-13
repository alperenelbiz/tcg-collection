import Testing
@testable import TCGCollection2

@MainActor
struct CatalogSearchViewTests {
    /// Feedback 1: "Clear" stands in All cards' toolbar while one of Set, Rarity and Type is chosen. The search text is not
    /// a filter: it does not show the button, and Clear leaves it.
    @Test func filtersOnCountsTheThreeMenusAndClearResetsThem() {
        let state = CatalogScreenState(gameID: "riftbound", search: "rune")
        #expect(state.filtersOn == 0)                                    // a search text alone
        state.filter.groupID = 24344
        #expect(state.filtersOn == 1)
        state.filter.rarity = "Rare"
        state.filter.typeFacet = "Gear"
        #expect(state.filtersOn == 3)
        state.clearFilters()
        #expect(state.filter == CardFilter())
        #expect(state.filtersOn == 0)
        #expect(state.text == "rune")
        state.filter.typeFacet = "Unit"
        #expect(state.filtersOn == 1)
    }
}
