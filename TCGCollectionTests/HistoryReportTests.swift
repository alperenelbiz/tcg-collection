import Foundation
import Testing
@testable import TCGCollection2

/// The pure parts of the price history report (`-catalogReport YES`, phase 5A task 7; phase 5B task 3: day files).
@MainActor
struct HistoryReportTests {
    @Test func theDayLineGivesTheMedianTheMaxAndTheTotal() {
        let line = HistoryReport.dayLine([.microseconds(1_500), .microseconds(1_200), .microseconds(1_300)],
                                         total: .microseconds(4_100))
        #expect(line == "3 day files read, median 1.3 ms, max 1.5 ms per day file, total 4.1 ms")
        #expect(HistoryReport.dayLine([.milliseconds(3)], total: .milliseconds(3))
            == "1 day file read, median 3.0 ms, max 3.0 ms per day file, total 3.0 ms")
    }

    @Test func noDayFileReadSaysSo() {
        #expect(HistoryReport.dayLine([], total: .milliseconds(20)) == "0 day files read, total 20.0 ms")
    }

    /// Each day's time runs from its read's start to the next read's start, the last one's to the end.
    @Test func theSpansRunFromEachStartToTheNext() {
        let zero = ContinuousClock.now
        let starts = [zero, zero + .milliseconds(5), zero + .milliseconds(7)]
        #expect(HistoryReport.spans(starts: starts, end: zero + .milliseconds(10))
            == [.milliseconds(5), .milliseconds(2), .milliseconds(3)])
        #expect(HistoryReport.spans(starts: [], end: zero).isEmpty)
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
