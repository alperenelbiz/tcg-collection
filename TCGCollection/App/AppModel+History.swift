import Foundation

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
/// actor (one batched `reader.printings` call per game), reads the archives on disk off the main actor
/// (`HistoryPass.run`), and writes a game's file only when the pass added a day or a product (H9). Its result is kept only
/// for a game that is still followed and readable, in the folder the pass started with.
extension AppModel {
    // MARK: Questions

    /// The game's price history in memory; nil while `historyState` would say `.unknown`, and before its file is read.
    func history(game: String) -> PriceHistory? {
        historyShows(game) ? histories[game] : nil
    }

    /// What the card page's block can say about one printing (A41, H3). `.unknown` before the folder is read, with no or a
    /// missing folder, while the first-run question is due, and for a game that is not followed or whose game file is
    /// refused. "Tracked now" is the last prepared pass's set, or a collection row, for-sale entry or Wanted pin of the
    /// printing with a count of 1 or more, or (with `cardKey`, the printing's card) the card on Wanted or in a deck in
    /// play: so a click on `+` or "Add to deck" shows `.reading` at once, before the quiet time ends.
    func historyState(game: String, productID: Int, cardKey: String? = nil) -> HistoryState {
        guard historyShows(game) else { return .unknown }
        if let blocked = historyBlocked[game] { return blocked }
        if histories[game]?.has(productID: productID) == true { return .ready }
        if historyTracked[game]?.contains(productID) == true
            || library.rows(game: game).contains(where: { $0.productID == productID && $0.count >= 1 })
            || library.forSale(game: game).contains(where: { $0.productID == productID && $0.count >= 1 })
            || library.wanted(game: game).contains(where: { $0.pin?.productID == productID }) {
            return .reading
        }
        if let cardKey, library.wanted(game: game).contains(where: { $0.cardKey == cardKey })
            || decksInPlay(game: game).contains(where: { deck in deck.cards.contains { $0.cardKey == cardKey } }) {
            return .reading
        }
        return .notTracked
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
    /// the game's gates only makes memory forget its read (no IO), so the next pass that may read it does; one that fails
    /// the folder's gates does nothing (a folder read again is read again whole).
    func historyFileChanged(_ game: String) {
        guard historyFolderOpen, let folder = library.folder, historyFolder == folder, historyOnDisk[game] != nil else {
            return
        }
        guard isSynced(game), library.canChange(game: game) else {
            historyOnDisk[game] = nil
            return
        }
        historyStale.insert(game)
        runHistoryQueue()
    }

    /// Whether a read of the game's file says what memory holds of it.
    private func historyMatches(_ read: HistoryFiles.Read, game: String) -> Bool {
        switch read {
        case .none: historyOnDisk[game] == HistoryOnDisk.none
        case .history(let history): historyOnDisk[game] == .file && !historyUnwritten.contains(game) && histories[game] == history
        case .malformed: historyOnDisk[game] == .malformed
        case .newerVersion: historyBlocked[game] == .newerVersion
        case .notDownloaded: historyBlocked[game] == .notDownloaded
        }
    }

    /// H11: before a folder switch. A running pass stops and keeps nothing; memory of the old folder goes.
    func historyFolderWillChange() {
        cancelHistoryPass()
        historyQuietTask?.cancel()
        historyQuietTask = nil
        dropHistory()
    }

    /// Stops the running pass (it keeps nothing) and drops a queued one.
    func cancelHistoryPass() {
        historyQueued = false
        historyTask?.cancel()
    }

    private func dropHistory() {
        let games = Set(histories.keys).union(historyBlocked.keys).union(historyTracked.keys)
        histories = [:]
        historyBlocked = [:]
        historyTracked = [:]
        historyOnDisk = [:]
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
            #if DEBUG
            historyFileReads += 1
            #endif
            let read = await Self.readHistoryFile(game: game, folder: folder)
            guard !Task.isCancelled, historyStillOn(folder) else { return }
            // Reported again during the read: the next check reads it once more.
            guard !historyStale.contains(game) else { continue }
            guard let read else {
                // An IO error: the next pass reads it.
                historyOnDisk[game] = nil
                historyQueued = true
                continue
            }
            if !historyMatches(read, game: game) {
                takeHistoryRead(read, game: game)
                historyQueued = true
            }
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
        for game in syncedGames.map(\.id) where library.canChange(game: game)
            && (historyOnDisk[game] == nil || historyStale.contains(game)) {
            historyStale.remove(game)
            #if DEBUG
            historyFileReads += 1
            #endif
            let read = await Self.readHistoryFile(game: game, folder: folder)
            guard !Task.isCancelled, historyStillOn(folder) else { return }
            if let read { takeHistoryRead(read, game: game) }
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

        // 3. The archives on disk, off the main actor.
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: now()))
        let result = await HistoryPass.run(games: games, archives: paths.archives, window: window,
                                           failedDays: historyFailedDays, read: historyArchiveReader)
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
            let outcome = await Self.writeHistoryFile(new, game: id, folder: folder, creating: creating)
            #if DEBUG
            await historyWriteHook?(id)
            #endif
            guard historyStillOn(folder) else { return }
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
    private func takeHistoryRead(_ read: HistoryFiles.Read, game: String) {
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
    }

    // MARK: File work, off the main actor

    /// The game's history file; nil for an IO error (the game is then left out of this pass).
    @concurrent nonisolated static func readHistoryFile(game: String, folder: URL) async -> HistoryFiles.Read? {
        try? HistoryFiles.read(game: game, in: folder)
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
