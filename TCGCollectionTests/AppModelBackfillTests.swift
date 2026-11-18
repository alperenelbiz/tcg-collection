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
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network)
        await model.start()
        await model.waitForBackfill()
        let calls = await network.calls
        #expect(calls.count == 90)                                               // no question: the backfill ran
        #expect(exists(AppPaths(root: root).priceDay("2025-12-20")))
        #expect(model.backfillOptedIn)
    }

    // MARK: Each day once (A32)

    /// Final fix wave, item 3: three not-found answers stop the queue for the run (a window full of 404s points to a
    /// wrong clock); a 404 day is not missing and is not asked again in the run.
    @Test(.timeLimit(.minutes(1))) func threeNotFoundAnswersStopTheBackfillForTheRun() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        let model = model(root, network)
        await model.start()
        model.startBackfill()
        await model.waitForBackfill()
        #expect(await network.calls == [Self.wanted, "2026-01-01", "2025-12-31", "2025-12-30", "2025-12-29"])
        #expect(!model.missingDays.contains("2025-12-31"))                      // a 404 is not missing in this run
        #expect(model.backfillProgress == nil)
        #expect(!model.canAskBackfill)
        // Feedback 1: the line stays and says the download stopped; the 3 404 days are gaps, not counted.
        #expect(model.backfillLine?.text == MissingDays.stoppedText(missing: 85))
        #expect(model.backfillLine?.button == false)
        model.startBackfill()                                                    // the menu item clicked again
        await model.waitForBackfill()
        #expect(await network.calls.count == 5)
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

    // MARK: The iPhone in the background (Task 1B, A64)

    /// A64: the app goes to the background while a day of the queue downloads. The request is cancelled, and a cancel is
    /// no failure: no sentence, the queue not stopped for the run, the day not failed in the lane. Back to the
    /// foreground, the queue asks for that day again and finishes.
    @Test(.timeLimit(.minutes(1))) func aBackgroundCancelLeavesNoFailure() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network)
        await model.start()
        await network.hold("2026-01-01", cancellable: true)
        model.startBackfill()
        try await until { await network.holding }
        model.sceneWentToBackground()
        try await until { model.backfillTask == nil }
        #expect(model.statusNotice == nil)
        #expect(!model.backfillStopped)
        #expect(await !model.priceSync.downloads.failed.contains("2026-01-01"))
        #expect(await !model.priceSync.downloads.backgroundStopped)
        #expect(!model.backfillMayRun)
        #expect(!exists(paths.priceDay("2026-01-01")))
        await network.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await network.calls.filter { $0 == "2026-01-01" }.count == 1)    // nothing asked in the background
        model.sceneBecameActive()
        try await until { await network.calls.filter { $0 == "2026-01-01" }.count == 2 }
        try await until { model.backfillTask == nil && model.backfillProgress == nil }
        await model.waitForBackfill()
        #expect(exists(paths.priceDay("2026-01-01")))
        #expect(model.missingDays.isEmpty)
        #expect(model.statusNotice == nil)
        #expect(!model.backfillStopped)
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
        // Feedback 1: the line stays after the stop and counts the failed day (it is asked at the next launch).
        #expect(model.backfillLine?.text == MissingDays.stoppedText(missing: 88))
        #expect(model.backfillLine?.button == false)
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

    /// Task 6 review, item 1: a day the launch's migration decoded (an archive the 5A price step downloaded) is in the
    /// record, so an opted-in backfill never downloads it again when its day file is lost (A47).
    @Test(.timeLimit(.minutes(1))) func aMigratedDayIsRecordedAndNotDownloadedAgain() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                         to: paths.archives.appending(path: ArchiveGate.archiveName(day: "2025-12-20")))
        let model1 = model(root, BackfillNetwork(served: [Self.wanted]))
        await model1.start()
        await model1.waitForBackfill()
        #expect(exists(paths.priceDay("2025-12-20")))
        let record = Set(try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? [])
        #expect(record.contains("2025-12-20"))
        try FileManager.default.removeItem(at: paths.priceDay("2025-12-20"))
        try optIn(root)
        let second = BackfillNetwork(serveAll: true)
        let model2 = model(root, second)
        await model2.start()
        await model2.waitForBackfill()
        #expect(await !second.calls.contains("2025-12-20"))
        #expect(!model2.missingDays.contains("2025-12-20"))
    }

    /// Task 6 review, item 1: a day file of the window on disk at launch (no archive, never downloaded by this build: a day
    /// held before the record existed) is in the record after the launch.
    @Test(.timeLimit(.minutes(1))) func aDayFileAtLaunchIsRecorded() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let row = PriceDayRow(productID: 700, finish: "Normal", price: ShownPrice(amount: 1.5, isLow: false))
        try PriceDayFile.write(PriceDayFile.data(day: "2025-12-15", rows: [89: [row]]), to: paths.priceDay("2025-12-15"))
        let model = model(root, BackfillNetwork(served: [Self.wanted]))
        await model.start()
        await model.waitForBackfill()
        let record = Set(try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? [])
        #expect(record.contains("2025-12-15"))
        #expect(record.contains(Self.wanted))
    }

    /// Finding 2, as changed by the final fix wave (item 3): the clean-up prunes the record's days more than 2 years
    /// before the window's start (2025-10-05: 730 days before it is 2023-10-06), not the days before the window: a clock
    /// jump must not empty it.
    @Test(.timeLimit(.minutes(1))) func theRecordIsPrunedTwoYearsBeforeTheWindow() async throws {
        let root = tempRoot()
        #expect(ArchiveDownloads.pruneDay(windowStart: "2025-10-05") == "2023-10-06")
        try preferences(root).set(["2023-10-05", "2023-10-06", "2025-01-01", "2025-12-01"],
                                  forKey: AppModel.priceDaysDownloadedKey)
        let network = BackfillNetwork(served: [Self.wanted])
        let model = model(root, network)
        await model.start()
        await model.waitForBackfill()
        let record = Set(try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? [])
        #expect(record == ["2023-10-06", "2025-01-01", "2025-12-01", Self.wanted])
        #expect(!model.missingDays.contains("2025-12-01"))
    }

    /// Finding 4: a gate that closes and opens again while a day is in flight: the queue runs again once it has ended.
    @Test(.timeLimit(.minutes(1))) func theQueueRunsAgainAfterAQuickGateFlip() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(serveAll: true)
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

    // MARK: Review round 2

    /// A: a 200 whose move fails (a full disk): the day is in the record at once, and the next launch on the same
    /// preferences asks nothing for it (A47: it is a gap from now on).
    @Test(.timeLimit(.minutes(1))) func aDayWhoseMoveFailedAfterIts200IsRecorded() async throws {
        let root = tempRoot()
        let first = BackfillNetwork(serveAll: true, moveFails: [Self.wanted])
        let model1 = model(root, first)
        await model1.start()
        #expect(await first.calls == [Self.wanted])
        let record = try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? []
        #expect(record.contains(Self.wanted))
        #expect(!model1.canAskBackfill)                                          // stopped for the run
        let second = BackfillNetwork(serveAll: true)
        let model2 = model(root, second)
        await model2.start()
        #expect(await !second.calls.contains(Self.wanted))
    }

    /// B: a Refresh's price step that throws turns the line's button and the menu item off.
    @Test(.timeLimit(.minutes(1))) func aRefreshWhosePriceStepThrewTurnsTheAskOff() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(served: [Self.wanted], failing: ["2026-01-03"])
        let clock = Clock(Self.day1)
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"]),
                             catalogClient: network, archiveClient: network, fetcher: network, now: { clock.date })
        await model.start()
        #expect(model.canAskBackfill)
        clock.date = TCGDate.date("2026-01-03T21:00:00")!
        await model.refresh(rebuild: false)
        #expect(await network.calls.contains("2026-01-03"))
        #expect(!model.canAskBackfill)
        #expect(model.backfillLine?.button != true)
    }
}


