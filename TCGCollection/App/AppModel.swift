import Foundation

/// The sync state the sidebar shows at its bottom.
nonisolated enum Status: Equatable, Sendable {
    case idle(String), syncing(String), failed(String)

    var text: String {
        switch self {
        case .idle(let text), .syncing(let text), .failed(let text): text
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { true } else { false }
    }
}

nonisolated enum StatusText {
    static let checking = "Checking the catalog…"
    /// The store file could not be opened; it was moved aside and the sync fills a fresh one.
    static let storeRecovered = "The catalog could not be read and is downloaded again."
    /// The person asked for a reset in the last run; the store was set aside and the sync fills a fresh one.
    static let storeReset = "The catalog was reset and is downloaded again."
    /// The store was set aside in this launch on a UTC day when its sets were already fetched: the fresh store waits for
    /// the next UTC day (tcgcsv: never the same set twice in one day). Also the empty screen's text then.
    static let resetWaits = "The catalog is downloaded again tomorrow: its sets were already fetched today."
    /// The store file is kept and the app runs on an empty store in memory (P8).
    static let storeFromNewerVersion = "This catalog was written by a newer version of the app. Update the app, or reset the catalog."

    static func storeNotUpdated(_ reason: String) -> String {
        "The catalog could not be updated to this version (\(reason)). Free some disk space and open the app again."
    }

    static func notEnoughSpace(megabytes: Int) -> String {
        "Not enough free disk space to update the catalog (needs about \(megabytes) MB). Free some space and open the app again."
    }

    static func storeCannotOpen(_ reason: String) -> String {
        "Catalog: the store cannot be opened (\(reason))"
    }
    static let prices = "Updating prices…"
    static let ygoIndex = "Updating Yu-Gi-Oh! pictures…"

    static func catalog(_ progress: SyncProgress, gameName: String) -> String {
        let line = "\(gameName): \(progress.done) / \(progress.total) sets"
        return progress.failed > 0 ? line + " · \(progress.failed) failed" : line
    }

    /// `rulesPending`: sets that wait for the next UTC day to be fetched again after a rule change (they were fetched
    /// today). Shown only when the catalog is otherwise up to date.
    static func done(result: SyncResult, priceDay: String?, rulesPending: Int = 0) -> String {
        var problems: [String] = []
        switch result.failedSetLists {
        case 0: break
        case 1: problems.append("the set list of 1 game could not be loaded")
        default: problems.append("the set list of \(result.failedSetLists) games could not be loaded")
        }
        switch result.failed {
        case 0: break
        case 1: problems.append("1 set failed, it is tried again next time")
        default: problems.append("\(result.failed) sets failed, they are tried again next time")
        }
        var catalog = problems.isEmpty ? "Catalog up to date" : "Catalog: " + problems.joined(separator: "; ")
        if problems.isEmpty, rulesPending > 0 { catalog = Self.rulesPending(rulesPending) }
        return catalog + " · " + priceLine(priceDay)
    }

    static func rulesPending(_ count: Int) -> String {
        "Catalog up to date · \(count) \(count == 1 ? "set is" : "sets are") updated tomorrow"
    }

    static func offline(priceDay: String?) -> String {
        "Offline · " + priceLine(priceDay)
    }

    /// The end of the price step, while the other games still download.
    static func pricesLoaded(day: String?) -> String {
        day.map { "Loaded prices of \($0)" } ?? "No prices yet"
    }

    private static func priceLine(_ day: String?) -> String {
        day.map { "prices of \($0)" } ?? "no prices yet"
    }
}

/// The selected game, the stores and the sync that fills them.
@Observable
final class AppModel {
    let options: LaunchOptions
    let paths: AppPaths
    /// The sync writes through this store.
    let store: CatalogStore
    /// The views read through this store: a second actor on the same container, so a running download
    /// does not hold up a search or a card page.
    let reader: CatalogStore
    let prices = PriceTable()
    let pictures: PictureStore
    var ygoIndex: YGOPictureIndex?
    /// The game on screen, kept in `UserDefaults` (key `game`). `-game` wins at launch.
    var gameID: String {
        didSet { defaults.set(gameID, forKey: Self.gameKey) }
    }
    var game: GameDefinition { Games.game(gameID) ?? Games.all[0] }
    private(set) var status: Status = .idle("") {
        didSet {
            #if DEBUG
            // One line per change, so a background run can be followed in a log file.
            if status != oldValue { FileHandle.standardOutput.write(Data("status \(status)\n".utf8)) }
            #endif
        }
    }
    /// Goes up when a sync changed the store (also every 20 sets of the game on screen), so views search again.
    private(set) var catalogVersion = 0
    /// Goes up when a catalog step that changed the store has ended, so the filter menus read their values again.
    /// It does not follow the periodic steps of `catalogVersion`: those values come from every product of a game.
    private(set) var filtersVersion = 0

    /// The Rarity and Type menu values per game: read from `facets-<game>.json` at launch, rewritten after a catalog
    /// step that changed the game. A game with no entry shows empty menus.
    @ObservationIgnored private var facetLists: [String: FacetLists] = [:]

    /// Set by `-card`: the card page the window opens once. `RootView` takes it and clears it.
    var pendingCard: CardTarget?

    private static let gameKey = "game"
    /// Set by "Reset the catalog…" (`requestCatalogReset`); the next launch sets the store aside and clears it.
    private nonisolated static let resetKey = "resetCatalogOnNextLaunch"
    /// The UTC day (`yyyy-MM-dd`) of the last catalog step that fetched at least one set. It outlives the store, so a
    /// store set aside on that day does not lead to a second fetch of the same sets.
    private nonisolated static let lastFetchDayKey = "lastCatalogFetchDay"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogSync: CatalogSync
    @ObservationIgnored private let priceSync: PriceSync
    @ObservationIgnored private let ygoLoader: YGOIndexLoader
    @ObservationIgnored private let now: () -> Date
    /// The status line when no catalog store file is open: the app then runs on an empty store in memory and downloads
    /// nothing. Nil when a store file is open.
    @ObservationIgnored let storeFailure: String?
    /// The person asked for a reset in this run (in the store-failure state); the next launch does it.
    private(set) var catalogResetRequested = false
    /// When this launch set the store aside (reset, or unreadable): `lastCatalogFetchDay` as it was then. Nil otherwise.
    @ObservationIgnored private let setAsideFetchDay: String?
    /// The status of the first catalog check. After a store was moved aside it says so, until the first set is in.
    @ObservationIgnored private var checkingText = StatusText.checking
    @ObservationIgnored private var isRunning = false
    /// The launch steps and the first sync, made by the first `start()`. The model owns it, not a window: a window
    /// that closes cancels its own `.task`, not this one.
    @ObservationIgnored private var launchTask: Task<Void, Never>?

    init(options: LaunchOptions, catalogClient: any TCGCSVFetching, archiveClient: any ArchiveFetching,
         fetcher: any DataFetching, now: @escaping () -> Date = { Date() }) {
        self.options = options
        self.now = now
        let paths = AppPaths(root: options.storeRoot)
        self.paths = paths
        // With `-store`, the preferences live in `<root>/support/preferences.plist`, never in the real ones.
        // A suite name is nil only for the app's own id or the global domain.
        let defaults = options.storeRoot == nil
            ? UserDefaults.standard
            : UserDefaults(suiteName: paths.support.appending(path: "preferences").path) ?? .standard
        self.defaults = defaults
        let opened = Self.openStore(paths: paths, now: now(), defaults: defaults)
        store = opened.store
        storeFailure = opened.failure
        // A notice means the store was set aside and a fresh one opened.
        setAsideFetchDay = opened.notice == nil ? nil : defaults.string(forKey: Self.lastFetchDayKey)
        #if DEBUG
        if let migration = store.opening.migration {
            let vacuum = store.opening.vacuum.map { "vacuumed in \(Int($0 / .milliseconds(1))) ms" } ?? "not vacuumed"
            FileHandle.standardOutput.write(Data("catalog store migrated in \(Int(migration / .milliseconds(1))) ms, \(vacuum)\n".utf8))
        }
        #endif
        reader = CatalogStore(modelContainer: store.modelContainer)
        pictures = PictureStore(directory: paths.pictures, fetcher: options.offline ? NoNetwork() : fetcher)
        ygoLoader = YGOIndexLoader(paths: paths, fetcher: fetcher)
        priceSync = PriceSync(paths: paths, client: archiveClient)
        catalogSync = CatalogSync(store: store, client: catalogClient)
        let saved = defaults.string(forKey: Self.gameKey)
        for game in Games.all {
            if let lists = FacetLists.read(paths.facets(game.id)) { facetLists[game.id] = lists }
        }
        gameID = [options.game, saved].compactMap { $0 }.first { Games.game($0) != nil } ?? Games.all[0].id
        if let notice = opened.notice {
            status = .idle(notice)
            checkingText = notice
        }
    }

    /// The filter menu values of a game. Nil until a file exists or a sync wrote one. Views read it again when
    /// `filtersVersion` changes.
    func facets(game: String) -> FacetLists? { facetLists[game] }

    /// "Reset the catalog…" in the store-failure state: the next launch sets the store file aside and downloads the
    /// catalog again. Nothing happens to the file in this run.
    func requestCatalogReset() {
        defaults.set(true, forKey: Self.resetKey)
        catalogResetRequested = true
    }

    /// Opens the catalog store (P8). A file that is corrupt or not a database is moved aside into `unreadable-<date>`
    /// and a fresh store is made at the normal path; so is any file after "Reset the catalog…" in the last run. Any
    /// other open error keeps the file. When no store file is open in the end, the store lives in memory and `failure`
    /// is the status line that says why. `notice` is the status line after a store was set aside.
    private nonisolated static func openStore(paths: AppPaths, now: Date, defaults: UserDefaults)
        -> (store: CatalogStore, notice: String?, failure: String?) {
        if defaults.bool(forKey: resetKey) {
            defaults.removeObject(forKey: resetKey)
            do {
                try moveAside(paths.catalogStore, into: paths.unreadable(at: now))
                return (try CatalogStore(url: paths.catalogStore), StatusText.storeReset, nil)
            } catch {
                // Not moved, or no fresh store: the open below judges what is at the path, as on any launch.
            }
        }
        let failure: String
        do {
            return (try CatalogStore(url: paths.catalogStore), nil, nil)
        } catch {
            switch CatalogStore.classify(error) {
            case .other(let text):
                failure = text
            case .unreadable:
                do {
                    try moveAside(paths.catalogStore, into: paths.unreadable(at: now))
                    return (try CatalogStore(url: paths.catalogStore), StatusText.storeRecovered, nil)
                } catch {
                    failure = StatusText.storeCannotOpen(CatalogStore.reason(error))
                }
            }
        }
        do {
            return (try CatalogStore.inMemory(), nil, failure)
        } catch {
            // An in-memory store needs no disk: only a broken schema fails here, and the store above failed first.
            fatalError("The catalog schema cannot be loaded: \(error)")
        }
    }

    /// Moves a SwiftData store file and its `-wal` and `-shm` files (those that exist) into `folder`.
    private nonisolated static func moveAside(_ file: URL, into folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let part = URL(fileURLWithPath: file.path + suffix)
            guard fm.fileExists(atPath: part.path) else { continue }
            try fm.moveItem(at: part, to: folder.appending(path: part.lastPathComponent))
        }
    }

    /// Loads prices and the Yu-Gi-Oh! index from disk, then syncs (not with `-offline YES`). Once per app run:
    /// every window calls it, and a later call waits for the same work.
    func start() async {
        if launchTask == nil { launchTask = Task { await launch() } }
        await launchTask?.value
    }

    private func launch() async {
        prices.load(paths: paths)
        ygoIndex = await ygoLoader.current()
        await openLaunchCard()
        await writeMissingFacetLists()
        if let storeFailure {
            status = .failed(storeFailure)
            return
        }
        if options.offline {
            status = .idle(StatusText.offline(priceDay: prices.day(game: gameID)))
            return
        }
        if catalogWaits {
            status = .idle(StatusText.resetWaits)
            return
        }
        await sync(rebuild: false)
    }

    /// A game with products and no facets file (a store migrated from phase 1 has none) gets its lists computed once,
    /// through the reader store, so the menus do not wait for a sync.
    private func writeMissingFacetLists() async {
        let chosen = gameID
        var wrote = false
        for game in Games.all.sorted(by: { $0.id == chosen && $1.id != chosen }) where facetLists[game.id] == nil {
            guard (try? await reader.progress(game: game.id))?.fetched ?? 0 > 0 else { continue }
            wrote = await storeFacetLists(of: game) || wrote
        }
        if wrote { filtersVersion += 1 }
    }

    /// Reads a game's lists from the store, keeps them in memory and writes the file. False when the store read failed.
    private func storeFacetLists(of game: GameDefinition) async -> Bool {
        guard let lists = try? await reader.facetLists(game: game.id) else { return false }
        facetLists[game.id] = lists
        try? lists.write(to: paths.facets(game.id))
        return true
    }

    /// `-card <productId>`: switches to the product's game and asks the window to open its card page.
    private func openLaunchCard() async {
        guard let id = options.card, let product = try? await reader.product(id),
              let game = Games.game(product.gameID) else { return }
        gameID = game.id
        pendingCard = CardTarget(gameID: game.id, cardKey: CardName.searchKey(product.cardName), startProductID: product.productID)
    }

    /// False offline and with a store that cannot be opened: then nothing is downloaded.
    var canSync: Bool { !options.offline && storeFailure == nil }

    /// True while the store set aside in this launch was the one that fetched the sets today (UTC): the fresh store waits
    /// for the next UTC day. No sync runs then, not from Refresh, Rebuild or Try again either.
    var catalogWaits: Bool { setAsideFetchDay == SyncPlan.utcDay(now()) }

    /// Does nothing when the app cannot sync, or while a sync runs. Held while `catalogWaits`.
    func refresh(rebuild: Bool) async {
        guard canSync else { return }
        if catalogWaits {
            status = .idle(StatusText.resetWaits)
            return
        }
        await sync(rebuild: rebuild)
    }

    /// The game on screen gets its cards and prices first; Magic and Yu-Gi-Oh! take many minutes.
    private func sync(rebuild: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let now = self.now()
        let chosen = game
        let first = await syncCatalog(of: [chosen], now: now, rebuild: rebuild)
        let priceFailure = await syncPrices(now: now)
        let rest = await syncCatalog(of: Games.all.filter { $0.id != chosen.id }, now: now, rebuild: rebuild)
        let result = SyncResult(fetched: first.fetched + rest.fetched, failed: first.failed + rest.failed,
                                failedSetLists: first.failedSetLists + rest.failedSetLists,
                                newSets: first.newSets.merging(rest.newSets, uniquingKeysWith: +))
        let indexFailure = await refreshYGOIndexIfNeeded(newSets: result.newSets["yu-gi-oh", default: 0], now: now)
        let pending = await rulesPendingCount(now: now)
        let done = StatusText.done(result: result, priceDay: prices.day(game: gameID), rulesPending: pending)
        if result.failedSetLists > 0 {
            // The catalog failure first: with no network at first launch it is the one that matters.
            status = .failed([done, priceFailure ?? indexFailure].compactMap { $0 }.joined(separator: " · "))
        } else if let failure = priceFailure ?? indexFailure {
            status = .failed(failure)
        } else {
            status = .idle(done)
        }
    }

    /// Sets of every game that are stored under older rules and were fetched today: they wait for the next UTC day.
    private func rulesPendingCount(now: Date) async -> Int {
        var count = 0
        for game in Games.all {
            guard let versions = try? await reader.rulesVersions(game: game.id),
                  let dates = try? await reader.fetchDates(game: game.id) else { continue }
            count += versions.filter { SyncPlan.isOld($0.value) && dates[$0.key].map { SyncPlan.fetchedToday($0, now: now) } == true }.count
        }
        return count
    }

    private func syncCatalog(of games: [GameDefinition], now: Date, rebuild: Bool) async -> SyncResult {
        status = .syncing(checkingText)
        checkingText = StatusText.checking
        // A stream keeps the progress lines in order and ends before the step's result is used.
        let (updates, sink) = AsyncStream.makeStream(of: SyncProgress.self)
        async let result = Self.run(catalogSync, games: games, now: now, rebuild: rebuild, reportingTo: sink)
        var touched = Set<String>()
        for await progress in updates {
            touched.insert(progress.gameID)
            show(progress)
        }
        let done = await result
        if done.fetched > 0 {
            // A game that reported progress had a set stored or failed; its lists are read again before the menus are told.
            for game in games where touched.contains(game.id) { _ = await storeFacetLists(of: game) }
            catalogVersion += 1
            filtersVersion += 1
            defaults.set(SyncPlan.utcDay(now), forKey: Self.lastFetchDayKey)
        }
        return done
    }

    private nonisolated static func run(_ sync: CatalogSync, games: [GameDefinition], now: Date, rebuild: Bool,
                                        reportingTo sink: AsyncStream<SyncProgress>.Continuation) async -> SyncResult {
        defer { sink.finish() }
        return await sync.run(games: games, now: now, rebuild: rebuild) { sink.yield($0) }
    }

    private func show(_ progress: SyncProgress) {
        status = .syncing(StatusText.catalog(progress, gameName: Games.game(progress.gameID)?.name ?? progress.gameID))
        // The game on screen shows its first cards before a long download ends.
        if progress.gameID == gameID, progress.done % 20 == 0 { catalogVersion += 1 }
    }

    /// Nil when the prices are fine or there was nothing new; else the status text. A failure keeps the old prices.
    /// The outcome shows at once; the final status line repeats a failure.
    private func syncPrices(now: Date) async -> String? {
        status = .syncing(StatusText.prices)
        let days = Games.all.map { prices.day(game: $0.id) }
        let haveDay = days.contains(nil) ? nil : days.compactMap { $0 }.min()
        do {
            if let fresh = try await priceSync.run(games: Games.all, now: now, haveDay: haveDay) {
                for (game, table) in fresh { try prices.replace(game, with: table, paths: paths) }
            }
            status = .syncing(StatusText.pricesLoaded(day: prices.day(game: gameID)))
            return nil
        } catch {
            let failure = "Prices: \(Self.describe(error))"
            status = .failed(failure)
            return failure
        }
    }

    private func refreshYGOIndexIfNeeded(newSets: Int, now: Date) async -> String? {
        let writtenAt = (try? paths.ygoIndex.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard Self.needsYGOIndex(hasIndex: ygoIndex != nil, newSets: newSets, writtenAt: writtenAt, now: now) else { return nil }
        status = .syncing(StatusText.ygoIndex)
        do {
            ygoIndex = try await ygoLoader.refresh()
            return nil
        } catch {
            return "Yu-Gi-Oh! pictures: \(Self.describe(error))"
        }
    }

    /// D9: fetch the index when there is none, or when the sync added a Yu-Gi-Oh! set and the index is not from today (UTC).
    nonisolated static func needsYGOIndex(hasIndex: Bool, newSets: Int, writtenAt: Date?, now: Date) -> Bool {
        guard hasIndex else { return true }
        guard newSets > 0 else { return false }
        guard let writtenAt else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return !calendar.isDate(writtenAt, inSameDayAs: now)
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? PriceArchiveError {
            switch error {
            case .cannotOpen(let message), .readFailed(let message): return message
            }
        }
        if let error = error as? TCGCSVClientError { return "HTTP \(error.status)" }
        return error.localizedDescription
    }
}

/// No network: every request fails. The picture fetcher of an `-offline YES` run (only pictures on disk show), and all
/// three clients of a run whose `-fixtures` cannot be honoured (I3).
nonisolated struct NoNetwork: TCGCSVFetching, ArchiveFetching, DataFetching {
    func groups(category: Int) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }

    func products(category: Int, group: Int) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }

    func download(day: String, to file: URL) async throws -> Bool {
        throw URLError(.notConnectedToInternet)
    }

    func data(from url: URL) async throws -> (Data, Int) {
        throw URLError(.notConnectedToInternet)
    }
}
