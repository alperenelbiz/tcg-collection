import Foundation
#if os(iOS)
import Network
#endif

/// The opt-in progress of the 90-day download: the days done and the days the queue planned.
nonisolated struct BackfillProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// The 90-day download of daily price archives (phase 5B task 5: A32, A33, A46, A48, K7–K9). The stored properties are in
/// `AppModel.swift` (an extension cannot hold them).
///
/// Nothing is downloaded before the user's yes (`startBackfill`, the dialog's "Download"); after it, every launch
/// downloads the missing days of the window by itself (A48). The queue is one task the model keeps: newest missing day
/// first, one at a time, each day through `ArchiveDownloads` (one archive request at a time in the whole app; a day with a
/// day file or an archive on disk is never asked for; a day downloaded or a 404 in this run is not asked again), then
/// through the archive gate (`ArchiveGate.decodeDay`: the day file is written and verified, then the archive deleted).
extension AppModel {
    // MARK: Questions

    /// The gates of every download of the queue: the app may sync (not offline, a store file open), the folder is chosen
    /// and read and the first-run question is not due (`catalogMayStart`), no catalog reset was asked for in this run, on
    /// the iPhone the network is neither expensive nor constrained (A46), and the app is not in the background (A64, Task
    /// 1B: always true on the Mac).
    var backfillMayRun: Bool {
        canSync && catalogMayStart && !catalogResetRequested && backfillNetworkAllowed && sceneIsActive
    }

    /// The line under the chart (A33): what it says, and whether it offers the button. Nil: no line.
    var backfillLine: (text: String, button: Bool)? {
        if let progress = backfillProgress {
            return (MissingDays.progressText(done: progress.done, total: progress.total), false)
        }
        guard canSync, !catalogResetRequested else { return nil }
        // Feedback 1: after the yes a stop for the run (a request that threw, three not-found answers) is said here,
        // with every day a later launch can still bring; before, the line went away and the gap was not said.
        if backfillOptedIn, backfillStopped, pendingDayCount > 0 {
            return (MissingDays.stoppedText(missing: pendingDayCount), false)
        }
        guard !missingDays.isEmpty else { return nil }
        // The button only while the download can run in this run (review round 1, finding 5).
        if !backfillOptedIn { return (MissingDays.lineText(missing: missingDays.count), backfillCanRunNow) }
        if !backfillNetworkAllowed { return (MissingDays.waitsForWiFi, false) }
        return nil
    }

    /// The Catalog menu's "Download Price History…" and the line's button: off while nothing is missing, while the queue
    /// runs, and while the download cannot run in this run (offline, a store in memory, a gate closed, a reset asked for,
    /// a request that threw: review round 1, finding 5). The dialog never opens to do nothing.
    var canAskBackfill: Bool {
        !missingDays.isEmpty && backfillCanRunNow && backfillProgress == nil && backfillTask == nil
    }

    /// The gates are open and no request that threw stopped the download for this run.
    private var backfillCanRunNow: Bool { backfillMayRun && !backfillStopped }

    /// The status line: a notice, else the sync's own line while it runs, else the download's progress, else the status.
    /// A failure (`.failed`) is never hidden behind the progress (final fix wave, item 5).
    var statusLineText: String {
        if let statusNotice { return statusNotice }
        if case .idle = status, let progress = backfillProgress {
            return MissingDays.statusText(done: progress.done, total: progress.total)
        }
        return status.text
    }

    // MARK: The yes

    /// The record of the days downloaded with a 200, ever (A47; `PriceDaysRecord`).
    nonisolated static let priceDaysDownloadedKey = ArchiveDownloads.recordKey
    /// K9's reason, for the queue, the migration and the price step.
    nonisolated static let activityReason = "Reading price history"

    /// The line's button and the Catalog menu's item: opens the dialog with the count of this moment (finding 6).
    func askBackfill() {
        guard canAskBackfill else { return }
        backfillAskCount = missingDays.count
        asksBackfill = true
    }

