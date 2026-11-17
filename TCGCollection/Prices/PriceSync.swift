import Foundation

/// The server answered 200, then the archive could not be put in its place (a full disk, a permission): the request was
/// made and answered (review round 2, A). The lane records the day all the same: it is not asked for again, ever (A47).
nonisolated struct ArchiveStoreError: Error {
    let underlying: any Error
}

nonisolated protocol ArchiveFetching: Sendable {
    /// Downloads the archive of `day` to `file`. Returns false when the server has no such archive (404). A failure after
    /// a 200 (the file cannot be moved into place) throws `ArchiveStoreError`.
    func download(day: String, to file: URL) async throws -> Bool
}

nonisolated struct ArchiveClient: ArchiveFetching {
    /// Final fix wave, item 9: an archive request gives up after 60 s without data and after 120 s in all, so a trickling
    /// download cannot hold a catalog step (which waits for the request in flight) for long. A timeout is an ordinary
    /// failed request (`URLError.timedOut`): the lane stops the 90-day download for the run.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    var session: URLSession = ArchiveClient.session

    func download(day: String, to file: URL) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://tcgcsv.com/archive/tcgplayer/prices-\(day).ppmd.7z")!)
        request.setValue("TCGCollection/0.1", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            if status == 404 { return false }
            throw TCGCSVClientError(status: status)
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: file)
            try fm.moveItem(at: temporary, to: file)
        } catch {
            try? fm.removeItem(at: temporary)
            throw ArchiveStoreError(underlying: error)
        }
        return true
    }
}

/// Which day's archive to ask for (decision D8): the archive of day D appears at about 20:05 UTC of D.
nonisolated enum PriceDay {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func format(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Yesterday's (UTC) archive until 20:30 UTC, then today's.
    static func wanted(now: Date) -> String {
        let parts = utc.dateComponents([.hour, .minute], from: now)
        let afterPublish = parts.hour! * 60 + parts.minute! >= 20 * 60 + 30
        return afterPublish ? format(now) : format(now.addingTimeInterval(-86_400))
    }

    static func before(_ day: String) -> String { moved(day, by: -86_400) }

    /// `day` moved back by `days` days (`yyyy-MM-dd`, UTC); `day` itself when it does not read as a day.
    static func before(_ day: String, days: Int) -> String { moved(day, by: -86_400 * Double(days)) }

    /// The day after `day` (`yyyy-MM-dd`, UTC); `day` itself when it does not read as a day.
    static func after(_ day: String) -> String { moved(day, by: 86_400) }

    /// `day` moved by `seconds` from its noon (UTC); `day` itself when it does not read as a day.
    private static func moved(_ day: String, by seconds: TimeInterval) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return day }
        return format(date.addingTimeInterval(seconds))
    }

    /// The price history's window (H5): the 90 UTC days that end on `day`, that day included.
    static func window(endingOn day: String) -> ClosedRange<String> {
        var first = day
        for _ in 1..<90 { first = before(first) }
        return first...day
    }

    /// Every day of `window`, ascending.
    static func days(in window: ClosedRange<String>) -> [String] {
        var result: [String] = []
        var day = window.lowerBound
        while day <= window.upperBound {
            result.append(day)
            let next = after(day)
            if next <= day { break }
            day = next
        }
        return result
    }
}

/// The days this device has downloaded with a 200 or holds, ever (phase 5B review round 1, A47: an archive is never
/// downloaded twice, so a cache day that is lost does not come back). Kept in the app's preferences (with `-store`, the
/// root's own), key `priceDaysDownloaded`, a list of `yyyy-MM-dd`; at the launch's clean-up the days more than 2 years
/// before the window's start are pruned (final fix wave, item 3: not the days before the window, so a clock jump forward
/// never empties it; about 11 bytes a day). A reinstall loses it (stated limit). Beside it, key `priceDaysNotFound`: the
/// days that were a 404 and are older than a day this device holds (item 4), pruned the same way. UserDefaults is
/// thread-safe; it is only touched from `ArchiveDownloads`.
nonisolated struct PriceDaysRecord: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }

    func load() -> Set<String> { Set(defaults.stringArray(forKey: ArchiveDownloads.recordKey) ?? []) }
    func save(_ days: Set<String>) { defaults.set(days.sorted(), forKey: ArchiveDownloads.recordKey) }
    func loadNotFound() -> Set<String> { Set(defaults.stringArray(forKey: ArchiveDownloads.notFoundKey) ?? []) }
    func saveNotFound(_ days: Set<String>) { defaults.set(days.sorted(), forKey: ArchiveDownloads.notFoundKey) }
}

