import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// The 90-day download (phase 5B task 5: A32, A33, A46, A48, K7–K9). On `day1` (2026-01-03, morning UTC) the wanted day is
/// 2026-01-02 and the window 2025-10-05…2026-01-02: the price step downloads 2026-01-02, the backfill the other 89 days.
/// The fake network serves the fixture archive for the days it is told to (any day with `serveAll`), else a 404; it
/// counts every archive request per day and how many run at once.
@MainActor
struct AppModelBackfillTests {
    static let day1 = TCGDate.date("2026-01-03T10:00:00")!
    static let wanted = "2026-01-02"
    static let windowDays = PriceDay.days(in: PriceDay.window(endingOn: "2026-01-02"))

    private func model(_ root: URL, _ network: BackfillNetwork, _ extra: [String] = []) -> AppModel {
        AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"] + extra),
                 catalogClient: network, archiveClient: network, fetcher: network, now: { Self.day1 })
    }

    private func preferences(_ root: URL) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: AppPaths(root: root).support.appending(path: "preferences").path))
    }

    private func optIn(_ root: URL) throws {
        try preferences(root).set(true, forKey: AppModel.priceDaysDownloadKey)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the condition never held")
    }

    // MARK: The opt-in (A32, A33, A48)

    @Test(.timeLimit(.minutes(1))) func nothingDownloadsBeforeTheYes() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network)
        await model.start()
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted])                          // only the daily file
        #expect(!model.backfillOptedIn)
        #expect(model.missingDays.count == 89)
        #expect(model.missingDays.first == "2026-01-01")
        #expect(model.backfillProgress == nil)
        #expect(try preferences(root).object(forKey: AppModel.priceDaysDownloadKey) == nil)
    }

    @Test(.timeLimit(.minutes(2))) func afterTheYesEveryMissingDayDownloadsOnceOneAtATime() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        #expect(model.backfillOptedIn)
        #expect(try preferences(root).bool(forKey: AppModel.priceDaysDownloadKey))
        await model.waitForBackfill()
        let calls = await network.calls
        #expect(calls.count == 90)
        #expect(Set(calls) == Set(Self.windowDays))                              // each day once
        #expect(Array(calls.dropFirst()) == Self.windowDays.dropLast().reversed())   // newest first
        #expect(await network.maxInFlight == 1)
        #expect(PriceDayFile.days(in: paths.priceDays) == Set(Self.windowDays))
        #expect(ArchiveGate.archiveDays(in: paths.archives).isEmpty)
        #expect(model.missingDays.isEmpty)
        #expect(model.backfillProgress == nil)
        #expect(model.priceDaysVersion == 90)
        // The table keeps the newest day (K4).
        #expect(model.prices.day(game: "riftbound") == Self.wanted)
    }

    @Test(.timeLimit(.minutes(2))) func aSecondLaunchDownloadsNothingNew() async throws {
        let root = tempRoot()
        let first = BackfillNetwork(serveAll: true)
        let model1 = model(root, first)
        await model1.start()
        model1.startBackfill()
        await model1.waitForBackfill()
        #expect(await first.calls.count == 90)
        let second = BackfillNetwork(serveAll: true)
        let model2 = model(root, second)
        await model2.start()
        await model2.waitForBackfill()
        #expect(await second.calls.isEmpty)
        #expect(model2.backfillOptedIn)
        #expect(model2.missingDays.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func theYesIsRemembered() async throws {
        let root = tempRoot()
        try optIn(root)
        let network = BackfillNetwork(served: [Self.wanted, "2025-12-20"])
        let model = model(root, network)
        await model.start()
        await model.waitForBackfill()
        let calls = await network.calls
        #expect(calls.count == 90)                                               // no question: the backfill ran
        #expect(exists(AppPaths(root: root).priceDay("2025-12-20")))
        #expect(model.backfillOptedIn)
    }

    // MARK: Each day once (A32)

    @Test(.timeLimit(.minutes(1))) func a404IsNotAskedAgainInTheRun() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted])
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.count == 90)
        #expect(model.missingDays.isEmpty)                                       // a 404 is not missing in this run
        model.startBackfill()                                                    // the menu item clicked again
        await model.waitForBackfill()
        #expect(await network.calls.count == 90)
        // The price step asks again (a Refresh): a 404 day of the backfill is not asked by it either.
        #expect(Set(await network.calls).count == 90)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedDecodeIsNotDownloadedAgain() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let network = BackfillNetwork(served: [Self.wanted], broken: ["2026-01-01"])
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.filter { $0 == "2026-01-01" }.count == 1)
        // The gate keeps the archive and names the day failed for the run.
        #expect(exists(paths.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-01"))))
        #expect(!exists(paths.priceDay("2026-01-01")))
        #expect(!model.missingDays.contains("2026-01-01"))
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.filter { $0 == "2026-01-01" }.count == 1)
    }

    /// Review Focus 1: a day whose archive appears after the queue was planned (another path made it) is decoded, never
    /// downloaded.
    @Test(.timeLimit(.minutes(1))) func aDayWhoseArchiveAppearedAfterThePlanIsNotDownloaded() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        let model = model(root, network)
        await model.start()
        await network.hold("2026-01-01")
        model.startBackfill()
        try await until { await network.holding }
        #expect(model.backfillProgress?.total == 89)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                         to: paths.archives.appending(path: ArchiveGate.archiveName(day: "2025-12-31")))
        await network.release()
        await model.waitForBackfill()
        #expect(await !network.calls.contains("2025-12-31"))
        #expect(exists(paths.priceDay("2025-12-31")))
        #expect(!exists(paths.archives.appending(path: ArchiveGate.archiveName(day: "2025-12-31"))))
    }

    /// A32 and tcgcsv's 4 requests at a time: a Refresh while a day of the queue downloads. Its catalog step waits for that
    /// request to end, and its price step's request (a new wanted day: the clock passed 20:30 UTC) never runs beside it.
    @Test(.timeLimit(.minutes(1))) func aRefreshWaitsForTheDayInFlight() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01", "2026-01-03"])
        let clock = Clock(Self.day1)
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"]),
                             catalogClient: network, archiveClient: network, fetcher: network, now: { clock.date })
        await model.start()
        let groupsBefore = await network.groupCalls
        await network.hold("2026-01-01")
        model.startBackfill()
        try await until { await network.holding }
        clock.date = TCGDate.date("2026-01-03T21:00:00")!                       // the wanted day is now 2026-01-03
        let refresh = Task { await model.refresh(rebuild: false) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await network.groupCalls == groupsBefore)                       // the catalog step waits
        #expect(await !network.calls.contains("2026-01-03"))
        await network.release()
        await refresh.value
        await model.waitForBackfill()
        #expect(await network.maxInFlight == 1)
        #expect(await network.calls.filter { $0 == "2026-01-03" }.count == 1)
        #expect(Set(await network.calls).count == (await network.calls).count)  // no day asked twice
    }

    /// A quit while a day downloads: the archive's name never holds a partial file (only a temporary name does); the next
    /// launch deletes the temporary file and downloads the day once. Across the two runs the day is downloaded once to the
    /// end (the first request never completed).
    @Test(.timeLimit(.minutes(1))) func aQuitMidDownloadLeavesNoArchiveAndTheNextLaunchFinishesTheDay() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let first = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        await first.cutShort("2026-01-01")
        let model1 = model(root, first)
        await model1.start()
        model1.startBackfill()
        try await until { await first.holding }
        model1.stopBackfill()                                                    // the quit
        await model1.waitForBackfill()
        let partial = paths.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-01") + ".part")
        #expect(exists(partial))
        #expect(!exists(paths.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-01"))))
        #expect(await !first.completed.contains("2026-01-01"))

        let second = BackfillNetwork(served: ["2026-01-01"])
        let model2 = model(root, second)
        await model2.start()
        await model2.waitForBackfill()
        await model2.priceDaysCleaning?.value
        #expect(!exists(partial))
        #expect(exists(paths.priceDay("2026-01-01")))
        #expect(await second.calls.filter { $0 == "2026-01-01" }.count == 1)
        #expect(await second.completed == ["2026-01-01"])
    }

    // MARK: The gates (Review Focus 3)

    @Test(.timeLimit(.minutes(1))) func noBackfillOffline() async throws {
        let root = tempRoot()
        try optIn(root)
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network, ["-offline", "YES"])
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func noBackfillWhileTheFirstRunQuestionIsDue() async throws {
        let root = tempRoot()
        try optIn(root)
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network, ["-onboarding", "YES"])
        let run = Task { await model.start() }
        try await until { model.library.isLoaded }
        #expect(model.onboardingDue)
        model.startBackfill()
        try await Task.sleep(for: .milliseconds(500))
        await model.waitForBackfill()
        #expect(await network.calls.isEmpty)
        run.cancel()
    }

    @Test(.timeLimit(.minutes(1))) func noBackfillWithoutAFolder() async throws {
        let root = tempRoot()
        try optIn(root)
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network, ["-askUserFolder", "YES"])
        let run = Task { await model.start() }
        #expect(model.needsUserFolder)
        try await Task.sleep(for: .milliseconds(300))
        model.startBackfill()
        try await Task.sleep(for: .milliseconds(300))
        await model.waitForBackfill()
        #expect(await network.calls.isEmpty)
        run.cancel()
    }

    @Test(.timeLimit(.minutes(1))) func noBackfillAfterACatalogReset() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network)
        await model.start()
        await network.hold("2025-12-31")
        model.startBackfill()
        try await until { await network.holding }
        model.requestCatalogReset()
        await network.release()
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted, "2026-01-01", "2025-12-31"])
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.count == 3)
        #expect(model.backfillProgress == nil)
    }

    // MARK: App Nap (K9)

    @Test(.timeLimit(.minutes(1))) func theActivityIsHeldWhileTheQueueWorks() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        let model = model(root, network)
        let begins = Mutex<[String]>([]), ends = Mutex(0)
        model.backfillActivity = { reason in
            begins.withLock { $0.append(reason) }
            return { ends.withLock { $0 += 1 } }
        }
        await model.start()
        await model.waitForBackfill()
        // The launch's price step and migration hold it too (review round 1, finding 7); each ended. Counted from here.
        #expect(ends.withLock { $0 } == begins.withLock { $0 }.count)
        begins.withLock { $0 = [] }
        ends.withLock { $0 = 0 }
        await network.hold("2026-01-01")
        model.startBackfill()
        try await until { await network.holding }
        #expect(begins.withLock { $0 } == ["Reading price history"])
        #expect(ends.withLock { $0 } == 0)
        await network.release()
        await model.waitForBackfill()
        #expect(begins.withLock { $0 }.count == 1)
        #expect(ends.withLock { $0 } == 1)
    }

    // MARK: The status line

    @Test(.timeLimit(.minutes(1))) func theStatusLineSaysTheProgressThenTheUsualLine() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        let model = model(root, network)
        await model.start()
        let usual = model.statusLineText
        await network.hold("2025-12-31")
        model.startBackfill()
        try await until { await network.holding }
        #expect(model.backfillProgress == BackfillProgress(done: 1, total: 89))
        #expect(model.statusLineText == "Price history: 1 of 89 days")
        await network.release()
        await model.waitForBackfill()
        #expect(model.statusLineText == usual)
    }

    @Test(.timeLimit(.minutes(1))) func aNetworkErrorStopsTheQueueAndSaysItOnce() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01"], failing: ["2025-12-31"])
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted, "2026-01-01", "2025-12-31"])
        #expect(model.statusNotice == "Price history: 2025-12-31 could not be downloaded.")
        #expect(exists(AppPaths(root: root).priceDay("2026-01-01")))            // the days done are kept
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.count == 3)                                  // stopped for the run
    }

    // MARK: Review round 1

    /// Finding 1: the price step's request for the wanted day throws (no network); the opted-in backfill does not ask for
    /// that day again in the run (nor any day: a network error stops the backfill for the run).
    @Test(.timeLimit(.minutes(1))) func aDayWhosePriceStepRequestThrewIsNotRequestedAgain() async throws {
        let root = tempRoot()
        try optIn(root)
        let network = BackfillNetwork(serveAll: true, failing: [Self.wanted])
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted])
        #expect(!model.missingDays.contains(Self.wanted))
        #expect(!model.canAskBackfill)                                           // finding 5: stopped for the run
    }

    /// Finding 1: a 500 on day N: the backfill asks for no further day in the run.
    @Test(.timeLimit(.minutes(1))) func a500StopsTheBackfillForTheRun() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(serveAll: true, statuses: ["2025-12-31": 500])
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted, "2026-01-01", "2025-12-31"])
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls.count == 3)
        #expect(!model.canAskBackfill)
        #expect(model.backfillLine?.button != true)
    }

    /// Finding 2 (A47): a day downloaded in an earlier run whose day file was deleted is not requested again; the record
    /// is in the device's preferences and survives a relaunch.
    @Test(.timeLimit(.minutes(1))) func aDownloadedDayIsNeverRequestedAgain() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let first = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        let model1 = model(root, first)
        await model1.start()
        model1.startBackfill()
        await model1.waitForBackfill()
        let record = try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? []
        #expect(Set(record) == [Self.wanted, "2026-01-01"])
        try FileManager.default.removeItem(at: paths.priceDay("2026-01-01"))
        let second = BackfillNetwork(serveAll: true)
        let model2 = model(root, second)
        await model2.start()
        await model2.waitForBackfill()
        #expect(await !second.calls.contains("2026-01-01"))
        #expect(await !second.calls.contains(Self.wanted))
        #expect(!model2.missingDays.contains("2026-01-01"))
    }

    /// Finding 2: the clean-up prunes the record's days before the window.
    @Test(.timeLimit(.minutes(1))) func theRecordIsPrunedBeforeTheWindow() async throws {
        let root = tempRoot()
        try preferences(root).set(["2025-01-01", "2025-12-01"], forKey: AppModel.priceDaysDownloadedKey)
        let network = BackfillNetwork(served: [Self.wanted])
        let model = model(root, network)
        await model.start()
        await model.waitForBackfill()
        let record = Set(try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? [])
        #expect(record == ["2025-12-01", Self.wanted])
        #expect(!model.missingDays.contains("2025-12-01"))
    }

    /// Finding 4: a gate that closes and opens again while a day is in flight: the queue runs again once it has ended.
    @Test(.timeLimit(.minutes(1))) func theQueueRunsAgainAfterAQuickGateFlip() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01", "2025-12-20"])
        let model = model(root, network)
        await model.start()
        await network.hold("2026-01-01")
        model.startBackfill()
        try await until { await network.holding }
        model.backfillNetworkAllowed = false
        try await Task.sleep(for: .milliseconds(100))
        model.backfillNetworkAllowed = true
        try await Task.sleep(for: .milliseconds(100))
        await network.release()
        await model.waitForBackfill()
        let calls = await network.calls
        #expect(calls.count == 90)                                               // every day of the window, once
        #expect(Set(calls).count == 90)
    }

    /// Finding 6: the dialog's text is the count of the moment it opened; "Download" with nothing missing by then does
    /// nothing (no yes is stored).
    @Test(.timeLimit(.minutes(1))) func theDialogKeepsItsCountAndDoesNothingWhenNothingIsMissing() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted])
        let model = model(root, network)
        await model.start()
        model.askBackfill()
        #expect(model.asksBackfill)
        let asked = try #require(model.backfillDialog)
        #expect(asked.message.contains("in 89 files"))
        model.missingDays = []
        #expect(model.backfillDialog?.message == asked.message)
        model.startBackfill()
        #expect(!model.backfillOptedIn)
        #expect(try preferences(root).object(forKey: AppModel.priceDaysDownloadKey) == nil)
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted])
    }

    /// Finding 7 (K9): the activity is held around the launch's migration and the price step's decode too.
    @Test(.timeLimit(.minutes(1))) func theActivityIsHeldAroundTheMigrationAndThePriceStep() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                         to: paths.archives.appending(path: ArchiveGate.archiveName(day: "2025-12-20")))
        let network = BackfillNetwork(served: [Self.wanted])
        let model = model(root, network)
        let begins = Mutex(0), ends = Mutex(0)
        model.backfillActivity = { _ in
            begins.withLock { $0 += 1 }
            return { ends.withLock { $0 += 1 } }
        }
        await model.start()
        await model.waitForBackfill()
        #expect(begins.withLock { $0 } >= 2)                                     // the price step and the migration
        #expect(ends.withLock { $0 } == begins.withLock { $0 })
    }
}

