import Foundation
import Testing
@testable import TCGCollection2

/// The model's day files (phase 5B task 2: K4, K10, K11): the launch migrates the archives on disk through the gate and
/// cleans up; a day decoded only for the cache never replaces a newer price table.
@MainActor
struct AppModelPriceDaysTests {
    /// On this morning (UTC) the window ends on 2026-01-02 (it starts on 2025-10-05).
    static let day1 = TCGDate.date("2026-01-03T10:00:00")!

    private func offlineModel(_ root: URL) -> AppModel {
        AppModel(options: .init(arguments: ["app", "-store", root.path, "-offline", "YES", "-game", "riftbound"]),
                 catalogClient: NoNetwork(), archiveClient: NoNetwork(), fetcher: NoNetwork(), now: { Self.day1 })
    }

    private func place(_ paths: AppPaths, _ days: [String]) throws {
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        for day in days {
            try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                             to: paths.archives.appending(path: HistoryPass.archiveName(day: day)))
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// K4: the price table holds 2026-01-02; an archive of 2025-12-20 on disk is migrated into its day file and deleted,
    /// and the table keeps its day.
    @Test(.timeLimit(.minutes(1))) func aDayDecodedOnlyForTheCacheDoesNotReplaceANewerTable() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let table = GamePrices(day: "2026-01-02", finishes: ["Normal"], rows: [721334: [0: Price(market: 7, low: nil, mid: nil, high: nil)]])
        try JSONEncoder().encode(table).write(to: paths.prices("riftbound"))
        try place(paths, ["2025-12-20"])
        let model = offlineModel(root)
        await model.start()
        #expect(model.prices.day(game: "riftbound") == "2026-01-02")
        #expect(model.prices.shown(game: "riftbound", key: PrintingKey(productID: 721334, finish: "Normal"))?.amount == 7)
        #expect(exists(paths.priceDay("2025-12-20")))
        #expect(!exists(paths.archives.appending(path: HistoryPass.archiveName(day: "2025-12-20"))))
        #expect(model.priceDaysVersion == 1)
    }

    /// K11: an offline launch migrates every archive of the window (newest first); the table takes the newest day; an
    /// archive before the window is deleted without a decode (K10).
    @Test(.timeLimit(.minutes(1))) func theLaunchMigratesTheArchivesOnDiskAndCleansUp() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try place(paths, ["2025-12-30", "2025-12-31", "2025-09-01"])
        let model = offlineModel(root)
        await model.start()
        #expect(model.prices.day(game: "riftbound") == "2025-12-31")
        #expect(PriceDayFile.days(in: paths.priceDays) == ["2025-12-30", "2025-12-31"])
        #expect(HistoryPass.archiveDays(in: paths.archives).isEmpty)
        #expect(model.priceDaysVersion == 2)
    }
}
