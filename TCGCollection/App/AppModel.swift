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
    static let prices = "Updating prices…"
    static let ygoIndex = "Updating Yu-Gi-Oh! pictures…"

    static func catalog(_ progress: SyncProgress, gameName: String) -> String {
        let line = "\(gameName): \(progress.done) / \(progress.total) sets"
        return progress.failed > 0 ? line + " · \(progress.failed) failed" : line
    }

    static func done(result: SyncResult, priceDay: String?) -> String {
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
        let catalog = problems.isEmpty ? "Catalog up to date" : "Catalog: " + problems.joined(separator: "; ")
        return catalog + " · " + priceLine(priceDay)
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

    /// Set by `-card`: the card page the window opens once. `RootView` takes it and clears it.
    var pendingCard: CardTarget?

    private static let gameKey = "game"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogSync: CatalogSync
    @ObservationIgnored private let priceSync: PriceSync
    @ObservationIgnored private let ygoLoader: YGOIndexLoader
    @ObservationIgnored private let now: () -> Date
    /// Set when the catalog store could not be opened: the app then runs on an empty temporary store and downloads nothing.
    @ObservationIgnored private let storeFailure: String?
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
        do {
            store = try CatalogStore(url: paths.catalogStore)
            storeFailure = nil
        } catch {
            // Phase 1 has no error screen: the status line says it, and nothing is downloaded into the temporary store.
            let temporary = URL.temporaryDirectory.appending(path: "TCGCollection2-\(UUID().uuidString)/catalog.store")
            store = try! CatalogStore(url: temporary)
            storeFailure = "Catalog: the store cannot be opened (\(Self.describe(error)))"
        }
        reader = CatalogStore(modelContainer: store.modelContainer)
        pictures = PictureStore(directory: paths.pictures, fetcher: options.offline ? NoNetwork() : fetcher)
        ygoLoader = YGOIndexLoader(paths: paths, fetcher: fetcher)
        priceSync = PriceSync(paths: paths, client: archiveClient)
        catalogSync = CatalogSync(store: store, client: catalogClient)
        // With `-store`, the preferences live in `<root>/support/preferences.plist`, never in the real ones.
        // A suite name is nil only for the app's own id or the global domain.
        defaults = options.storeRoot == nil
            ? .standard
            : UserDefaults(suiteName: paths.support.appending(path: "preferences").path) ?? .standard
        let saved = defaults.string(forKey: Self.gameKey)
        gameID = [options.game, saved].compactMap { $0 }.first { Games.game($0) != nil } ?? Games.all[0].id
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
        if let storeFailure {
            status = .failed(storeFailure)
            return
        }
        if options.offline {
            status = .idle(StatusText.offline(priceDay: prices.day(game: gameID)))
            return
        }
        await sync(rebuild: false)
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

    /// Does nothing when the app cannot sync, or while a sync runs.
    func refresh(rebuild: Bool) async {
        guard canSync else { return }
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
        let done = StatusText.done(result: result, priceDay: prices.day(game: gameID))
        if result.failedSetLists > 0 {
            // The catalog failure first: with no network at first launch it is the one that matters.
            status = .failed([done, priceFailure ?? indexFailure].compactMap { $0 }.joined(separator: " · "))
        } else if let failure = priceFailure ?? indexFailure {
            status = .failed(failure)
        } else {
            status = .idle(done)
        }
    }

    private func syncCatalog(of games: [GameDefinition], now: Date, rebuild: Bool) async -> SyncResult {
        status = .syncing(StatusText.checking)
        // A stream keeps the progress lines in order and ends before the step's result is used.
        let (updates, sink) = AsyncStream.makeStream(of: SyncProgress.self)
        async let result = Self.run(catalogSync, games: games, now: now, rebuild: rebuild, reportingTo: sink)
        for await progress in updates { show(progress) }
        let done = await result
        if done.fetched > 0 {
            catalogVersion += 1
            filtersVersion += 1
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

/// The picture fetcher of an `-offline YES` run: every request fails, so only pictures on disk show.
private nonisolated struct NoNetwork: DataFetching {
    func data(from url: URL) async throws -> (Data, Int) {
        throw URLError(.notConnectedToInternet)
    }
}
