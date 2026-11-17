import Foundation

/// One printing's prices on the days of the window that have a day file on this device: day → finish → shown price. A day
/// with a day file and no row of the product is there with `[:]` (the day file wins: no point that day).
typealias DayFilePrices = [String: [String: ShownPrice]]

/// Phase 5B task 4 (A45, K6): every printing's points for the card page, from the day files on this device
/// (`support/price-days`) merged with the iCloud history file's days. Pure, except `read`, which opens the day files
/// through the given reader (off the main actor: the model calls it from a `@concurrent` function).
nonisolated enum PriceDayPoints {
    /// The points of one finish over the window: for each day, the day file's price when this device has a day file of
    /// that day (it wins, also when it has no price of the finish), else the history file's price of that day (a device
    /// that has not decoded that day: the iPhone, or a Mac before its download). Ascending by day; no day twice.
    static func merged(dayFiles: DayFilePrices, history: [HistoryPoint]?, finish: String,
                       window: ClosedRange<String>) -> [HistoryPoint] {
        var byDay: [String: HistoryPoint] = [:]
        for point in history ?? [] where window.contains(point.day) && dayFiles[point.day] == nil {
            if byDay[point.day] == nil { byDay[point.day] = point }
        }
        for (day, prices) in dayFiles where window.contains(day) {
            if let price = prices[finish] { byDay[day] = HistoryPoint(day: day, amount: price.amount, isLow: price.isLow) }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The finishes with a price in the day files or an entry in the history file, sorted by name.
    static func finishes(dayFiles: DayFilePrices, history: PriceHistory?, productID: Int) -> [String] {
        var names = Set(dayFiles.values.flatMap(\.keys))
        if let finishes = history?.products[productID]?.keys { names.formUnion(finishes) }
        return names.sorted()
    }

    /// One product's prices in the day files of the window: each day file is opened once and looked up once
    /// (`PriceDayReader.prices`, a binary search). The cost is one lookup per day whatever the card: a Magic basic land
    /// with hundreds of printings reads only the shown printing's days. A day file that does not read is left out, so the
    /// history file's day counts for it.
    static func read(days: Set<String>, window: ClosedRange<String>, categoryID: Int, productID: Int,
                     open: HistoryPass.Reader) -> DayFilePrices {
        var out: DayFilePrices = [:]
        for day in days where window.contains(day) {
            guard let file = try? open(day) else { continue }
            out[day] = file.prices(category: categoryID, productID: productID)
        }
        return out
    }
}

/// The day-file prices of one printing as the model keeps them (`AppModel.dayPrices`), with the key they were read under:
/// valid while `AppModel.priceDaysVersion` and the window are the same.
nonisolated struct DayPrices: Sendable, Equatable {
    let version: Int
    let window: ClosedRange<String>
    let prices: DayFilePrices

    /// At least one day file has a price of the product.
    var hasPrice: Bool { prices.values.contains { !$0.isEmpty } }
}
