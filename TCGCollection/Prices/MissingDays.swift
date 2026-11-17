import Foundation

/// The days the 90-day download (phase 5B task 5: A32, A33, A46, K7, K12) still has to fetch, and the texts that name
/// them. Pure: the model hands it what is on disk and what failed in this run.
nonisolated enum MissingDays {
    /// The first daily archive tcgcsv has (K7): no day before it is ever asked for.
    static let firstArchiveDay = "2024-02-08"

    /// K7: the days of `window`, not after the wanted day of `now` and not before `firstArchiveDay`, that have no day
    /// file, no archive on disk (an archive on disk is decoded, not downloaded), did not fail in this run (the gate's
    /// failed days, and the days whose request threw), were not a 404 (in this run, or kept from an earlier run: a gap tcgcsv
    /// does not have stays a gap, final fix wave item 4), and were never downloaded or held on this device (`downloaded`:
    /// the record, A47). Newest first: the chart fills from the right.
    static func days(window: ClosedRange<String>, dayFiles: Set<String>, archives: Set<String>, failed: Set<String>,
                     notFound: Set<String>, downloaded: Set<String> = [], now: Date) -> [String] {
        let wanted = PriceDay.wanted(now: now)
        return PriceDay.days(in: window)
            .filter { day in
                day <= wanted && day >= firstArchiveDay && !dayFiles.contains(day) && !archives.contains(day)
                    && !failed.contains(day) && !notFound.contains(day) && !downloaded.contains(day)
            }
            .sorted(by: >)
    }

    /// The line under the chart while days are missing and the download is not on (A33).
    static func lineText(missing: Int) -> String {
        "Prices of \(missing) of the last 90 days are missing."
    }

    /// The line under the chart while the download runs.
    static func progressText(done: Int, total: Int) -> String {
        "Downloading price history: \(done) of \(total) days."
    }

    /// The status line while the download runs.
    static func statusText(done: Int, total: Int) -> String {
        "Price history: \(done) of \(total) days"
    }

    /// The status line, once, when a day's download fails (the queue stops for the run).
    static func failureText(day: String) -> String {
        "Price history: \(day) could not be downloaded."
    }

    /// The line on an iPhone whose network is expensive or constrained (A46).
    static let waitsForWiFi = "Price history downloads on Wi-Fi."

    /// The button under the chart and the Catalog menu's item lead to this dialog.
    static let buttonTitle = "Download 90 days of price history…"
    static let menuTitle = "Download Price History…"
    static let confirmTitle = "Download"

    /// K12: missing days × 4.2 MB, rounded to 10 MB (10 MB at least), and missing days × 4 s, rounded up to whole minutes
    /// (1 minute at least). Phase 5B task 6 measured 3.2–5.1 s per day for a decode through the gate on the owner's
    /// archives (the plan's 2 s was 5A's archive read alone); the download's own time is not in it.
    static func confirmation(missing: Int) -> (title: String, message: String) {
        let megabytes = max(10, Int((Double(missing) * 4.2 / 10).rounded()) * 10)
        let minutes = max(1, (missing * 4 + 59) / 60)
        let files = missing == 1 ? "1 file" : "\(missing) files"
        let time = minutes == 1 ? "about 1 minute" : "about \(minutes) minutes"
        return ("Download 90 days of price history?",
                "About \(megabytes) MB in \(files), one at a time, in the background. It takes \(time). Each day is downloaded once.")
    }

    /// A46, the iPhone's network rule: the download runs only on a path that is neither expensive (cellular, a personal
    /// hotspot) nor constrained (Low Data Mode). The Mac does not ask.
    static func allowsBackfill(expensive: Bool, constrained: Bool) -> Bool {
        !expensive && !constrained
    }
}