// MARK: The final fix wave (after the whole-branch review)

@MainActor
struct AppModelBackfillFinalFixTests {
    static let day1 = AppModelBackfillTests.day1
    static let wanted = AppModelBackfillTests.wanted
    static let windowDays = AppModelBackfillTests.windowDays

    private func model(_ root: URL, _ network: BackfillNetwork, now: @escaping () -> Date = { Self.day1 })
        -> AppModel {
        AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"]),
                 catalogClient: network, archiveClient: network, fetcher: network, now: now)
    }

    private func preferences(_ root: URL) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: AppPaths(root: root).support.appending(path: "preferences").path))
    }

    private func optIn(_ root: URL) throws {
        try preferences(root).set(true, forKey: AppModel.priceDaysDownloadKey)
    }

    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the condition never held")
    }

    /// Item 3: a launch with the clock 100 days ahead, then a launch with the right clock. The record keeps the real
    /// window's days (pruned 2 years before the window, not at it), so no day of the real window is requested again; the
    /// day files the clean-up deleted under the wrong clock stay gaps (the stated limit). Under the wrong clock the queue
    /// stops after three 404s.
    @Test(.timeLimit(.minutes(2))) func aClockJumpDoesNotLeadToARedownload() async throws {
        let root = tempRoot()
        try optIn(root)
        let real = Set(Self.windowDays)
        let first = BackfillNetwork(served: real)
        let model1 = model(root, first)
        await model1.start()
        await model1.waitForBackfill()
        #expect(await first.calls.count == 90)

        let ahead = BackfillNetwork(served: real)
        let model2 = model(root, ahead, now: { Self.day1.addingTimeInterval(100 * 86_400) })
        await model2.start()
        await model2.waitForBackfill()
        await model2.priceDaysCleaning?.value
        let aheadCalls = await ahead.calls
        #expect(aheadCalls.allSatisfy { !real.contains($0) })
        #expect(aheadCalls.count == 5)                                           // the price step's 2, the queue's 3
        #expect(PriceDayFile.days(in: AppPaths(root: root).priceDays).isEmpty)   // the clean-up deleted the real days

        let back = BackfillNetwork(served: real)
        let model3 = model(root, back)
        await model3.start()
        await model3.waitForBackfill()
        #expect(await back.calls.isEmpty)
        #expect(model3.missingDays.isEmpty)                                      // gaps, not missing days
        // The wrong clock's 404s are not kept: no day newer than them was held.
        #expect(try preferences(root).stringArray(forKey: ArchiveDownloads.notFoundKey) == nil)
    }

    /// Item 4: a 404 is remembered across runs (`priceDaysNotFound`, kept only for a day older than a day this device
    /// holds): the next run does not request it, and it is not missing.
    @Test(.timeLimit(.minutes(1))) func aNotFoundDayIsNotRequestedInTheNextRun() async throws {
        let root = tempRoot()
        try optIn(root)
        let first = BackfillNetwork(served: [Self.wanted, "2026-01-01"])
        let model1 = model(root, first)
        await model1.start()
        await model1.waitForBackfill()
        #expect(await first.calls == [Self.wanted, "2026-01-01", "2025-12-31", "2025-12-30", "2025-12-29"])
        let kept = Set(try preferences(root).stringArray(forKey: ArchiveDownloads.notFoundKey) ?? [])
        #expect(kept == ["2025-12-31", "2025-12-30", "2025-12-29"])
        let second = BackfillNetwork(serveAll: true)
        let model2 = model(root, second)
        await model2.start()
        await model2.waitForBackfill()
        let calls = await second.calls
        #expect(!calls.contains("2025-12-31") && !calls.contains("2025-12-30") && !calls.contains("2025-12-29"))
        #expect(calls.count == 85)                                               // every other day of the window
        #expect(!model2.missingDays.contains("2025-12-31"))
    }

    /// Item 5: a `.failed` status is not hidden behind the download's progress. A Refresh whose set lists fail while the
    /// queue has days left: the status line says the failure, not "Price history: n of m days".
    @Test(.timeLimit(.minutes(1))) func aFailedStatusShowsOverTheProgress() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(serveAll: true)
        let model = model(root, network)
        await model.start()
        await network.hold("2025-12-31")
        model.startBackfill()
        try await until { await network.holding }
        #expect(model.statusLineText.hasPrefix("Price history: "))
        await network.failGroups(true)
        // The Refresh has two catalog steps (the game on screen, then the others); each waits for the day in flight. The
        // queue's request between them is held, then released while the next day is held, so the Refresh can end while
        // the queue still has a day in flight.
        let refresh = Task { await model.refresh(rebuild: false) }
        try await Task.sleep(for: .milliseconds(300))
        await network.moveHold(to: "2025-12-30")
        try await until { await network.holding }
        try await Task.sleep(for: .milliseconds(300))
        await network.moveHold(to: "2025-12-29")
        await refresh.value
        try await until { await network.holding }
        guard case .failed(let text) = model.status else {
            Issue.record("the refresh did not fail: \(model.status)")
            return
        }
        #expect(model.backfillProgress != nil)
        #expect(model.statusLineText == text)
        model.stopBackfill()
        await network.release()
        await model.waitForBackfill()
    }

    /// Item 6: no archive request of the queue starts while a catalog step's requests run, and the app never has more
    /// than 4 requests at tcgcsv at once (one count over set lists, products and archives).
    @Test(.timeLimit(.minutes(1))) func noArchiveRequestRunsBesideACatalogStep() async throws {
        let root = tempRoot()
        let network = BackfillNetwork(serveAll: true)
        let clock = Clock(Self.day1)
        let model = model(root, network, now: { clock.date })
        await model.start()
        await network.hold("2025-12-31")
        model.startBackfill()
        try await until { await network.holding }
        clock.date = TCGDate.date("2026-01-04T10:00:00")!                       // a new UTC day: every set is fetched
        await network.holdProducts()
        let refresh = Task { await model.refresh(rebuild: true) }
        try await Task.sleep(for: .milliseconds(300))
        await network.release()
        try await until { await network.productsHolding }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await network.archivesStartedWhileProductsHeld == 0)
        #expect(!model.missingDays.isEmpty)                                      // the queue has days left
        await network.releaseProducts()
        await refresh.value
        model.stopBackfill()
        await model.waitForBackfill()
        #expect(await network.sharedMaxInFlight <= 4)
    }

    /// Item 7: the migration records every archive day of the window it finds, also one whose decode fails (it was
    /// received). Deleted later by an outside cleaner, that day is not requested.
    @Test(.timeLimit(.minutes(1))) func anArchiveThatDoesNotDecodeIsRecorded() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let archive = paths.archives.appending(path: ArchiveGate.archiveName(day: "2025-12-20"))
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("not-an-archive.7z"), to: archive)
        let model1 = model(root, BackfillNetwork(served: [Self.wanted]))
        await model1.start()
        await model1.waitForBackfill()
        #expect(FileManager.default.fileExists(atPath: archive.path))           // the gate keeps it
        let record = Set(try preferences(root).stringArray(forKey: AppModel.priceDaysDownloadedKey) ?? [])
        #expect(record.contains("2025-12-20"))
        try FileManager.default.removeItem(at: archive)                         // an outside cleaner
        try optIn(root)
        let second = BackfillNetwork(serveAll: true)
        let model2 = model(root, second)
        await model2.start()
        await model2.waitForBackfill()
        #expect(await !second.calls.contains("2025-12-20"))
        #expect(!model2.missingDays.contains("2025-12-20"))
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
    private let moveFails: Set<String>
    private(set) var calls: [String] = []
    /// The days whose answer was written to the archive's name.
    private(set) var completed: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var held: String?
    private var cut: String?
    private(set) var holding = false
    private var waiting: CheckedContinuation<Void, Never>?

    /// Final fix wave, item 6: one count of the requests in flight over groups, products and archives together.
    private var sharedInFlight = 0
    private(set) var sharedMaxInFlight = 0
    /// Item 6: the first products request waits while `productsHeld`; archive requests that start meanwhile are counted.
    private var productsHeld = false
    private(set) var productsHolding = false
    private var productsWaiting: CheckedContinuation<Void, Never>?
    private(set) var archivesStartedWhileProductsHeld = 0
    /// Item 5: every set list request fails while true.
    private var groupsFail = false
    private let timingOut: Set<String>

    init(serveAll: Bool = false, served: Set<String> = [], broken: Set<String> = [], failing: Set<String> = [],
         statuses: [String: Int] = [:], moveFails: Set<String> = [], timingOut: Set<String> = []) {
        self.timingOut = timingOut
        self.statuses = statuses
        self.moveFails = moveFails
        self.serveAll = serveAll
        self.served = served
        self.broken = broken
        self.failing = failing
    }

    /// The download of `day` waits until `release()`. With `cancellable` (Task 1B) it also ends when its task is
    /// cancelled, as URLSession's does (`URLError.cancelled`); without it a cancel waits for `release()` as before.
    func hold(_ day: String, cancellable: Bool = false) {
        held = day
        heldCancellable = cancellable
    }

    private var heldCancellable = false

    /// The download of `day` writes half a file under a temporary name, then waits until its task is cancelled.
    func cutShort(_ day: String) { cut = day }

    func release() {
        held = nil
        holding = false
        waiting?.resume()
        waiting = nil
    }

    /// Releases the held day and holds `next` in one step (no request can start between the two).
    func moveHold(to next: String) {
        held = next
        holding = false
        waiting?.resume()
        waiting = nil
    }

    /// Task 1B: a held download ends when its task is cancelled, as URLSession's does (`URLError.cancelled`).
    private func waitWhileHeld() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiting = continuation }
            }
        } onCancel: {
            Task { await self.wakeCancelled() }
        }
        if Task.isCancelled { throw URLError(.cancelled) }
    }

    private func wakeCancelled() {
        holding = false
        waiting?.resume()
        waiting = nil
    }

    /// Task 1B: every products request after the first `count` answers waits until `releaseProducts()` or until its task
    /// is cancelled (then it throws `URLError.cancelled`, as URLSession does).
    func holdProducts(after count: Int) { productsAnswerLimit = count }

    private var productsAnswerLimit: Int?
    private var productsLimitWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Every products request, by set, in order; and the sets whose products were answered.
    private(set) var productCalls: [Int] = []
    private(set) var productsAnswered: [Int] = []
    /// The products requests waiting for `releaseProducts()` now.
    var productsWaitingCount: Int { productsLimitWaiters.count }

    private func waitForProductsLimit() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { productsLimitWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.wakeProducts(id) }
        }
        if Task.isCancelled { throw URLError(.cancelled) }
    }

    private func wakeProducts(_ id: UUID) {
        productsLimitWaiters.removeValue(forKey: id)?.resume()
    }

    func holdProducts() { productsHeld = true }

    func releaseProducts() {
        productsHeld = false
        productsWaiting?.resume()
        productsWaiting = nil
        productsAnswerLimit = nil
        let waiters = productsLimitWaiters
        productsLimitWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    func failGroups(_ fail: Bool) { groupsFail = fail }

    private func enter() {
        sharedInFlight += 1
        sharedMaxInFlight = max(sharedMaxInFlight, sharedInFlight)
    }

    private(set) var groupCalls = 0

    func groups(category: Int) async throws -> Data {
        groupCalls += 1
        enter()
        defer { sharedInFlight -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        if groupsFail { throw URLError(.notConnectedToInternet) }
        return category == 89 ? try fixture("groups-89.json") : Self.noSets
    }

    func products(category: Int, group: Int) async throws -> Data {
        productCalls.append(group)
        enter()
        defer { sharedInFlight -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        if let limit = productsAnswerLimit, productsAnswered.count >= limit {
            try await waitForProductsLimit()
        }
        if productsHeld, !productsHolding {
            productsHolding = true
            await withCheckedContinuation { productsWaiting = $0 }
            productsHolding = false
        }
        productsAnswered.append(group)
        return try fixture("products-89.json")
    }

    func download(day: String, to file: URL) async throws -> Bool {
        calls.append(day)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        enter()
        if productsHolding { archivesStartedWhileProductsHeld += 1 }
        defer {
            inFlight -= 1
            sharedInFlight -= 1
        }
        try await Task.sleep(for: .milliseconds(2))
        if held == day {
            holding = true
            if heldCancellable {
                try await waitWhileHeld()
            } else {
                await withCheckedContinuation { waiting = $0 }
            }
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
        if timingOut.contains(day) { throw URLError(.timedOut) }
        if let status = statuses[day] { throw TCGCSVClientError(status: status) }
        if moveFails.contains(day) {
            throw ArchiveStoreError(underlying: CocoaError(.fileWriteOutOfSpace))   // a 200, then the move failed
        }
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

    /// The Yu-Gi-Oh! picture index answers (final fix wave, item 5: else every launch's status is a failure, which the
    /// status line now shows over the download's progress); pictures are not served.
    func data(from url: URL) async throws -> (Data, Int) {
        guard url.lastPathComponent == "cardinfo.php" else { throw URLError(.notConnectedToInternet) }
        indexCalls += 1
        if indexHeld {
            indexWaiting = true
            try? await Task.sleep(for: .seconds(30))       // ends at the cancel
            indexWaiting = false
            throw URLError(.cancelled)
        }
        return (try fixture("cardinfo-sample.json"), 200)
    }

    /// Fix wave item 2: the picture index request waits until its task is cancelled, then throws `URLError.cancelled`.
    func holdIndex() { indexHeld = true }
    private var indexHeld = false
    private(set) var indexWaiting = false
    private(set) var indexCalls = 0
}

/// A clock a test moves.
final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

extension BackfillNetwork: TCGCSVFetching, ArchiveFetching, DataFetching {}
