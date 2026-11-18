import Foundation

/// Reads one game's history file in a folder (`HistoryFiles.read`, which settles its conflict versions first). Tests count
/// the reads.
typealias HistoryFileReader = @Sendable (String, URL) throws -> HistoryFiles.Read

/// What the last read of a game's history file found (H3): it decides how the next write goes.
nonisolated enum HistoryOnDisk: Equatable, Sendable {
    /// No file and no placeholder: the next write creates it (and never replaces one that appeared since).
    case none
    /// A history file of this version: the next write replaces it.
    case file
    /// Not a history file: the next write replaces it (H3).
    case malformed
    /// A newer version or an iCloud placeholder: never written in this run (`historyBlocked` says which).
    case blocked
}

/// The price history in memory and the pass that keeps it (phase 5A task 4: A41, A42, H6–H11). The stored properties are
/// in `AppModel.swift` (an extension cannot hold them).
///
/// One pass at a time, in a task the model keeps (`historyTask`): a newer request replaces a queued one. A pass reads the
/// history files it has not read (or that changed on disk), computes each passed game's tracked printings on the main
/// actor (one batched `reader.printings` call per game), reads the day files on disk off the main actor
/// (`HistoryPass.run`), and writes a game's file only when the pass added a day or a product (H9). Its result is kept only
/// for a game that is still followed and readable, in the folder the pass started with.
extension AppModel {
    // MARK: Questions

    /// The game's price history in memory; nil while `historyState` would say `.unknown`, and before its file is read.
    func history(game: String) -> PriceHistory? {
        historyShows(game) ? histories[game] : nil
    }

    /// What the card page's block can say about one printing (phase 5B task 4: A45, K6; H3). `.unknown` before the folder
    /// is read, with no or a missing folder, while the first-run question is due, and for a game that is not followed or
    /// whose game file is refused (5A's rules: nothing shows before the folder is read, although the day files are not
    /// folder data). Else `.reading` until the printing's day-file prices are read once for the current window (`points`;
    /// final fix wave, item 1: a read made before a newer day file stays shown while the newer read runs, so a day file
    /// written during the migration or the download never flashes "Reading…"), and while the day files give it no price
    /// and the game's history file is not read yet; the history
    /// file's blocked state (a newer version, an iCloud placeholder) only when the day files give no price; else `.ready`
    /// (the points decide: none, one day, a chart). Every printing has its block, tracked or not.
    func historyState(game: String, productID: Int) -> HistoryState {
        guard historyShows(game) else { return .unknown }
        guard let read = currentDayPrices(game: game, productID: productID) else { return .reading }
        if read.hasPrice { return .ready }
        if let blocked = historyBlocked[game] { return blocked }
        if !historyReadGames.contains(game) { return .reading }
        return .ready
    }

    /// The points of one finish of a printing (the day files merged with the history file, `PriceDayPoints.merged`); nil
    /// while `historyState` would not say `.ready` from the day files' side: before they are read once for the current
    /// window (a read made before a newer day file stays until the newer read lands), and while the state is `.unknown`. A view reads this on the main actor; it never reads a disk.
    func dayPoints(game: String, productID: Int, finish: String) -> [HistoryPoint]? {
        guard historyShows(game), let read = currentDayPrices(game: game, productID: productID) else { return nil }
        return PriceDayPoints.merged(dayFiles: read.prices,
                                     history: history(game: game)?.points(productID: productID, finish: finish),
                                     finish: finish, window: read.window)
    }

    /// Every finish's points of a printing, reading its day-file prices off the main actor first when they are not read
    /// for the current day files and window (one lookup per day file of the window; cached per product until
    /// `priceDaysVersion` or the window changes; the history file's days are merged at each call, so a new history in
    /// memory needs no read). `[:]` while `historyState` says `.unknown`.
    func points(game: String, productID: Int) async -> [String: [HistoryPoint]] {
        await readDayPrices(game: game, productID: productID)
        guard historyShows(game), let read = currentDayPrices(game: game, productID: productID) else { return [:] }
        let history = history(game: game)
        var out: [String: [HistoryPoint]] = [:]
        for finish in PriceDayPoints.finishes(dayFiles: read.prices, history: history, productID: productID) {
            out[finish] = PriceDayPoints.merged(dayFiles: read.prices,
                                                history: history?.points(productID: productID, finish: finish),
                                                finish: finish, window: read.window)
        }
        return out
    }

