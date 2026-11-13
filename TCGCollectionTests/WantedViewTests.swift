import Testing
@testable import TCGCollection2

@MainActor
struct WantedViewTests {
    /// Wanted lists nothing before a join of the game has ended, then lays the live list on the last join: a count or a
    /// pin changed since shows at once, a card added since is pending. The catalog counts as settled as it was for that
    /// join (as the Collection's `theListUsesTheSettledStateOfItsOwnJoin`).
    @Test func wantedLaysTheLiveListOnItsLastJoin() throws {
        let twin = [product(id: 1, groupID: 10, name: "Twin"), product(id: 2, groupID: 11, name: "Twin (Showcase)")]
        let state = WantedScreenState(gameID: "riftbound")
        #expect(state.sort == .name)
        let none: (WantedEntry, [ProductRecord]) -> ShownPrice? = { _, _ in nil }
        let wanted = [WantedEntry(cardKey: "twin", name: "Twin", count: 1, pinProductID: nil, pinFinish: nil)]
        #expect(state.join.content(wanted: wanted, price: none) == nil)          // no join has ended yet

        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 1, priceDay: nil, catalogSettled: false)
        state.join.catalogHasProducts = true
        state.join.read = WantedRead(printings: ["twin": twin], keys: ["twin"], setNames: [10: "Set A", 11: "Set B"])
        // Since the join: Twin pinned to its second printing at 3, and Gone Card added.
        let live = [WantedEntry(cardKey: "twin", name: "Twin", count: 3, pinProductID: 2, pinFinish: "Normal"),
                    WantedEntry(cardKey: "gone card", name: "Gone Card", count: 1, pinProductID: nil, pinFinish: nil)]
        let during = try #require(state.join.content(wanted: live, price: none))
        #expect(during.cards.map(\.shown?.productID) == [2, nil] && during.cards.map(\.entry.count) == [3, 1])
        #expect(during.countText(for: during.cards[0]) == "×3 · Set B")
        #expect(!during.settled && during.note == CollectionList.catalogDownloading)
        #expect(during.cards.map { during.link(for: $0) } == [.card, .none])

        // The same read, made on a settled catalog: Gone Card was not looked up, so it is still pending.
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 2, priceDay: nil, catalogSettled: true)
        let settled = try #require(state.join.content(wanted: live, price: none))
        #expect(settled.settled && settled.note == nil)
        #expect(settled.cards.map { settled.link(for: $0) } == [.card, .none])
    }

    /// Fix round 1: a pin on another printing than the one shown is named on the card page by that printing's set.
    @Test func aPinOnAnotherPrintingIsNamed() {
        let sets = [719834: "Beyond the Brave", 719835: "Beyond the Brave", 9: ""]
        #expect(WantedLine.pinnedText(PrintingKey(productID: 719834, finish: "1st Edition"), sets: sets)
                == "Pinned to Beyond the Brave")
        #expect(WantedLine.pinnedText(PrintingKey(productID: 1, finish: "Normal"), sets: sets)
                == "Pinned to a printing that left the catalog")
        #expect(WantedLine.pinnedText(PrintingKey(productID: 9, finish: "Normal"), sets: sets) == "Pinned to another printing")
    }
}
