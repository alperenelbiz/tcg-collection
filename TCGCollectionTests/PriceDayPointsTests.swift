import Foundation
import Testing
@testable import TCGCollection2

/// Phase 5B task 4 (A45, K6): a printing's points over the window, from the day files on this device merged with the
/// iCloud history file's days.
struct PriceDayPointsTests {
    static let window = "2026-01-01"..."2026-01-05"

    private static func shown(_ amount: Double, low: Bool = false) -> ShownPrice { ShownPrice(amount: amount, isLow: low) }

    private static func point(_ day: String, _ amount: Double, low: Bool = false) -> HistoryPoint {
        HistoryPoint(day: day, amount: amount, isLow: low)
    }

    @Test func aDayFileWinsOverTheHistoryFileForOneDay() {
        let days = ["2026-01-02": ["Normal": Self.shown(5)], "2026-01-03": [:]]
        let history = [Self.point("2026-01-02", 4), Self.point("2026-01-03", 7)]
        let points = PriceDayPoints.merged(dayFiles: days, history: history, finish: "Normal", window: Self.window)
        // 01-02: the day file's price; 01-03: the day file has no price of it, and it wins (no point, not the 7).
        #expect(points == [Self.point("2026-01-02", 5)])
    }

    /// The iPhone case: a device that has not decoded those days keeps the history file's points for them.
    @Test func daysOnlyInTheHistoryFileAreKept() {
        let days = ["2026-01-04": ["Normal": Self.shown(6, low: true)]]
        let history = [Self.point("2026-01-01", 3), Self.point("2026-01-02", 4)]
        let points = PriceDayPoints.merged(dayFiles: days, history: history, finish: "Normal", window: Self.window)
        #expect(points == [Self.point("2026-01-01", 3), Self.point("2026-01-02", 4), Self.point("2026-01-04", 6, low: true)])
    }

    @Test func noHistoryAndAnotherFinishGiveOnlyTheDayFilesPricesOfThatFinish() {
        let days = ["2026-01-02": ["Normal": Self.shown(5), "Foil": Self.shown(9)], "2026-01-03": ["Foil": Self.shown(8)]]
        let points = PriceDayPoints.merged(dayFiles: days, history: nil, finish: "Foil", window: Self.window)
        #expect(points == [Self.point("2026-01-02", 9), Self.point("2026-01-03", 8)])
    }

    @Test func daysOutsideTheWindowAreLeftOut() {
        let days = ["2025-12-31": ["Normal": Self.shown(1)], "2026-01-05": ["Normal": Self.shown(2)]]
        let history = [Self.point("2025-12-30", 3), Self.point("2026-01-06", 4)]
        let points = PriceDayPoints.merged(dayFiles: days, history: history, finish: "Normal", window: Self.window)
        #expect(points == [Self.point("2026-01-05", 2)])
    }

    @Test func theFinishesAreTheDayFilesAndTheHistorysInOrder() {
        let days = ["2026-01-02": ["Normal": Self.shown(5)], "2026-01-03": ["Foil": Self.shown(9)]]
        let history = PriceHistory(days: ["2026-01-01"], products: [7: ["Holofoil": [Self.shown(1)], "Normal": [nil]]])
        #expect(PriceDayPoints.finishes(dayFiles: days, history: history, productID: 7) == ["Foil", "Holofoil", "Normal"])
        #expect(PriceDayPoints.finishes(dayFiles: [:], history: nil, productID: 7) == [])
    }

    /// One lookup per day file of the window, for one product: a Magic basic land's page (hundreds of printings in one
    /// card) costs the same as any other page, since the block reads the shown printing only. A day file that does not
    /// read is left out (the history file's day then counts).
    @Test func theReadOpensEachDayFileOfTheWindowOnceAndSkipsOneThatDoesNotRead() throws {
        let rows = [89: [PriceDayRow(productID: 7, finish: "Normal", price: Self.shown(5)),
                         PriceDayRow(productID: 8, finish: "Normal", price: Self.shown(1))]]
        let good = try PriceDayReader(data: PriceDayFile.data(day: "2026-01-02", rows: rows))
        let opened = OpenCount()
        let open: HistoryPass.Reader = { day in
            opened.add(day)
            if day == "2026-01-03" { throw PriceDayFileError.notADayFile }
            return good
        }
        let read = PriceDayPoints.read(days: ["2025-12-31", "2026-01-02", "2026-01-03"], window: Self.window,
                                       categoryID: 89, productID: 7, open: open)
        #expect(read == ["2026-01-02": ["Normal": Self.shown(5)]])
        #expect(opened.days.sorted() == ["2026-01-02", "2026-01-03"])
    }

    final class OpenCount: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var days: [String] { lock.withLock { list } }
        func add(_ day: String) { lock.withLock { list.append(day) } }
    }
}
