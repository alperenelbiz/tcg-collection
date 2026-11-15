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

    /// Final fix B9: a deck's search writes its cards and their printings together; a failed printings read (nil) keeps
    /// the last good read instead of emptying it (the controls would go off), and the next appearance reads again.
    @Test func aSearchWritesCardsAndPrintingsTogetherAndKeepsAGoodRead() {
        let state = CatalogScreenState(gameID: "riftbound", search: "")
        let kaisa = product(id: 721337, name: "Kai'Sa, Rebel", cardType: "Champion Unit")
        let card = CardSummary(id: "kai sa rebel", name: "Kai'Sa, Rebel", cover: kaisa, productIDs: [721337])
        state.show([card], printings: ["kai sa rebel": [kaisa]])
        #expect(state.cards == [card] && state.deckPrintings == ["kai sa rebel": [kaisa]])
        state.show([card], printings: nil)                                    // the read failed
        #expect(state.cards == [card] && state.deckPrintings == ["kai sa rebel": [kaisa]])
        state.show([], printings: [:])
        #expect(state.cards == [] && state.deckPrintings.isEmpty)
    }
}