/// Every archive request of the app goes through this one lane (phase 5B task 5, A32): the price step's daily file and
/// the 90-day download alike.
/// - One request at a time: a second caller waits until the first one's request has ended.
/// - Checked again inside the lane, right before the request: a day that has a day file or an archive on disk is never
///   asked for (another path may have made one since the caller looked).
/// - A day downloaded with a 200 is never asked for again, in any run (`PriceDaysRecord`); without a record (tests), in
///   this run.
/// - A day that was a 404, or whose request threw (a network error, an HTTP error, a timeout, a failed move; not a
///   cancel), is not asked for again in this run, by either caller (review round 1, finding 1).
/// - A 404 of a day older than a day this device holds (the record) is kept across runs (`priceDaysNotFound`, final fix
///   wave, item 4): tcgcsv has no archive of it, and it is never asked for again. A 404 of a day with no newer day held
///   (the newest day not published yet, or a clock ahead) is remembered for the run only.
/// - After a request that threw, and after 3 not-found answers to background requests in the run (item 3: a window full
///   of 404s points to a wrong clock), background callers get `.stopped` for the rest of the run: the 90-day download
///   stops; the price step may still try another day once on a later Refresh.
/// - `background` callers (the 90-day download) also wait while the lane is paused (`pause()`: a catalog step runs, so
///   tcgcsv never gets more than its 4 requests at a time); the price step is not a background caller.
/// The client writes the archive's name only once the whole file is there (`ArchiveClient` moves a finished temporary
/// file into place), so a request cut short leaves no archive.
actor ArchiveDownloads {
    nonisolated enum Outcome: Equatable, Sendable {
        /// The archive was downloaded to its place.
        case downloaded
        /// The day has a day file or an archive on disk already: nothing was asked for.
        case onDisk
        /// No archive for that day (a 404, now, earlier in this run, or kept from an earlier run).
        case notFound
        /// The day was downloaded before (this run, or an earlier one: the record) and is gone from disk: not asked again.
        case downloadedBefore
        /// The day's request threw earlier in this run: not asked again.
        case failedBefore
        /// A background caller after a request that threw, or after 3 not-found answers, in this run: nothing is asked for.
        case stopped
    }

    nonisolated static let recordKey = "priceDaysDownloaded"
    /// Final fix wave, item 4: the days that were a 404, kept across runs (`PriceDaysRecord.loadNotFound`).
    nonisolated static let notFoundKey = "priceDaysNotFound"

    private let paths: AppPaths
    private let client: any ArchiveFetching
    private let record: PriceDaysRecord?
    private var inFlight = false
    private var pauses = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Every day downloaded with a 200: this run's and the record's.
    private(set) var downloaded: Set<String>
    /// The days that were a 404 in this run, and the days kept from earlier runs (`keptNotFound`).
    private(set) var notFound: Set<String>
    /// The 404 days kept across runs (item 4): each older than a day held when its 404 came.
    private var keptNotFound: Set<String>
    /// The not-found answers background requests got in this run (item 3: 3 stop the background).
    private var backgroundNotFoundAnswers = 0
    /// Item 3: the background stops after this many not-found answers in a run.
    nonisolated static let notFoundLimit = 3
    /// The days whose request threw in this run.
    private(set) var failed: Set<String> = []
    /// True after a request threw, or after 3 not-found answers to background requests, in this run: background callers
    /// get `.stopped`.
    private(set) var backgroundStopped = false

    init(paths: AppPaths, client: any ArchiveFetching, record: PriceDaysRecord? = nil) {
        self.paths = paths
        self.client = client
        self.record = record
        downloaded = record?.load() ?? []
        keptNotFound = record?.loadNotFound() ?? []
        notFound = keptNotFound
    }

    func download(day: String, background: Bool) async throws -> Outcome {
        while inFlight || (background && pauses > 0) {
            await withCheckedContinuation { waiters.append($0) }
            try Task.checkCancellation()
        }
        let fm = FileManager.default
        let archive = paths.archives.appending(path: ArchiveGate.archiveName(day: day))
        if fm.fileExists(atPath: paths.priceDay(day).path) || fm.fileExists(atPath: archive.path) { return .onDisk }
        if downloaded.contains(day) { return .downloadedBefore }
        if notFound.contains(day) { return .notFound }
        if failed.contains(day) { return .failedBefore }
        if background, backgroundStopped { return .stopped }
        try Task.checkCancellation()
        inFlight = true
        defer {
            inFlight = false
            wakeAll()
        }
        let found: Bool
        do {
            try fm.createDirectory(at: paths.archives, withIntermediateDirectories: true)
            found = try await client.download(day: day, to: archive)
        } catch let error as ArchiveStoreError {
            // A 200 came: the day is recorded before anything else (review round 2, A), and is a gap from now on.
            downloaded.insert(day)
            record?.save(downloaded)
            failed.insert(day)
            backgroundStopped = true
            throw error
        } catch {
            if !Self.isCancel(error) {
                failed.insert(day)
                backgroundStopped = true
            }
            throw error
        }
        if found {
            downloaded.insert(day)
            record?.save(downloaded)
            return .downloaded
        }
        notFound.insert(day)
        // Item 4: kept across runs only below a day held (tcgcsv published a later day, so this one is a real gap).
        if downloaded.contains(where: { $0 > day }) {
            keptNotFound.insert(day)
            record?.saveNotFound(keptNotFound)
        }
        if background {
            backgroundNotFoundAnswers += 1
            if backgroundNotFoundAnswers >= Self.notFoundLimit { backgroundStopped = true }
        }
        return .notFound
    }

    /// Task 6 review, item 1: every day this device holds is recorded, not only the days this lane downloaded: the days
    /// the launch's migration decoded (archives a 5A build downloaded) and every day file of the window at launch (a day
    /// held before the record existed). So a lost day file of such a day is not downloaded again either (A47).
    func recordHeld(_ days: Set<String>) {
        let all = downloaded.union(days)
        guard all != downloaded else { return }
        downloaded = all
        record?.save(all)
    }

    /// K10: the record's days before `day` are dropped, and the kept 404 days before it (once per launch, with the
    /// clean-up; the launch passes the day 2 years before the window's start: final fix wave, item 3).
    func pruneRecord(before day: String) {
        let kept = downloaded.filter { $0 >= day }
        if kept != downloaded {
            downloaded = kept
            record?.save(kept)
        }
        let keptMissing = keptNotFound.filter { $0 >= day }
        if keptMissing != keptNotFound {
            notFound.subtract(keptNotFound.subtracting(keptMissing))
            keptNotFound = keptMissing
            record?.saveNotFound(keptMissing)
        }
    }

    /// Item 3: the day before which the record and the kept 404 days are pruned: 2 years (730 days) before the window's
    /// first day.
    nonisolated static func pruneDay(windowStart: String) -> String { PriceDay.before(windowStart, days: 730) }

    private static func isCancel(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return Task.isCancelled
    }

    /// Background requests wait from now until `resume()`; returns once no request is in flight.
    func pause() async {
        pauses += 1
        while inFlight { await withCheckedContinuation { waiters.append($0) } }
    }

    func resume() {
        pauses = max(0, pauses - 1)
        wakeAll()
    }

    private func wakeAll() {
        let woken = waiters
        waiters = []
        for waiter in woken { waiter.resume() }
    }
}

