import Testing
@testable import TCGCollection2

/// The window's memory of each screen (`ScreenMemory`, All cards' `CatalogMemory`): one game's state per screen.
@MainActor
struct ScreenMemoryTests {
    /// The same state while the game stays; a game switch (`keep(game:)`, from the window, whichever screen is on show)
    /// drops a state of another game, so every screen of the old game starts afresh (fix round 2).
    @Test func aGameSwitchDropsTheStateOfEveryScreen() {
        let memory = CollectionMemory()
        let riftbound = memory.state(game: "riftbound")
        #expect(memory.state(game: "riftbound") === riftbound)
        memory.keep(game: "riftbound")                           // the same game: kept
        #expect(memory.state(game: "riftbound") === riftbound)
        memory.keep(game: "cyberpunk")                           // another game while another screen is on show
        #expect(memory.state(game: "riftbound") !== riftbound)

        let catalog = CatalogMemory()
        let cards = catalog.state(game: "riftbound", search: "rune")
        catalog.keep(game: "riftbound")
        #expect(catalog.state(game: "riftbound", search: nil) === cards)
        catalog.keep(game: "cyberpunk")
        let fresh = catalog.state(game: "riftbound", search: "rune")
        #expect(fresh !== cards && fresh.text == "rune")         // afresh, with the `-search` text as before
    }
}