/// tcgcsv's fake for the backfill: Riftbound's fixture catalog, no sets of the other games, and the fixture archive for
/// the days served. Counts the archive requests per day and the requests in flight at once.
actor BackfillNetwork {
    private static let noSets = Data(#"{"success":true,"errors":[],"results":[],"totalItems":0}"#.utf8)

    private let serveAll: Bool
    private let served: Set<String>
    private let broken: Set<String>
    private let failing: Set<String>
    private let statuses: [String: Int]
    private(set) var calls: [String] = []
    /// The days whose answer was written to the archive's name.
    private(set) var completed: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var held: String?
    private var cut: String?
    private(set) var holding = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(serveAll: Bool = false, served: Set<String> = [], broken: Set<String> = [], failing: Set<String> = [],
         statuses: [String: Int] = [:]) {
        self.statuses = statuses
        self.serveAll = serveAll
        self.served = served
        self.broken = broken
        self.failing = failing
    }

    /// The download of `day` waits until `release()`.
    func hold(_ day: String) { held = day }

    /// The download of `day` writes half a file under a temporary name, then waits until its task is cancelled.
    func cutShort(_ day: String) { cut = day }

    func release() {
        held = nil
        holding = false
        waiting?.resume()
        waiting = nil
    }

    private(set) var groupCalls = 0

    func groups(category: Int) async throws -> Data {
        groupCalls += 1
        return category == 89 ? try fixture("groups-89.json") : Self.noSets
    }

    func products(category: Int, group: Int) async throws -> Data { try fixture("products-89.json") }

    func download(day: String, to file: URL) async throws -> Bool {
        calls.append(day)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        if held == day {
            holding = true
            await withCheckedContinuation { waiting = $0 }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if cut == day {
            try Data(repeating: 7, count: 100).write(to: file.deletingLastPathComponent()
                .appending(path: file.lastPathComponent + ".part"))
            holding = true
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        if failing.contains(day) { throw URLError(.notConnectedToInternet) }
        if let status = statuses[day] { throw TCGCSVClientError(status: status) }
        if broken.contains(day) {
            try fm.copyItem(at: fixtureURL("not-an-archive.7z"), to: file)
            completed.append(day)
            return true
        }
        guard serveAll || served.contains(day) else { return false }
        try fm.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: file)
        completed.append(day)
        return true
    }

    func data(from url: URL) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}

/// A clock a test moves.
final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

extension BackfillNetwork: TCGCSVFetching, ArchiveFetching, DataFetching {}