actor PriceSync {
    private let paths: AppPaths
    /// Every archive is decoded through the gate (phase 5B, K3): once, into the tables and the day file.
    nonisolated let gate: ArchiveGate
    /// Every archive request goes through this lane (one at a time, each day once).
    nonisolated let downloads: ArchiveDownloads

    init(paths: AppPaths, client: any ArchiveFetching, gate: ArchiveGate? = nil, record: PriceDaysRecord? = nil) {
        self.paths = paths
        self.gate = gate ?? ArchiveGate(paths: paths)
        downloads = ArchiveDownloads(paths: paths, client: client, record: record)
    }

    /// Prices of every game in `games` from the wanted day, else the day before. Returns nil when `haveDay` is already
    /// that day or newer, or when neither day can be had.
    ///
    /// A day whose day file exists is never downloaded: its tables come from the day file (phase 5B). An archive already
    /// on disk is never downloaded again. The tables of a downloaded (or found) archive come from the gate's one decode,
    /// which also writes the day file and then deletes the archive. If that decode throws, `run` rethrows and the archive
    /// stays where it is (the gate names the day failed for the run, so it is neither decoded nor downloaded again).
    ///
    /// `download` false (a game turned on, G5): only a day file or an archive already on disk is read; nothing is
    /// downloaded.
    func run(games: [GameDefinition], now: Date, haveDay: String?, download: Bool = true) async throws -> [String: GamePrices]? {
        let wanted = PriceDay.wanted(now: now)
        let fm = FileManager.default
        for day in [wanted, PriceDay.before(wanted)] {
            if let haveDay, haveDay >= day { return nil }
            let file = paths.archives.appending(path: "prices-\(day).ppmd.7z")
            if !fm.fileExists(atPath: paths.priceDay(day).path), !fm.fileExists(atPath: file.path) {
                guard download else { continue }
                switch try await downloads.download(day: day, background: false) {
                case .downloaded, .onDisk: break
                case .notFound, .downloadedBefore, .failedBefore, .stopped: continue
                }
            }
            return try await gate.decode(day: day, games: games)
        }
        return nil
    }

    #if DEBUG
    /// Reads one archive into a `GamePrices` per game id, without a day file (the gate's decode does both). A game with
    /// no rows gets empty rows. Kept for the price table's tests only (DEBUG): the app reads archives through the gate
    /// alone (phase 5B task 3).
    nonisolated static func build(file: URL, games: [GameDefinition], day: String) throws -> [String: GamePrices] {
        var result: [String: GamePrices] = [:]
        var indexes: [String: [String: Int]] = [:]
        var gameOf: [Int: String] = [:]
        for game in games {
            result[game.id] = GamePrices(day: day, finishes: [], rows: [:])
            gameOf[game.categoryID] = game.id
        }
        try PriceArchive.read(file, categories: Set(gameOf.keys)) { category, _, rows in
            guard let id = gameOf[category] else { return }
            for row in rows {
                var finishIndexes = indexes[id, default: [:]]
                let index: Int
                if let known = finishIndexes[row.finish] {
                    index = known
                } else {
                    index = result[id]!.finishes.count
                    result[id]!.finishes.append(row.finish)
                    finishIndexes[row.finish] = index
                    indexes[id] = finishIndexes
                }
                result[id]!.rows[row.productID, default: [:]][index] = row.price
            }
        }
        return result
    }
    #endif
}