    /// The dialog's title and message, from the count taken when it opened; nil before.
    var backfillDialog: (title: String, message: String)? {
        backfillAskCount.map { MissingDays.confirmation(missing: $0) }
    }

    /// The dialog's "Download": remembers the yes in the preferences (A48) and starts the queue when its gates are open.
    /// With nothing missing by then it does nothing (finding 6).
    func startBackfill() {
        guard !missingDays.isEmpty else { return }
        if !backfillOptedIn {
            defaults.set(true, forKey: Self.priceDaysDownloadKey)
            backfillOptedIn = true
        }
        runBackfill()
    }

    /// Stops the queue for the run (a catalog reset; a quit in the tests): the request in flight is cancelled, nothing more
    /// is asked in this run.
    func stopBackfill() {
        backfillStopped = true
        backfillTask?.cancel()
    }

    /// The launch's price step, its migration and its first history pass request are done: the missing days are listed,
    /// and the queue starts when the user said yes.
    func backfillLaunchStepEnded() async {
        guard !backfillLaunchReady else { return }
        backfillLaunchReady = true
        await refreshMissingDays()
        runBackfill()
    }

    /// K7: lists the day files and the archives on disk (off the main actor, without the gate: a day file gets its name
    /// only once verified), takes the gate's failed days and the lane's 404s (this run's and the kept ones).
    func refreshMissingDays() async {
        let version = priceDaysVersion
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: now()))
        let paths = paths
        let (dayFiles, archives) = await Self.listDays(paths: paths)
        let lane = priceSync.downloads
        let failed = await archiveGate.failedDays.union(lane.failed)
        let notFound = await lane.notFound, downloaded = await lane.downloaded
        // A request that threw (the price step's too) stops the download for the run (finding 1).
        if await lane.backgroundStopped { backfillStopped = true }
        let days = MissingDays.days(window: window, dayFiles: dayFiles, archives: archives, failed: failed,
                                    notFound: notFound, downloaded: downloaded, now: now())
        let pending = MissingDays.pending(window: window, dayFiles: dayFiles, archives: archives, notFound: notFound,
                                          downloaded: downloaded, now: now()).count
        missingDaysVersion = version
        if days != missingDays { missingDays = days }
        if pending != pendingDayCount { pendingDayCount = pending }
    }

    @concurrent private nonisolated static func listDays(paths: AppPaths) async -> (Set<String>, Set<String>) {
        (PriceDayFile.days(in: paths.priceDays), ArchiveGate.archiveDays(in: paths.archives))
    }

    // MARK: The queue

    /// Starts the queue when it does not run, the user said yes, the launch is ready, no network error stopped it in this
    /// run and its gates are open.
    func runBackfill() {
        guard backfillTask == nil, backfillOptedIn, backfillLaunchReady, !backfillStopped, backfillMayRun else { return }
        backfillTask = Task { [weak self] in
            let completed = await self?.backfillQueue() ?? true
            guard let self else { return }
            self.backfillTask = nil
            // Finding 4: a run cut short by a gate that has opened again since (the watcher saw it while this task still
            // ran) runs again, once per such cut; a finished run, a reset or a stop for the run does not.
            if !completed { self.runBackfill() }
        }
    }

    /// Starts the queue whenever its gates open (the folder read again, the iPhone back on Wi-Fi), for as long as the
    /// model lives; on the iPhone it also watches the network path.
    func watchBackfillGates() {
        guard !backfillWatching else { return }
        backfillWatching = true
        let changes = Observations { [weak self] in self?.backfillMayRun ?? false }
        Task { [weak self] in
            for await may in changes {
                guard let self else { return }
                if may {
                    self.runBackfill()
                } else if !self.backfillNetworkAllowed || !self.sceneIsActive {
                    // Off Wi-Fi or in the background (iOS): the day in flight is cancelled (no failure); back on Wi-Fi or
                    // in the foreground the queue runs again.
                    self.backfillTask?.cancel()
                }
            }
        }
        #if os(iOS)
        watchBackfillNetwork()
        #endif
    }

    #if os(iOS)
    /// A46: the iPhone downloads the missing days only on a path that is neither expensive nor constrained; a path that
    /// becomes one stops the queue (the day in flight is cancelled), and Wi-Fi starts it again.
    private func watchBackfillNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = MissingDays.allowsBackfill(expensive: path.isExpensive, constrained: path.isConstrained)
            Task { @MainActor [weak self] in
                guard let self, self.backfillNetworkAllowed != allowed else { return }
                self.backfillNetworkAllowed = allowed
            }
        }
        monitor.start(queue: DispatchQueue(label: "backfill-network"))
        backfillPathMonitor = monitor
    }
    #endif

    /// One run of the queue: every missing day of this moment, newest first, one at a time. Holds the activity (K9) while it
    /// works. A history pass is asked for every 10 days and at the end (not per day: each pass plans the whole window). A
    /// 404 marks the day not found for the run (kept across runs below a held day), and 3 of them stop the queue for the
    /// run (`.stopped`: a wrong clock); a decode that fails is the gate's failed day (its archive is kept and
    /// decoded at the next launch, never downloaded again); a network error stops the queue for the run and is said once
    /// (every day done is kept; the next launch goes on). A cancel (a reset; going off Wi-Fi on the iPhone) stops it
    /// without a word; so does the app going to the background on the iPhone (A64, Task 1B).
    /// Returns false when the run was cut short (a cancel or a closed gate) before its plan was done.
    private func backfillQueue() async -> Bool {
        let end = backfillActivity(Self.activityReason)
        defer { end() }
        await refreshMissingDays()
        let plan = missingDays
        guard !Task.isCancelled else { return false }
        guard !plan.isEmpty, !backfillStopped else { return true }
        var completed = true
        backfillProgress = BackfillProgress(done: 0, total: plan.count)
        defer { backfillProgress = nil }
        let lane = priceSync.downloads, gate = archiveGate
        var sincePass = 0
        for day in plan {
            guard !Task.isCancelled, backfillMayRun else {
                completed = false
                break
            }
            // The window moved since the plan (the wanted day changes at 20:30 UTC): a day that left it is not fetched.
            guard PriceDay.window(endingOn: PriceDay.wanted(now: now())).contains(day) else {
                backfillProgress?.done += 1
                continue
            }
            do {
                switch try await lane.download(day: day, background: true) {
                case .downloaded, .onDisk:
                    // A cancel after the download: the archive stays and the next launch decodes it (K11), no download.
                    guard !Task.isCancelled else { break }
                    if let decoded = try? await gate.decodeDay(day: day, games: Games.all) {
                        takeNewerTables(decoded.tables.filter { isSynced($0.key) })
                    }
                    await notePriceDays()
                case .notFound, .downloadedBefore, .failedBefore:
                    break
                case .stopped:
                    // The price step's request threw meanwhile: stopped for the run (said by the price step).
                    backfillStopped = true
                }
            } catch {
                if Task.isCancelled {
                    completed = false
                    break
                }
                backfillStopped = true
                say(MissingDays.failureText(day: day))
                break
            }
            if backfillStopped { break }
            if Task.isCancelled {
                completed = false
                break
            }
            backfillProgress?.done += 1
            sincePass += 1
            if sincePass >= 10 {
                sincePass = 0
                requestHistory()
            }
        }
        requestHistory()
        await refreshMissingDays()
        return completed
    }

    #if DEBUG
    /// Test only: returns when the queue's task (and any that started after it) has ended.
    func waitForBackfill() async {
        while let task = backfillTask {
            await task.value
            if backfillTask == task { backfillTask = nil }
        }
    }
    #endif

    /// K9's default: `ProcessInfo`'s activity, ended by the closure it returns.
    static func processActivity(_ reason: String) -> (@MainActor () -> Void) {
        let token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
        return { ProcessInfo.processInfo.endActivity(token) }
    }
}
