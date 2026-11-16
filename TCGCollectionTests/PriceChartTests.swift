import Foundation
import Testing
@testable import TCGCollection2

struct PriceChartTests {
    private let window = PriceDay.window(endingOn: "2026-11-16")

    private func point(_ day: String, _ amount: Double, low: Bool = false) -> HistoryPoint {
        HistoryPoint(day: day, amount: amount, isLow: low)
    }

    /// UTC noon of `day`, built here independently of the code under test.
    private func noon(_ day: String) -> Date {
        let parts = day.split(separator: "-").map { Int($0)! }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    private func chartPoint(_ day: String, _ amount: Double) -> ChartPoint { ChartPoint(date: noon(day), amount: amount) }

    private func chart(_ points: [HistoryPoint]) -> PriceChart { PriceChart(points: points, window: window) }

    private func yLabels(_ amounts: [Double]) -> [String] {
        chart(amounts.enumerated().map { point(PriceDay.days(in: window)[$0.offset], $0.element) }).yTicks.map(\.label)
    }

    // MARK: Runs and dots (H13)

    @Test func consecutiveDaysMakeOneRun() {
        let chart = chart([point("2026-11-14", 1), point("2026-11-12", 2), point("2026-11-13", 3)])
        #expect(chart.runs == [PriceChart.Run(points: [chartPoint("2026-11-12", 2), chartPoint("2026-11-13", 3),
                                                       chartPoint("2026-11-14", 1)], isLow: false)])
        #expect(chart.dots.isEmpty)
    }

    @Test func aMissingDayBreaksTheRun() {
        let chart = chart([point("2026-11-01", 1), point("2026-11-02", 2), point("2026-11-04", 3), point("2026-11-05", 4)])
        #expect(chart.runs == [
            PriceChart.Run(points: [chartPoint("2026-11-01", 1), chartPoint("2026-11-02", 2)], isLow: false),
            PriceChart.Run(points: [chartPoint("2026-11-04", 3), chartPoint("2026-11-05", 4)], isLow: false),
        ])
        #expect(chart.dots.isEmpty)
    }

    @Test func aDayAloneIsADot() {
        let chart = chart([point("2026-11-01", 1), point("2026-11-03", 2, low: true), point("2026-11-04", 3),
                           point("2026-11-05", 4), point("2026-11-07", 5)])
        #expect(chart.dots == [chartPoint("2026-11-01", 1), chartPoint("2026-11-07", 5)])
        #expect(chart.runs.flatMap(\.points).contains(chartPoint("2026-11-01", 1)) == false)
        #expect(chart.runs.flatMap(\.points).contains(chartPoint("2026-11-07", 5)) == false)
    }

    @Test func aLowStretchIsARunOfItsOwnJoinedToItsNeighbours() {
        let chart = chart([point("2026-11-01", 1), point("2026-11-02", 2), point("2026-11-03", 3, low: true),
                           point("2026-11-04", 4, low: true), point("2026-11-05", 5), point("2026-11-06", 6)])
        #expect(chart.runs == [
            PriceChart.Run(points: [chartPoint("2026-11-01", 1), chartPoint("2026-11-02", 2)], isLow: false),
            PriceChart.Run(points: [chartPoint("2026-11-02", 2), chartPoint("2026-11-03", 3), chartPoint("2026-11-04", 4),
                                    chartPoint("2026-11-05", 5)], isLow: true),
            PriceChart.Run(points: [chartPoint("2026-11-05", 5), chartPoint("2026-11-06", 6)], isLow: false),
        ])
        #expect(chart.dots.isEmpty)
    }

    @Test func aRunOfLowDaysAloneIsOneLowRun() {
        let chart = chart([point("2026-11-01", 1, low: true), point("2026-11-02", 2, low: true)])
        #expect(chart.runs == [PriceChart.Run(points: [chartPoint("2026-11-01", 1), chartPoint("2026-11-02", 2)],
                                              isLow: true)])
    }

    @Test func aPointOutsideTheWindowIsLeftOut() {
        let chart = chart([point("2026-08-18", 9), point("2026-08-19", 1), point("2026-08-20", 2)])
        #expect(chart.runs == [PriceChart.Run(points: [chartPoint("2026-08-19", 1), chartPoint("2026-08-20", 2)],
                                              isLow: false)])
        #expect(chart.dots.isEmpty)
    }

    // MARK: X axis (A40)

    @Test func theXAxisIsAlwaysTheWindow() {
        let chart = chart([point("2026-11-01", 1), point("2026-11-02", 2), point("2026-11-03", 3)])
        #expect(chart.xDomain == noon("2026-08-19")...noon("2026-11-16"))
        #expect(chart.xTicks == [
            ChartXTick(date: noon("2026-08-19"), label: "Aug 19"),
            ChartXTick(date: noon("2026-09-18"), label: "Sep 18"),
            ChartXTick(date: noon("2026-10-18"), label: "Oct 18"),
            ChartXTick(date: noon("2026-11-16"), label: "Nov 16"),
        ])
        #expect(PriceChart(points: [], window: window).xDomain == chart.xDomain)
    }

    @Test func theLabelsDoNotDependOnTheDevicesTimeZone() {
        // Dates are UTC noon: in every zone from UTC−11 to UTC+11 the day is the same, and the labels are not formatted
        // with the device's locale or zone.
        let chart = chart([point("2026-10-03", 11.9), point("2026-10-04", 12)])
        #expect(chart.xTicks.map(\.label) == ["Aug 19", "Sep 18", "Oct 18", "Nov 16"])
        #expect(chart.nearest(to: noon("2026-10-03"))?.text == "$11.90 · Oct 3")
    }

    // MARK: Y axis (H14)

    @Test func yTicksAreThreeRoundSteps() {
        #expect(yLabels([10.20, 13.90]) == ["$10", "$12", "$14"])
        #expect(yLabels([0.11, 0.24]) == ["$0.10", "$0.20", "$0.30"])
        #expect(yLabels([5.00, 5.00, 5.00]) == ["$4", "$5", "$6"])
        #expect(yLabels([0.01]) == ["$0.00", "$0.01", "$0.02"])
        #expect(yLabels([3950, 4010]) == ["$3,950", "$4,000", "$4,050"])
    }

    @Test func yTickValuesCoverTheRange() {
        let ticks = chart([point("2026-11-01", 10.2), point("2026-11-02", 13.9)]).yTicks
        #expect(ticks.map(\.value) == [10, 12, 14])
        let small = chart([point("2026-11-01", 0.11), point("2026-11-02", 0.24)]).yTicks
        #expect(small.map(\.value) == [0.1, 0.2, 0.3])
    }

    @Test func neverATickUnderZero() {
        for amounts in [[0.01], [0.01, 4000], [0.02, 0.03], [0.5], [1.0], [0.99, 1.01], [0.01, 0.01]] {
            let ticks = chart(amounts.enumerated().map { point(PriceDay.days(in: window)[$0.offset], $0.element) }).yTicks
            #expect(ticks.count == 3)
            #expect(ticks.allSatisfy { $0.value >= 0 }, "\(amounts)")
            #expect(ticks[0].value <= amounts.min()! + 1e-9, "\(amounts)")
            #expect(ticks[2].value >= amounts.max()! - 1e-9, "\(amounts)")
        }
    }

    @Test func aStepOfTwoAndAHalfDollarsShowsCents() {
        // 7.60…12.40: a step of 2 gives 6, 8, 10 (no), 2.5 gives 7.50, 10.00, 12.50.
        #expect(yLabels([7.6, 12.4]) == ["$7.50", "$10.00", "$12.50"])
    }

    @Test func noPointNoTick() {
        #expect(chart([]).yTicks.isEmpty)
    }

    // MARK: Summary (H15)

    @Test func summaryIsTheLastPriceAndTheChange() {
        let full = chart([point("2026-08-19", 11.20), point("2026-11-16", 12.40)])
        #expect(full.summary == ChartSummary(price: "$12.40", change: "+$1.20 in 90 days"))
        let low = chart([point("2026-11-02", 3.40), point("2026-11-13", 3.00, low: true)])
        #expect(low.summary == ChartSummary(price: "~$3.00", change: "−$0.40 in 12 days"))
        let flat = chart([point("2026-10-01", 5), point("2026-10-15", 5.2), point("2026-10-30", 5)])
        #expect(flat.summary == ChartSummary(price: "$5.00", change: "no change in 30 days"))
    }

    @Test func aChangeUnderACentIsNoChange() {
        let chart = chart([point("2026-11-01", 0.1), point("2026-11-02", 0.1 + 0.2 - 0.2)])
        #expect(chart.summary?.change == "no change in 2 days")
    }

    @Test func noSummaryUnderTwoPoints() {
        #expect(chart([]).summary == nil)
        #expect(chart([point("2026-11-16", 1)]).summary == nil)
    }

    // MARK: Notes

    @Test func theNoteFollowsThePoints() {
        #expect(chart([]).note == "No price in the last 90 days.")
        #expect(chart([point("2026-08-18", 1)]).note == "No price in the last 90 days.")
        #expect(chart([point("2026-11-16", 1)]).note == "Price history starts on Nov 16.")
        #expect(chart([point("2026-11-15", 1), point("2026-11-16", 2)]).note == nil)
    }

    @Test func theNoteOfEachState() {
        #expect(PriceChart.note(for: .unknown) == nil)
        #expect(PriceChart.note(for: .notTracked) == "Price history is kept for cards you own, want, sell or use in a deck.")
        #expect(PriceChart.note(for: .reading) == "Reading price history…")
        #expect(PriceChart.note(for: .ready) == nil)
        #expect(PriceChart.note(for: .newerVersion) == "The price history was written by a newer version of the app.")
        #expect(PriceChart.note(for: .notDownloaded) == "The price history is not downloaded from iCloud yet.")
    }

    // MARK: Hover

    @Test func nearestIsTheClosestDayWithAPrice() {
        let chart = chart([point("2026-09-20", 10), point("2026-10-03", 11.90), point("2026-10-20", 13, low: true)])
        let nearest = chart.nearest(to: noon("2026-10-08"))
        #expect(nearest == ChartReadout(date: noon("2026-10-03"), text: "$11.90 · Oct 3"))
        #expect(chart.nearest(to: noon("2026-11-16"))?.text == "~$13.00 · Oct 20")
        #expect(chart.nearest(to: noon("2026-01-01"))?.text == "$10.00 · Sep 20")
        #expect(PriceChart(points: [], window: window).nearest(to: noon("2026-10-08")) == nil)
    }

    // MARK: First finish (A38)

    @Test func theFirstFinishIsAnOwnedOneElseTheFirstOffered() {
        #expect(PriceChart.firstFinish(offered: ["Normal", "Foil", "1st Edition"], owned: ["1st Edition": 1, "Foil": 2])
            == "Foil")
        #expect(PriceChart.firstFinish(offered: ["Normal", "Foil"], owned: ["Foil": 0]) == "Normal")
        #expect(PriceChart.firstFinish(offered: ["Normal", "Foil"], owned: ["Etched": 3]) == "Normal")
        #expect(PriceChart.firstFinish(offered: [], owned: ["Foil": 1]) == nil)
    }
}
