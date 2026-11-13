import Foundation
import Testing
@testable import TCGCollection2

func tempRoot() -> URL {
    URL.temporaryDirectory.appending(path: "tcg-test-" + UUID().uuidString, directoryHint: .isDirectory)
}

func fixturePrices() throws -> GamePrices {
    let built = try PriceSync.build(file: fixtureURL("prices-2026-01-02.ppmd.7z"), games: Games.all, day: "2026-01-02")
    return built["riftbound"]!
}

@MainActor func filledTable() throws -> PriceTable {
    let table = PriceTable()
    try table.replace("riftbound", with: fixturePrices(), paths: AppPaths(root: tempRoot()))
    return table
}

struct PriceTableTests {
    @Test func shownPriceFallsBackToLowAndNeverShowsZero() {
        #expect(Price(market: 5.12, low: 4.87, mid: nil, high: nil).shown == ShownPrice(amount: 5.12, isLow: false))
        #expect(Price(market: nil, low: 9.5, mid: nil, high: nil).shown == ShownPrice(amount: 9.5, isLow: true))
        #expect(Price(market: nil, low: nil, mid: 3, high: 4).shown == nil)
        #expect(Price(market: 0, low: 0, mid: nil, high: nil).shown == nil)
    }

    @MainActor @Test func tableAnswersPerPrintingAndCheapest() throws {
        let table = try filledTable()
        #expect(table.prices(game: "riftbound", productID: 721334).map(\.finish) == ["Normal", "Foil"])
        #expect(table.prices(game: "riftbound", productID: 999).isEmpty)
        #expect(table.cheapest(game: "riftbound", productIDs: [721334, 711362]) == ShownPrice(amount: 5.12, isLow: false))
        #expect(table.cheapest(game: "riftbound", productIDs: [711362]) == nil)
        #expect(table.day(game: "riftbound") == "2026-01-02")
    }

    /// A printing's own price: its product's price for its finish, as the finish is written; nil when there is none.
    @MainActor @Test func aPrintingsPriceIsItsFinishs() throws {
        let table = try filledTable()
        #expect(table.shown(game: "riftbound", key: PrintingKey(productID: 721334, finish: "Normal")) == ShownPrice(amount: 5.12, isLow: false))
        #expect(table.shown(game: "riftbound", key: PrintingKey(productID: 721334, finish: "Foil")) == ShownPrice(amount: 9.5, isLow: true))
        #expect(table.shown(game: "riftbound", key: PrintingKey(productID: 721334, finish: "foil")) == nil)
        #expect(table.shown(game: "riftbound", key: PrintingKey(productID: 999, finish: "Normal")) == nil)
        #expect(table.shown(game: "yu-gi-oh", key: PrintingKey(productID: 721334, finish: "Normal")) == nil)
    }

    @MainActor @Test func cheapestUsesALowPriceOnlyWhenNoPrintingHasMarket() {
        let table = PriceTable()
        let prices = GamePrices(day: "2026-01-02", finishes: ["Normal"], rows: [
            1: [0: Price(market: nil, low: 1, mid: nil, high: nil)],
            2: [0: Price(market: 7, low: 6, mid: nil, high: nil)],
        ])
        try? table.replace("riftbound", with: prices, paths: AppPaths(root: tempRoot()))
        #expect(table.cheapest(game: "riftbound", productIDs: [1, 2]) == ShownPrice(amount: 7, isLow: false))
        #expect(table.cheapest(game: "riftbound", productIDs: [1]) == ShownPrice(amount: 1, isLow: true))
    }

    @MainActor @Test func tableSurvivesAReload() throws {
        let paths = AppPaths(root: tempRoot()); let a = PriceTable(); try a.replace("riftbound", with: fixturePrices(), paths: paths)
        let b = PriceTable(); b.load(paths: paths)
        #expect(b.prices(game: "riftbound", productID: 721334).count == 2)
    }
}
