import Foundation
import Testing
@testable import TCGCollection2

/// K7 and K12 (phase 5B task 5): which days the 90-day download fetches, and the texts that name them.
struct MissingDaysTests {
    /// 2026-01-03, morning UTC: the wanted day is 2026-01-02, the window 2025-10-05…2026-01-02.
    static let now = TCGDate.date("2026-01-03T10:00:00")!
    static let window = PriceDay.window(endingOn: "2026-01-02")

    @Test func missingDaysSkipDayFilesArchivesFailedAndNotFound() {
        let days = MissingDays.days(window: Self.window, dayFiles: ["2026-01-02"], archives: ["2026-01-01"],
                                    failed: ["2025-12-31"], notFound: ["2025-12-30"], now: Self.now)
        #expect(days.count == 86)
        #expect(days.first == "2025-12-29")
        #expect(!days.contains("2026-01-02") && !days.contains("2026-01-01"))
        #expect(!days.contains("2025-12-31") && !days.contains("2025-12-30"))
        #expect(days.last == "2025-10-05")
    }

    /// Review round 1, finding 2 (A47): a day this device downloaded before is never missing again.
    @Test func missingDaysSkipDaysDownloadedBefore() {
        let days = MissingDays.days(window: Self.window, dayFiles: [], archives: [], failed: [], notFound: [],
                                    downloaded: ["2026-01-02", "2025-11-01"], now: Self.now)
        #expect(days.count == 88)
        #expect(!days.contains("2025-11-01"))
    }

    @Test func missingDaysStopAtTheFirstArchiveDay() {
        // The window 2023-12-21…2024-03-19: only 2024-02-08 and later.
        let window = PriceDay.window(endingOn: "2024-03-19")
        let now = TCGDate.date("2024-03-20T10:00:00")!
        let days = MissingDays.days(window: window, dayFiles: [], archives: [], failed: [], notFound: [], now: now)
        #expect(days.last == "2024-02-08")
        #expect(days.first == "2024-03-19")
        #expect(days.count == 41)
    }

    @Test func andAtTheWantedDay() {
        // A window that ends after the wanted day (the clock moved back): no day after the wanted one.
        let days = MissingDays.days(window: PriceDay.window(endingOn: "2026-01-05"), dayFiles: [], archives: [],
                                    failed: [], notFound: [], now: Self.now)
        #expect(days.first == "2026-01-02")
        #expect(!days.contains("2026-01-03"))
    }

    @Test func newestFirst() {
        let days = MissingDays.days(window: Self.window, dayFiles: [], archives: [], failed: [], notFound: [], now: Self.now)
        #expect(days == days.sorted(by: >))
        #expect(days.count == 90)
    }

    @Test func theConfirmationNamesSizeFilesAndMinutes() {
        let three = MissingDays.confirmation(missing: 3)
        #expect(three.title == "Download 90 days of price history?")
        #expect(three.message == "About 10 MB in 3 files, one at a time, in the background. It takes about 1 minute. Each day is downloaded once.")
        let ninety = MissingDays.confirmation(missing: 90)
        #expect(ninety.message == "About 380 MB in 90 files, one at a time, in the background. It takes about 6 minutes. Each day is downloaded once.")
        #expect(MissingDays.confirmation(missing: 1).message.hasPrefix("About 10 MB in 1 file,"))
        #expect(MissingDays.lineText(missing: 89) == "Prices of 89 of the last 90 days are missing.")
        #expect(MissingDays.stoppedText(missing: 16)
                == "Prices of 16 of the last 90 days are missing. The download stopped and goes on at the next launch.")
    }

    @Test func theIPhoneNetworkRule() {
        #expect(MissingDays.allowsBackfill(expensive: false, constrained: false))
        #expect(!MissingDays.allowsBackfill(expensive: true, constrained: false))
        #expect(!MissingDays.allowsBackfill(expensive: false, constrained: true))
        #expect(!MissingDays.allowsBackfill(expensive: true, constrained: true))
    }
}
