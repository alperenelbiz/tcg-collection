import Foundation

/// One price on the chart: a day (UTC noon) and its amount.
nonisolated struct ChartPoint: Equatable, Sendable {
    let date: Date
    let amount: Double
}

/// A label on the x axis: a day of the window (UTC noon), `MMM d` in English.
nonisolated struct ChartXTick: Equatable, Sendable {
    let date: Date
    let label: String
}

/// A gridline of the y axis and its label (`$12`, `$0.25`).
nonisolated struct ChartYTick: Equatable, Sendable {
    let value: Double
    let label: String
}

/// The line under the heading (H15): the last price and the change over the window.
nonisolated struct ChartSummary: Equatable, Sendable {
    let price: String
    let change: String
}

/// What the summary line shows while the pointer is over the plot: the nearest day with a price.
nonisolated struct ChartReadout: Equatable, Sendable {
    let date: Date
    let text: String
}

/// The price chart of one printing's finish as a value (A38, A40, H13–H15): pure, UTC, English, no view.
nonisolated struct PriceChart: Equatable, Sendable {
    /// A stretch of consecutive days drawn as one line; a low stretch is dashed (H13).
    struct Run: Equatable, Sendable {
        let points: [ChartPoint]
        let isLow: Bool
    }

    /// Lines of two points or more, in day order. A low run shares its first and last point with the run beside it.
    let runs: [Run]
    /// Days with a price and no neighbour on either side.
    let dots: [ChartPoint]
    /// Always the whole window (A40), UTC noon of its first and last day.
    let xDomain: ClosedRange<Date>
    /// The window's days 0, 30, 60 and its last day.
    let xTicks: [ChartXTick]
    /// Three round gridlines (H14); none without a point.
    let yTicks: [ChartYTick]
    /// Nil under two points (then `note` says why).
    let summary: ChartSummary?
    /// The sentence of a ready history with fewer than two points; nil otherwise.
    let note: String?

    private let entries: [Entry]

    private struct Entry: Equatable, Sendable {
        let day: String
        let date: Date
        let amount: Double
        let isLow: Bool
        var point: ChartPoint { ChartPoint(date: date, amount: amount) }
    }

    init(points: [HistoryPoint], window: ClosedRange<String>) {
        var byDay: [String: HistoryPoint] = [:]
        for point in points where window.contains(point.day) && point.amount.isFinite && point.amount >= 0 { byDay[point.day] = byDay[point.day] ?? point }
        let entries = byDay.values.sorted { $0.day < $1.day }.compactMap { point -> Entry? in
            guard let date = Self.noon(point.day) else { return nil }
            return Entry(day: point.day, date: date, amount: point.amount, isLow: point.isLow)
        }
        self.entries = entries

        let windowDays = PriceDay.days(in: window)
        let first = Self.noon(window.lowerBound) ?? .distantPast
        let last = Self.noon(window.upperBound) ?? first
        xDomain = first...max(first, last)
        xTicks = [0, 30, 60, windowDays.count - 1].compactMap { index in
            guard windowDays.indices.contains(index), let date = Self.noon(windowDays[index]) else { return nil }
            return ChartXTick(date: date, label: Self.label(windowDays[index]))
        }

        (runs, dots) = Self.lines(entries)
        yTicks = Self.yTicks(entries.map(\.amount))

        switch entries.count {
        case 0:
            summary = nil
            note = "No price in the last 90 days."
        case 1:
            summary = nil
            note = "Price history starts on \(Self.label(entries[0].day))."
        default:
            let firstEntry = entries[0], lastEntry = entries[entries.count - 1]
            summary = ChartSummary(price: CardFacts.priceText(ShownPrice(amount: lastEntry.amount, isLow: lastEntry.isLow)),
                                   change: Self.changeText(from: firstEntry, to: lastEntry))
            note = nil
        }
    }

    /// The closest day with a price (an equal distance: the earlier day), as `$11.90 · Oct 3` (`~` for a low day).
    func nearest(to date: Date) -> ChartReadout? {
        guard let entry = entries.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
        else { return nil }
        let price = CardFacts.priceText(ShownPrice(amount: entry.amount, isLow: entry.isLow))
        return ChartReadout(date: entry.date, text: "\(price) · \(Self.label(entry.day))")
    }

    /// The finish shown first (A38): the first offered finish that is owned, else the first offered; nil for none.
    static func firstFinish(offered: [String], owned: [String: Int]) -> String? {
        offered.first { (owned[$0] ?? 0) >= 1 } ?? offered.first
    }

    /// The block's sentence for a state other than ready ("The look"); nil for `.unknown` (no sentence) and `.ready`
    /// (the points decide: the instance's `note`).
    static func note(for state: HistoryState) -> String? {
        switch state {
        case .unknown, .ready: nil
        case .notTracked: "Price history is kept for cards you own, want, sell or use in a deck."
        case .reading: "Reading price history…"
        case .newerVersion: "The price history was written by a newer version of the app."
        case .notDownloaded: "The price history is not downloaded from iCloud yet."
        }
    }

    // MARK: Lines (H13)

    private static func lines(_ entries: [Entry]) -> ([Run], [ChartPoint]) {
        var groups: [[Entry]] = []
        for entry in entries {
            if let previous = groups.last?.last, PriceDay.after(previous.day) == entry.day {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        var runs: [Run] = []
        var dots: [ChartPoint] = []
        for group in groups {
            guard group.count > 1 else {
                dots.append(group[0].point)
                continue
            }
            // A segment touching a low day is dashed; consecutive segments of one kind make one run, so a low run
            // starts and ends on the market point beside it and the line has no hole.
            var current: [ChartPoint] = [group[0].point]
            var currentLow = group[0].isLow || group[1].isLow
            for index in 1..<group.count {
                let segmentLow = group[index - 1].isLow || group[index].isLow
                if segmentLow != currentLow {
                    runs.append(Run(points: current, isLow: currentLow))
                    current = [group[index - 1].point]
                    currentLow = segmentLow
                }
                current.append(group[index].point)
            }
            runs.append(Run(points: current, isLow: currentLow))
        }
        return (runs, dots)
    }

    // MARK: Y axis (H14)

    /// Round steps in cents: 1, 2, 5 × a power of ten from one cent, and 2.5 × a power of ten from 25 cents (a step of
    /// 2.5 cents would need a third decimal).
    private static func steps() -> [Int] {
        var result: [Int] = []
        var power = 1
        while power <= 1_000_000_000 {
            result.append(power)
            result.append(2 * power)
            if power >= 10 { result.append(power * 5 / 2) }
            result.append(5 * power)
            power *= 10
        }
        return result
    }

    private static func yTicks(_ amounts: [Double]) -> [ChartYTick] {
        guard let low = amounts.min(), let high = amounts.max() else { return [] }
        var lowCents = max(0, Int((low * 100 + 1e-6).rounded(.down)))
        var highCents = max(lowCents, Int((high * 100 - 1e-6).rounded(.up)))
        // A range narrower than 20 % of the highest price is widened to that width around its middle, so a flat price
        // reads flat (controller ruling of review 1); its lower end is never under 0, and a cut at 0 keeps the width.
        let width = 0.2 * Double(highCents)
        if Double(highCents - lowCents) < width {
            let middle = Double(lowCents + highCents) / 2
            var lower = middle - width / 2
            var upper = middle + width / 2
            if lower < 0 {
                upper -= lower
                lower = 0
            }
            lowCents = Int((lower + 1e-6).rounded(.down))
            highCents = Int((upper - 1e-6).rounded(.up))
        }
        let step = steps().first { step in (lowCents / step) * step + 2 * step >= highCents } ?? 1_000_000_000
        let bottom = (lowCents / step) * step
        let cents = [bottom, bottom + step, bottom + 2 * step]
        let whole = cents.allSatisfy { $0 % 100 == 0 }
        return cents.map { value in
            let amount = Double(value) / 100
            return ChartYTick(value: amount, label: whole ? wholeDollars(value / 100) : CardFacts.priceText(
                ShownPrice(amount: amount, isLow: false)))
        }
    }

    private static func wholeDollars(_ dollars: Int) -> String {
        dollars.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
    }

    // MARK: Texts

    /// `+$1.20 in 90 days`, `−$0.40 in 12 days` (a real minus sign), `no change in 30 days` (H15): the calendar days
    /// from the first point's day to the last point's day, both included (a full window is 90 days).
    private static func changeText(from first: Entry, to last: Entry) -> String {
        let days = Int((last.date.timeIntervalSince(first.date) / 86_400).rounded()) + 1
        let span = "\(days) days" // two points or more: always 2 days or more
        let cents = Int((last.amount * 100).rounded()) - Int((first.amount * 100).rounded())
        guard cents != 0 else { return "no change in \(span)" }
        let amount = CardFacts.priceText(ShownPrice(amount: Double(abs(cents)) / 100, isLow: false))
        return "\(cents > 0 ? "+" : "\u{2212}")\(amount) in \(span)"
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `2026-10-03` → `Oct 3`, without the device's locale or time zone.
    private static func label(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }

    /// UTC noon of `day` (`yyyy-MM-dd`); nil when it does not read as a day.
    private static func noon(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
