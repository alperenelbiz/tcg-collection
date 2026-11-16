import Foundation
import Testing
@testable import TCGCollection2

/// The pure parts of the price history report (`-catalogReport YES`, phase 5A task 7).
@MainActor
struct HistoryReportTests {
    @Test func theArchiveLineGivesTheMedianTheMaxAndTheTotal() {
        let line = HistoryReport.archiveLine([.milliseconds(1_500), .milliseconds(1_200), .milliseconds(1_300)],
                                             total: .milliseconds(4_100))
        #expect(line == "3 archives read, median 1.30 s, max 1.50 s per archive, total 4.10 s")
    }

    @Test func aFillOverThreeSecondsPerArchiveIsMarked() {
        let under = HistoryReport.archiveLine([.seconds(3)], total: .seconds(3), limit: HistoryReport.fillLimit)
        #expect(under == "1 archive read, median 3.00 s, max 3.00 s per archive, total 3.00 s")
        let over = HistoryReport.archiveLine([.milliseconds(900), .milliseconds(3_100)], total: .seconds(4),
                                             limit: HistoryReport.fillLimit)
        #expect(over == "2 archives read, median 3.10 s, max 3.10 s per archive, total 4.00 s  ** over 3.00 s per archive **")
    }

    @Test func noArchiveReadSaysSo() {
        #expect(HistoryReport.archiveLine([], total: .milliseconds(20)) == "0 archives read, total 0.02 s")
    }

    @Test func theNewProductIsTheSmallestUntrackedOne() {
        #expect(HistoryReport.newProduct(catalog: [9, 3, 5, 7], tracked: [3, 7]) == 5)
        #expect(HistoryReport.newProduct(catalog: [3, 7], tracked: [3, 7]) == nil)
        #expect(HistoryReport.newProduct(catalog: [], tracked: []) == nil)
    }

    @Test func theSeriesHasAPriceOnEveryDayOfTheWindow() {
        let window = PriceDay.window(endingOn: "2026-11-15")
        let series = HistoryReport.series(window: window)
        #expect(series.count == 90)
        #expect(series.map(\.day) == PriceDay.days(in: window))
        #expect(series.allSatisfy { $0.amount > 0 })
        #expect(series.filter(\.isLow).count == 12)
        let chart = PriceChart(points: series, window: window)
        #expect(chart.summary != nil && chart.dots.isEmpty && !chart.runs.isEmpty)
    }
}
