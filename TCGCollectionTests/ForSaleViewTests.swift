import Testing
@testable import TCGCollection2

@MainActor
struct ForSaleViewTests {
    /// For Sale lists its printings with the Collection's catalog states: nothing before a join has ended; the for-sale
    /// printings alone (saved names, no price) while the catalog has no product of the game; on a join made during the
    /// download, a printing the catalog lacks is pending with the downloading line; on a settled join it has left the
    /// catalog. The counts are the for-sale counts throughout, and a printing not for sale is not listed.
    @Test func forSaleFollowsTheCatalogStates() throws {
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 3, condition: "", name: "Dockside Lock-Up"),
                    CollectionRow(productID: 2, finish: "Foil", count: 2, condition: "", name: "Last Batch"),
                    CollectionRow(productID: 3, finish: "Normal", count: 1, condition: "", name: "Not For Sale")]
        let sale = [SaleEntry(productID: 2, finish: "Foil", count: 1, name: "Last Batch"),
                    SaleEntry(productID: 1, finish: "Normal", count: 2, name: "Dockside Lock-Up")]
        let state = ForSaleScreenState(gameID: "riftbound")
        #expect(state.sort == .priceHigh)
        #expect(state.content(sale: sale) == nil)

        // The catalog has no product of the game yet: the for-sale printings alone.
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 1, priceDay: nil, catalogSettled: false)
        let alone = try #require(state.content(sale: sale))
        #expect(alone.entries.map(\.id) == sale.map(\.key) && alone.entries.map(\.row.count) == [1, 2])
        #expect(alone.entries.allSatisfy { $0.product == nil && $0.price == nil } && !alone.joined)
        #expect(alone.note == CollectionList.catalogDownloading)

        // A join during the download: product 2 is not in yet, so its printing is pending.
        let price = { (key: PrintingKey) in key.productID == 1 ? ShownPrice(amount: 5.12, isLow: false) : nil }
        state.join.catalogHasProducts = true
        state.join.entries = CollectionList.entries(rows: rows, products: [1: product(id: 1, name: "Dockside Lock-Up"),
                                                                           3: product(id: 3, name: "Not For Sale")],
                                                    setNames: [:], price: price)
        let during = try #require(state.content(sale: sale))
        #expect(during.entries.map(\.id) == sale.map(\.key) && during.entries.map(\.row.count) == [1, 2])
        #expect(during.note == CollectionList.catalogDownloading)
        #expect(during.link(for: during.entries[0]) == .none && during.link(for: during.entries[1]) == .card)
        #expect(SaleList.totals(during.entries) == "3 copies · 2 printings · $10.24 + 1 without a price")

        // The same entries on a settled join: product 2 has left the catalog.
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 2, priceDay: nil, catalogSettled: true)
        let settled = try #require(state.content(sale: sale))
        #expect(settled.note == nil && settled.link(for: settled.entries[0]) == .unknownPrinting)
        // Nothing for sale: an empty list, not the rows of the collection.
        #expect(state.content(sale: [])?.entries.isEmpty == true)
    }

    /// Fix round 1: a for-sale printing the last join did not cover (a reload added it after the join) is pending until the
    /// next join ends, also on a settled catalog: the join has not looked for its product, so it is not "not in the
    /// catalog any more". A covered printing whose product is missing still is.
    @Test func aPrintingTheJoinDidNotCoverIsPending() throws {
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 3, condition: "", name: "Dockside Lock-Up"),
                    CollectionRow(productID: 9, finish: "Normal", count: 1, condition: "", name: "Gone Card")]
        let state = ForSaleScreenState(gameID: "riftbound")
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 1, priceDay: nil, catalogSettled: true)
        state.join.catalogHasProducts = true
        state.join.entries = CollectionList.entries(rows: rows, products: [1: product(id: 1, name: "Dockside Lock-Up")],
                                                    setNames: [:]) { _ in nil }
        let sale = [SaleEntry(productID: 1, finish: "Normal", count: 1, name: "Dockside Lock-Up"),
                    SaleEntry(productID: 9, finish: "Normal", count: 1, name: "Gone Card"),
                    SaleEntry(productID: 4, finish: "Foil", count: 2, name: "Added By A Reload")]
        let content = try #require(state.content(sale: sale))
        #expect(content.entries.map(\.name) == ["Dockside Lock-Up", "Gone Card", "Added By A Reload"])
        #expect(content.entries.map { content.link(for: $0) } == [.card, .unknownPrinting, .none])
        #expect(content.uncovered == [PrintingKey(productID: 4, finish: "Foil")])
    }
}