    /// Reads the printing's day-file prices for the current day files and window, unless they are in `dayPrices` already
    /// or being read (one read per key). The card page's block calls it from its task; the read itself runs off the main
    /// actor, and lists the day files without the archive gate (final fix wave, item 1: a running decode never holds it
    /// up; a day file gets its name only once verified). The last read stays in `dayPrices` until a newer one lands.
    func readDayPrices(game: String, productID: Int) async {
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: now()))
        if let last = currentDayPrices(game: game, productID: productID), last.version == priceDaysVersion,
           last.window == window { return }
        guard let category = Games.game(game)?.categoryID else { return }
        let version = priceDaysVersion
        let key = "\(game)|\(productID)|\(version)|\(window.upperBound)"
        let task: Task<DayPrices, Never>
        if let running = dayPricesReads[key] {
            task = running
        } else {
            let folder = paths.priceDays, open = historyDayReader(folder)
            task = Task {
                let prices = await Self.readDayFiles(in: folder, window: window, categoryID: category,
                                                     productID: productID, open: open)
                return DayPrices(version: version, window: window, prices: prices)
            }
            dayPricesReads[key] = task
        }
        let read = await task.value
        dayPricesReads[key] = nil
        // A read of another window is not kept (the window moved meanwhile), nor one older than the read kept (a later
        // read landed first). A read made before a newer day file is kept until the newer read lands (item 1).
        guard read.window == PriceDay.window(endingOn: PriceDay.wanted(now: now())) else { return }
        let entry = "\(game)|\(productID)"
        if let kept = dayPrices[entry], kept.window == read.window, kept.version > read.version { return }
        guard dayPrices[entry] != read else { return }
        // A small cache: entries of an older key go first; past 256 products it starts again.
        if dayPrices.count >= 256 {
            dayPrices = dayPrices.filter { $0.value.version == read.version && $0.value.window == read.window }
            if dayPrices.count >= 256 { dayPrices = [:] }
        }
        dayPrices[entry] = read
    }

    /// The printing's last day-file prices read for the current window, also when a day file was written since (its
    /// newer read is then due or running: item 1); else nil.
    private func currentDayPrices(game: String, productID: Int) -> DayPrices? {
        guard let read = dayPrices["\(game)|\(productID)"],
              read.window == PriceDay.window(endingOn: PriceDay.wanted(now: now())) else { return nil }
        return read
    }

    /// Lists the day files (without the gate) and reads the printing's prices from them, off the main actor.
    @concurrent private nonisolated static func readDayFiles(in folder: URL, window: ClosedRange<String>, categoryID: Int,
                                                            productID: Int, open: HistoryPass.Reader) async -> DayFilePrices {
        PriceDayPoints.read(days: PriceDayFile.days(in: folder), window: window, categoryID: categoryID,
                            productID: productID, open: open)
    }

    /// The folder is read and there, the first-run question is not due, the game is followed and its game file readable.
    private func historyShows(_ game: String) -> Bool {
        historyFolderOpen && isSynced(game) && library.canChange(game: game)
    }

    /// The gates of every read and write of a history file (Global Constraints): a folder chosen, read and there, and the
    /// first-run question not due.
    private var historyFolderOpen: Bool {
        catalogMayStart && library.isLoaded && !library.folderIsMissing && library.folder != nil
    }

    // MARK: Triggers (H10, H11)

    /// Asks for a pass. One runs at a time; a request while one runs makes one more after it.
    func requestHistory() {
        historyQueued = true
        runHistoryQueue()
    }

    /// The end of a price step: the launch's (and, without a sync, the launch's read of prices from disk) opens the queue
    /// and asks for a pass; a later one asks only when it brought a new day.
    func historyPriceStepEnded(newDay: Bool) {
        let first = !historyLaunchReady
        historyLaunchReady = true
        if first || newDay { requestHistory() }
    }

    /// H10: a pass `historyQuietTime` after the last change of the library (an import or fast clicks make one pass).
    func watchHistoryChanges() {
        let library = library
        let changes = Observations { library.version }
        Task { [weak self] in
            for await version in changes {
                guard let self else { return }
                self.historySeenVersion = version
                self.historyLibraryChanged()
            }
        }
    }

    private func historyLibraryChanged() {
        historyQuietTask?.cancel()
        let quiet = historyQuietTime
        historyQuietTask = Task { [weak self] in
            if quiet > .zero { try? await Task.sleep(for: quiet) }
            guard !Task.isCancelled, let self else { return }
            self.historyQuietTask = nil
            self.requestHistory()
        }
    }

    /// H11: a history file of the folder was reported changed. Nothing is read here: a read settles conflict versions,
    /// which writes. Behind the pass's gates (the folder read and there, the first-run question not due, the folder the
    /// history in memory belongs to, the game followed with a readable game file) the game is marked stale and the queue
    /// reads it, after any running pass (`checkStaleHistoryFiles`, or the next pass's first step). A report that fails
    /// any of those gates (the folder missing for now, the question due, the game not followed or refused) only makes
    /// memory forget its read (no IO), so the first pass that may read it reads it. A report for another folder, or for a
    /// game whose file memory has not read, does nothing (it is read anyway).
    func historyFileChanged(_ game: String) {
        // Every report counts, whatever the gates say: a read or a write running now is not recorded (the rule at
        // `historyOnDisk`).
        historyReports[game, default: 0] += 1
        guard let folder = library.folder, historyFolder == folder, historyOnDisk[game] != nil else { return }
        // A closed gate (the folder missing for now, the first-run question due): no IO, but memory forgets the read, so
        // the first pass after the gate opens reads the file another device wrote instead of overwriting it.
        guard historyFolderOpen, isSynced(game), library.canChange(game: game) else {
            historyOnDisk[game] = nil
            return
        }
        historyStale.insert(game)
        runHistoryQueue()
    }


    /// Phase 6B, ruling G4 (a): every game whose history file was a placeholder at its last read is marked as reported
    /// changed, so the queue reads it again (behind the pass's gates).
    func historyNotDownloadedAgain() {
        for (game, state) in historyBlocked where state == .notDownloaded { historyFileChanged(game) }
    }

    /// H11: before a folder switch. A running pass stops and keeps nothing; memory of the old folder goes.
    func historyFolderWillChange() {
        cancelHistoryPass()
        historyQuietTask?.cancel()
        historyQuietTask = nil
        dropHistory()
    }

    /// Stops the running pass (it keeps nothing) and drops a queued one.
    /// A stale mark means another device wrote the file: it is not lost with the cancel. Its game forgets its read instead
    /// (no IO), so the next pass reads the file first.
    func cancelHistoryPass() {
        historyQueued = false
        for game in historyStale { historyOnDisk[game] = nil }
        historyStale = []
        historyTask?.cancel()
    }

    private func dropHistory() {
        let games = Set(histories.keys).union(historyBlocked.keys).union(historyTracked.keys)
        histories = [:]
        historyBlocked = [:]
        historyTracked = [:]
        historyReadGames = []
        historyOnDisk = [:]
        historyReports = [:]
        historyUnwritten = []
        historyStale = []
        historyFolder = nil
        for game in games { historyChanged(game) }
    }

    #if DEBUG
    /// Test only: returns when the library change the watcher has not seen yet, the quiet wait, the checks of reported
    /// files and every queued or running pass have ended.
    func waitForHistory() async {
        while true {
            if historySeenVersion != nil, historySeenVersion != library.version {
                try? await Task.sleep(for: .milliseconds(5))
            } else if let quiet = historyQuietTask {
                await quiet.value
                if historyQuietTask == quiet { historyQuietTask = nil }
            } else if let task = historyTask {
                await task.value
            } else {
                return
            }
        }
    }
    #endif

    // MARK: The queue

    private func runHistoryQueue() {
        guard historyTask == nil, historyQueued || !historyStale.isEmpty, historyLaunchReady else { return }
        historyTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.historyQueued || !self.historyStale.isEmpty {
                if self.historyQueued {
                    self.historyQueued = false
                    await self.runHistoryPass()
                } else {
                    await self.checkStaleHistoryFiles()
                }
            }
            // A cancel leaves its task here; requests made since then get a new one.
            self?.historyTask = nil
            self?.runHistoryQueue()
        }
    }

    /// H11, in the queue: reads each stale history file again, behind the gates. A read that says what memory holds
    /// changes nothing (our own writes read back equal: no pass); any other read becomes memory and asks for a pass. A
    /// game that fails its gates now forgets its read (the next pass that may read it does); a closed folder gate clears
    /// every mark the same way, so the queue always ends.
    private func checkStaleHistoryFiles() async {
        guard historyFolderOpen, let folder = library.folder, historyFolder == folder else {
            for game in historyStale { historyOnDisk[game] = nil }
            historyStale = []
            return
        }
        for game in historyStale.sorted() {
            historyStale.remove(game)
            guard isSynced(game), library.canChange(game: game) else {
                historyOnDisk[game] = nil
                continue
            }
            switch await readUnderRule(game: game, folder: folder) {
            case .taken(let changed):
                // A read that says what memory holds (our own write's echo) asks for nothing more.
                if changed { historyQueued = true }
            case .failed:
                // An IO error: the next pass reads it (no stale mark, so a lasting error does not loop).
                historyQueued = true
            case .forgotten:
                break
            }
            if Task.isCancelled { return }
        }
    }

    // MARK: The pass

    /// One pass (H6–H9). Nothing before the gates are open; the files of the followed, readable games are read first
    /// (once per folder, again after a change on disk); a game is passed only when its catalog is settled and has
    /// products (H7) and its file may be written.
    private func runHistoryPass() async {
        guard historyFolderOpen, let folder = library.folder else { return }
        if historyFolder != folder {
            dropHistory()
            historyFolder = folder
        }
        #if DEBUG
        historyPassCount += 1
        #endif

        // 1. The files not read yet, or changed on disk.
        for game in syncedGames.map(\.id) where historyOnDisk[game] == nil || historyStale.contains(game) {
            // Checked again before each read: an earlier read may have let a game go unfollowed, or the folder go.
            guard historyStillOn(folder) else { return }
            guard isSynced(game), library.canChange(game: game) else { continue }
            historyStale.remove(game)
            _ = await readUnderRule(game: game, folder: folder)
            if Task.isCancelled { return }
        }

        // 2. The games to pass, each with its tracked printings.
        var games: [HistoryPass.Game] = []
        var versions: [String: Int] = [:]
        for definition in syncedGames {
            let game = definition.id
            guard historyMayPass(game), (try? await reader.hasProducts(game: game)) == true,
                  !Task.isCancelled, historyStillOn(folder), historyMayPass(game) else { continue }
            let rows = library.rows(game: game), forSale = library.forSale(game: game), wanted = library.wanted(game: game)
            let keys = TrackedPrintings.cardKeys(wanted: wanted, decks: decksInPlay(game: game))
            let printings: [String: [ProductRecord]]
            if keys.isEmpty {
                printings = [:]
            } else {
                // A failed read leaves the game out: a write without all its printings would drop some (H7).
                guard let read = try? await reader.printings(game: game, cardKeys: Array(keys)) else { continue }
                printings = read
            }
            guard !Task.isCancelled, historyStillOn(folder), historyMayPass(game) else { continue }
            let tracked = TrackedPrintings.productIDs(collection: rows, forSale: forSale, wanted: wanted,
                                                      printingsByCard: printings.mapValues { $0.map(\.productID) },
                                                      cardKeys: keys)
            if historyTracked[game] != tracked { historyTracked[game] = tracked }
            versions[game] = historyVersions[game, default: 0]
            games.append(HistoryPass.Game(id: game, categoryID: definition.categoryID, history: histories[game],
                                          tracked: tracked))
        }
        guard !games.isEmpty, !Task.isCancelled else { return }
        #if DEBUG
        await historyPassHook?(games.map(\.id))
        #endif

        // 3. The day files on disk (phase 5B task 3, K5), off the main actor. The launch's migration and the price step
        // turn every archive into its day file through the gate before they ask for a pass; a pass reads no archive.
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: now()))
        let days = await archiveGate.dayFiles()
        guard !Task.isCancelled, historyStillOn(folder) else { return }
        let result = await HistoryPass.run(games: games, days: days, window: window, failedDays: historyFailedDays,
                                           read: historyDayReader(paths.priceDays))
        // A cancelled pass keeps nothing (a folder switch, a reset).
        guard !Task.isCancelled, historyStillOn(folder) else { return }
        historyFailedDays = result.failedDays

        // 4. Memory and the files: only for a game still followed and readable, whose memory and file did not change
        // meanwhile (a reported change is read again by the next pass).
        for game in games {
            // A cancel during an earlier game's write: nothing more is set or written.
            guard !Task.isCancelled, historyStillOn(folder) else { return }
            let id = game.id
            guard let new = result.histories[id], isSynced(id), historyMayPass(id),
                  historyVersions[id, default: 0] == versions[id] else { continue }
            // Another device wrote the file during the pass (H11): its result is dropped; the queue reads the file and
            // asks for a pass that adds what it lacks.
            guard !historyStale.contains(id) else {
                historyQueued = true
                continue
            }
            let writes = historyUnwritten.contains(id) || HistoryPlan.writes(old: game.history, new: new)
            if new != game.history {
                histories[id] = new
                historyChanged(id)
            }
            guard writes else { continue }
            let creating = historyOnDisk[id] == HistoryOnDisk.none
            // On the main actor, with no suspension since the stale check above: the last moment before the write.
            let reports = historyReports[id, default: 0]
            let outcome = await Self.writeHistoryFile(new, game: id, folder: folder, creating: creating)
            #if DEBUG
            await historyWriteHook?(id)
            #endif
            // The rule: a write is recorded only when no report came during it (another device may have written after
            // it, or its own echo: one more read, which finds the file equal to memory).
            guard historyStillOn(folder), historyReports[id, default: 0] == reports else {
                forgetHistoryRead(id, folder: folder)
                if Task.isCancelled || !historyStillOn(folder) { return }
                continue
            }
            switch outcome {
            case .written:
                historyOnDisk[id] = .file
                historyUnwritten.remove(id)
            case .appeared:
                // The create rule: a file arrived after the read. It is read (and taken as memory) by the next pass, which
                // adds what it lacks.
                historyStale.insert(id)
                historyQueued = true
            case .refused(let state):
                historyOnDisk[id] = .blocked
                historyBlocked[id] = state
                histories[id] = nil
                historyChanged(id)
            case .failed:
                historyUnwritten.insert(id)
            }
            // The write is recorded as it happened; a cancel during it stops the pass here.
            if Task.isCancelled { return }
        }
    }

    /// The game may be passed now (H7): followed (and not while the first-run question is due), its game file readable,
    /// its history file read and writable, its catalog settled.
    private func historyMayPass(_ game: String) -> Bool {
        isSynced(game) && library.canChange(game: game) && historyOnDisk[game] != nil && historyBlocked[game] == nil
            && catalogSettled(game: game)
    }

    /// The folder the pass started with is still the library's, read and there, and memory belongs to it.
    private func historyStillOn(_ folder: URL) -> Bool {
        historyFolderOpen && library.folder == folder && historyFolder == folder
    }

    /// A read of the game's history file becomes memory (H3): a history replaces it; no file, a malformed one, a newer
    /// one or a placeholder leaves none; the last two block the game's writes for the run (until a read finds otherwise).
    @discardableResult
    private func takeHistoryRead(_ read: HistoryFiles.Read, game: String) -> Bool {
        let history: PriceHistory?
        var blocked: HistoryState?
        switch read {
        case .none:
            historyOnDisk[game] = HistoryOnDisk.none
            history = nil
        case .history(let found):
            historyOnDisk[game] = .file
            history = found
        case .malformed:
            historyOnDisk[game] = .malformed
            history = nil
        case .newerVersion:
            historyOnDisk[game] = .blocked
            history = nil
            blocked = .newerVersion
        case .notDownloaded:
            historyOnDisk[game] = .blocked
            history = nil
            blocked = .notDownloaded
        }
        historyUnwritten.remove(game)
        if !historyReadGames.contains(game) { historyReadGames.insert(game) }
        var changed = false
        if histories[game] != history {
            histories[game] = history
            changed = true
        }
        if historyBlocked[game] != blocked {
            historyBlocked[game] = blocked
            changed = true
        }
        if changed { historyChanged(game) }
        return changed
    }

    private enum RuledRead {
        /// The read became memory; `changed`: memory or the blocked state changed with it.
        case taken(changed: Bool)
        /// An IO error: nothing recorded, the read forgotten.
        case failed
        /// A report came during the read, or it was cancelled, or a gate closed: the read forgotten (and the game
        /// marked stale while the gates hold).
        case forgotten
    }

    /// The rule at `historyOnDisk`, for every read of a history file: the report count is taken before the read; after
    /// it the result is taken only when the task is not cancelled, the folder is the same and open, the game is followed
    /// with a readable game file, and no report came during the read. Else the read is forgotten.
    private func readUnderRule(game: String, folder: URL) async -> RuledRead {
        let reports = historyReports[game, default: 0]
        let read = await readHistoryFile(game: game, folder: folder)
        guard !Task.isCancelled, historyStillOn(folder), isSynced(game), library.canChange(game: game),
              historyReports[game, default: 0] == reports else {
            forgetHistoryRead(game, folder: folder)
            return .forgotten
        }
        guard let read else {
            historyOnDisk[game] = nil
            return .failed
        }
        return .taken(changed: takeHistoryRead(read, game: game))
    }

    /// A read or a write that a report (or a cancel, or a closed gate) followed: memory forgets what it believed is on
    /// disk, so the game is not written before it is read again; while the gates hold it is marked stale, so the queue
    /// reads it again (also after a cancel: the queue's next task does).
    private func forgetHistoryRead(_ game: String, folder: URL) {
        historyOnDisk[game] = nil
        if historyStillOn(folder), isSynced(game), library.canChange(game: game) { historyStale.insert(game) }
    }

    // MARK: File work, off the main actor

    /// The game's history file, through `historyFileReader` (every read of a history file goes through here); nil for an
    /// IO error (the game is then left out of this pass).
    private func readHistoryFile(game: String, folder: URL) async -> HistoryFiles.Read? {
        await Self.readHistoryFile(game: game, folder: folder, reader: historyFileReader)
    }

    @concurrent private nonisolated static func readHistoryFile(game: String, folder: URL,
                                                               reader: HistoryFileReader) async -> HistoryFiles.Read? {
        try? reader(game, folder)
    }

    nonisolated enum HistoryWrite: Sendable {
        case written
        /// A creating write found a file or a placeholder (the create rule): nothing was written.
        case appeared
        /// The file on disk must not be replaced: a newer version or a placeholder.
        case refused(HistoryState)
        /// Any other failure: nothing was written.
        case failed
    }

    @concurrent nonisolated static func writeHistoryFile(_ history: PriceHistory, game: String, folder: URL,
                                                          creating: Bool) async -> HistoryWrite {
        do {
            try HistoryFiles.write(history, game: game, in: folder, creating: creating)
            return .written
        } catch UserFilesError.appeared {
            return .appeared
        } catch UserFilesError.notRewritable(newerVersion: true) {
            return .refused(.newerVersion)
        } catch UserFilesError.notDownloaded {
            return .refused(.notDownloaded)
        } catch {
            return .failed
        }
    }
}
