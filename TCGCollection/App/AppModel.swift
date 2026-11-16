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

/// What the window shows, chosen in the sidebar. `storedValue` is the `-screen` flag's value and the stored one: the four
/// screens of phase 2 keep their strings (`collection`, `wanted`, `for-sale`, `all-cards`), so a value an older build
/// stored is still read; a deck is `deck:<id>` (its id in the game's file).
nonisolated enum Screen: Hashable, Sendable {
    case collection
    case wanted
    case forSale
    case allCards
    /// One deck of the game on screen, by its id.
    case deck(String)

    private static let deckPrefix = "deck:"

    init?(storedValue: String) {
        switch storedValue {
        case "collection": self = .collection
        case "wanted": self = .wanted
        case "for-sale": self = .forSale
        case "all-cards": self = .allCards
        case _ where storedValue.hasPrefix(Self.deckPrefix) && storedValue.count > Self.deckPrefix.count:
            self = .deck(String(storedValue.dropFirst(Self.deckPrefix.count)))
        default: return nil
        }
    }

    var storedValue: String {
        switch self {
        case .collection: "collection"
        case .wanted: "wanted"
        case .forSale: "for-sale"
        case .allCards: "all-cards"
        case .deck(let id): Self.deckPrefix + id
        }
    }

    /// A list of the user's (the Collection, Wanted, For Sale, a deck): it shows the library's lines (a problem, a settled
    /// conflict) itself, on the screen and its pages. On any other screen the sidebar shows them.
    var isList: Bool { self != .allCards }

    /// `screen`, unless it is a deck that `deckIDs` (the game's decks, once the folder is read) lacks: then the Collection.
    static func checked(_ screen: Screen, deckIDs: [String]) -> Screen {
        guard case .deck(let id) = screen, !deckIDs.contains(id) else { return screen }
        return .collection
    }
}

nonisolated enum StatusText {
    static let checking = "Checking the catalog…"
    /// The store file could not be opened; it was moved aside and the sync fills a fresh one.
    static let storeRecovered = "The catalog could not be read and is downloaded again."
    /// The person asked for a reset in the last run; the store was set aside and the sync fills a fresh one.
    static let storeReset = "The catalog was reset and is downloaded again."
    /// The catalog sync waits for the next UTC day: the sets were fetched today, into a store that is gone (reset,
    /// unreadable, deleted). tcgcsv: never the same set twice in one day. Also the empty screen's text then.
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
    /// A Sold choice the library refused: the copies for sale changed while the dialog was open (C7).
    static let nothingSold = "Nothing was sold: the copies for sale changed."
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
    var ygoIndex: YGOPictureIndex? {
        didSet { ygoIndexVersion += 1 }
    }
    /// Goes up each time `ygoIndex` is replaced: part of a deck join's key (`DeckJoin.deckKey`, final fix B7).
    private(set) var ygoIndexVersion = 0
    /// The game on screen, kept in `UserDefaults` (key `game`). `-game` wins at launch.
    var gameID: String {
        didSet {
            defaults.set(gameID, forKey: Self.gameKey)
            // A deck belongs to one game: another game opens the Collection.
            if gameID != oldValue, case .deck = screen { screen = .collection }
        }
    }
    var game: GameDefinition { Games.game(gameID) ?? Games.all[0] }
    /// The sidebar selection, kept in `UserDefaults` (key `screen`; with `-store`, the root's own). `-screen` wins at
    /// launch; a new root opens on the Collection. The sidebar sets it (a person's click: the screen comes back with the
    /// pages it kept); code switches with `showRoot(of:)`.
    var screen: Screen {
        didSet { defaults.set(screen.storedValue, forKey: Self.screenKey) }
    }
    /// Screens that a switch made by code opened (`showRoot(of:)`) and whose pages have not changed since: they show their
    /// root, not the pages kept from an earlier visit (`Binding.kept(on:in:)`).
    private(set) var rootShown: Set<Screen> = []
    private(set) var status: Status = .idle("") {
        didSet {
            #if DEBUG
            // One line per change, so a background run can be followed in a log file.
            if status != oldValue { FileHandle.standardOutput.write(Data("status \(status)\n".utf8)) }
            #endif
            // The next status replaces an import's summary.
            if status != oldValue { statusNotice = nil }
        }
    }
    /// Goes up when a sync changed the store (also at every 20th finished set of the game on screen), so views search again.
    private(set) var catalogVersion = 0
    /// Sets of the game on screen that finished in the running catalog step; every 20th one raises `catalogVersion`.
    @ObservationIgnored private var finishedOnScreen = 0
    /// Goes up when a catalog step that changed the store has ended, so the filter menus read their values again.
    /// It does not follow the periodic steps of `catalogVersion`: those values come from every product of a game.
    private(set) var filtersVersion = 0

    /// The Rarity and Type menu values per game: read from `facets-<game>.json` at launch, rewritten after a catalog
    /// step that changed the game. A game with no entry shows empty menus.
    @ObservationIgnored private var facetLists: [String: FacetLists] = [:]

    /// Set by `-card`: the card page the window opens once. `RootView` takes it and clears it.
    var pendingCard: CardTarget?
    /// Set by `-exportPDF` where it is allowed (`LaunchOptions.launchPDF`): the list screen it names writes its PDF once
    /// its list is read by a join made on a settled catalog that had the game's prices (offline: without waiting for
    /// prices; `PDFExport.launchReady`), and takes it (`takeLaunchPDF`).
    @ObservationIgnored private var launchPDF: LaunchPDF?

    /// What the user owns. Every screen that shows or changes the collection talks to it.
    let library: UserLibrary
    /// Where the user folder is and what the folder sheet may do in this run (`UserFolder.setup`).
    let userFolderSetup: UserFolderSetup
    /// True until a folder is chosen (a Release build's first run, or `-askUserFolder YES`): the folder sheet is open and
    /// cannot be closed without a choice.
    private(set) var needsUserFolder: Bool
    /// "Collection Folder…" asked for the folder sheet.
    var showsFolderSheet = false
    /// "Import CSV…" asked for the system's file panel (`chooseCSVFile`).
    var choosesCSVFile = false
    /// The import the sheet shows (`ImportSheet`); nil while no import sheet is open.
    var importing: ImportModel?
    /// "New Deck…" (the sidebar, or a card page's "Add to deck") asked for its sheet (`NewDeckSheet`).
    var showsNewDeck = false
    /// "New Deck…" of a card page's "Add to deck": the card the new deck gets one copy of after Create. Nil when the
    /// sidebar opened the sheet; cleared when the sheet closes.
    var newDeckCard: DeckCardToAdd?
    /// A deck page's Rename sheet is open (`RenameDeckSheet` sets it while it shows).
    var renamingDeck = false
    /// The paste the paste sheet shows (`PasteDeckSheet`); nil while no paste sheet is open.
    var pasting: PasteDeckModel?
    /// Wanted's "Decisions (n)…" asked for the sheet "Sharing decisions" (`SharingSheet`, E7).
    var showsSharing = false
    /// Each game's names for a paste's unknown names, kept for the run per catalog version (final fix B1).
    @ObservationIgnored private(set) lazy var pasteNames = PasteNames(container: reader.modelContainer)
    /// "Paste a deck…" of the New Deck sheet: the name and format typed there. The paste sheet opens with them once the New
    /// Deck sheet has closed (`openPendingPaste`).
    @ObservationIgnored var pendingPaste: (name: String, format: String)?
    /// True while the window has one of the app's sheets open (the folder sheet, the CSV file panel, the import sheet, the
    /// New Deck sheet, the Rename sheet, the paste sheet, the sharing sheet): a dialog asked for meanwhile would not show
    /// (For Sale's Sold dialog does not open again then).
    var showsSheet: Bool {
        choosesCSVFile || importing != nil || showsOtherSheet
    }
    /// A sheet open that is not the import's own (the file panel, the import sheet): an import does not start under it
    /// (final fix B5).
    private var showsOtherSheet: Bool {
        needsUserFolder || showsFolderSheet || showsNewDeck || renamingDeck || pasting != nil || showsSharing
    }
    /// Said once after an import, when for-sale counts followed owned counts down (`UserLibrary.saleNotice`, C8), and when
    /// a Sold or a PDF did not end as asked (refused, not saved, not made): the status line shows it in place of `status`
    /// until the status changes (the next sync line replaces it) or `noticeDuration` has passed. `status` itself is never
    /// replaced, so the sync's line comes back.
    private(set) var statusNotice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Each `importApplied` takes the next number; only the latest one sets the notice after its wait.
    @ObservationIgnored private var appliedImports = 0
    /// The `importApplied` calls still waiting for their writes: the for-sale notice of an import is said with its result.
    @ObservationIgnored private var importsBeingSaid = 0
    /// E8: the last known count of pending cards and its game (`pendingCountChanged`); nil until the first one.
    @ObservationIgnored private var pendingBase: (game: String, count: Int)?
    /// Final fix A2: a rise of the pending count that waits behind another notice: its game and the count before the
    /// rise. Said with the count of the moment once that notice is gone (`sayHeldPendingNotice`), unless the count is
    /// back at or under `base` by then.
    @ObservationIgnored private var pendingHeld: (game: String, base: Int)?
    /// The last pending notice said: a newer one may replace it (it is not "another notice").
    @ObservationIgnored private var pendingSaid: String?
    /// The last "The sale was not saved: …" said: the for-sale notice does not hide it.
    @ObservationIgnored private var unsavedSaleSaid: String?
    /// True while a picked file is read (`importCSV(from:)`). A second import is ignored then, and while `importing` is set.
    private(set) var readsImport = false
    /// Tests only: runs on the main actor before a picked file is read, so a test can act while the read is in progress.
    @ObservationIgnored var beforeImportRead: (@MainActor (URL) async -> Void)?
    /// How long a status notice stays (`say`). Tests shorten it.
    @ObservationIgnored var noticeDuration = Duration.seconds(20)

    #if DEBUG
    nonisolated static let isDebugBuild = true
    #else
    nonisolated static let isDebugBuild = false
    #endif
    /// The chosen user folder, as a bookmark, in this run's preferences (with `-store`: the root's own).
    nonisolated static let userFolderBookmarkKey = "userFolderBookmark"

    private static let gameKey = "game"
    private static let screenKey = "screen"
    /// Set by "Reset the catalog…" (`requestCatalogReset`); the next launch sets the store aside and clears it.
    private nonisolated static let resetKey = "resetCatalogOnNextLaunch"
    /// The UTC day (`yyyy-MM-dd`) of the last catalog step that fetched at least one set. It outlives the store, so a
    /// store set aside or lost on that day does not lead to a second fetch of the same sets (`catalogHeld`).
    private nonisolated static let lastFetchDayKey = "lastCatalogFetchDay"
    /// The UTC day of the last `cardinfo.php` request, made or failed: a failed refresh is not tried again that day.
    private nonisolated static let lastYGOIndexAttemptDayKey = "lastYGOIndexAttemptDay"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogSync: CatalogSync
    @ObservationIgnored private let priceSync: PriceSync
    @ObservationIgnored private let ygoLoader: YGOIndexLoader
    @ObservationIgnored private let now: () -> Date
    /// The status line when no catalog store file is open: the app then runs on an empty store in memory and downloads
    /// nothing. Nil when a store file is open.
    @ObservationIgnored let storeFailure: String?
    /// True when the store-failure state offers "Reset the catalog…". Not for a lack of disk space (M8): a reset frees
    /// nothing, and its download would fill the disk further.
    @ObservationIgnored let canResetCatalog: Bool
    /// The person asked for a reset in this run (in the store-failure state); the next launch does it.
    private(set) var catalogResetRequested = false
    /// True while the catalog sync waits for the next UTC day (`catalogHeld`): no catalog step runs, the empty screen
    /// says why and has no Try again. Set by each sync; at launch already when this launch set the store aside on the
    /// day of the last fetch.
    private(set) var catalogWaits = false
    /// The games whose catalog step of this run is still to come or running: every game from a launch that syncs until
    /// its step of the first sync has ended, and again during each Refresh or Rebuild. A step that ended with failed sets
    /// counts as ended. Empty offline, with a store in memory, and while the catalog waits for the next UTC day.
    private(set) var catalogPending: Set<String> = []
    /// The status of the first catalog check. After a store was moved aside it says so, until the first set is in.
    @ObservationIgnored private var checkingText = StatusText.checking
    @ObservationIgnored private var isRunning = false
    /// The launch steps and the first sync, made by the first `start()`. The model owns it, not a window: a window
    /// that closes cancels its own `.task`, not this one.
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// The launch's one cleaning of the picture cache (`PictureStore.clean`, the 3 GB limit): the names it deleted. Nil
    /// before the launch.
    @ObservationIgnored private(set) var pictureCleaning: Task<[String], Never>?

    init(options: LaunchOptions, catalogClient: any TCGCSVFetching, archiveClient: any ArchiveFetching,
         fetcher: any DataFetching, now: @escaping () -> Date = { Date() },
         availableCapacity: @Sendable (URL) -> Int? = StoreFile.availableCapacity) {
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
        let setup = UserFolder.setup(storeRoot: options.storeRoot, isDebugBuild: Self.isDebugBuild,
                                     askUserFolder: options.askUserFolder,
                                     bookmark: defaults.data(forKey: Self.userFolderBookmarkKey), iCloudDrive: Self.iCloudDrive)
        userFolderSetup = setup
        Self.prepareUserFolder(setup, defaults: defaults)
        needsUserFolder = setup.choice == .none
        library = UserLibrary(folder: setup.choice.url, watcher: FolderPresenter())
        #if DEBUG
        library.writeDelay = options.writeDelay.map { .milliseconds($0) }
        #endif
        let opened = Self.openStore(paths: paths, now: now(), defaults: defaults, availableCapacity: availableCapacity)
        store = opened.store
        storeFailure = opened.failure
        canResetCatalog = opened.failure != nil && opened.canReset
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
        screen = options.screen ?? defaults.string(forKey: Self.screenKey).flatMap(Screen.init(storedValue:)) ?? .collection
        #if DEBUG
        launchPDF = options.launchPDF(isDebugBuild: Self.isDebugBuild)
        #endif
        if let notice = opened.notice {
            // A notice means the store was set aside and a fresh, empty one opened. On the day of the last fetch that is
            // enough to know the sync waits (`catalogHeld`), before any store read.
            checkingText = notice
            if defaults.string(forKey: Self.lastFetchDayKey) == SyncPlan.utcDay(now()) {
                catalogWaits = true
                status = .idle(StatusText.resetWaits)
            } else {
                status = .idle(notice)
            }
        }
        // A launch that syncs has every game's catalog step still to come.
        if !options.offline, opened.failure == nil, !catalogWaits { catalogPending = Set(Games.all.map(\.id)) }
    }

    /// True when no catalog step of this run is running or still to come for the game (`catalogPending`): the catalog
    /// then holds every product of the game it is going to hold in this run.
    func catalogSettled(game: String) -> Bool { !catalogPending.contains(game) }

    /// A switch made by code ("Search a card", "Open the collection", the import, `-card`): `screen` opens on its root, not
    /// on a page kept from an earlier visit; only the sidebar returns to kept pages.
    func showRoot(of screen: Screen) {
        rootShown.insert(screen)
        self.screen = screen
    }

    /// True while `screen` shows its root after a switch made by code (`showRoot(of:)`).
    func showsRoot(_ screen: Screen) -> Bool { rootShown.contains(screen) }

    /// A page was opened or closed on `screen` while it was on show: it shows its own pages again.
    func pagesChanged(on screen: Screen) {
        if rootShown.contains(screen) { rootShown.remove(screen) }
    }

    /// `-exportPDF`: the file the list screen `screen` writes its PDF to, once; nil for any other screen, and after the
    /// first take.
    func takeLaunchPDF(for screen: Screen) -> URL? {
        guard let launchPDF, launchPDF.screen == screen else { return nil }
        self.launchPDF = nil
        return launchPDF.file
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
    /// is the status line that says why; `canReset` is false when a reset cannot help (no space for a migration). `notice`
    /// is the status line after a store was set aside.
    private nonisolated static func openStore(paths: AppPaths, now: Date, defaults: UserDefaults,
                                              availableCapacity: @Sendable (URL) -> Int?)
        -> (store: CatalogStore, notice: String?, failure: String?, canReset: Bool) {
        func open() throws -> CatalogStore { try CatalogStore(url: paths.catalogStore, availableCapacity: availableCapacity) }
        if defaults.bool(forKey: resetKey) {
            defaults.removeObject(forKey: resetKey)
            do {
                try moveAside(paths.catalogStore, into: paths.unreadable(at: now))
                return (try open(), StatusText.storeReset, nil, false)
            } catch {
                // Not moved, or no fresh store: the open below judges what is at the path, as on any launch.
            }
        }
        let failure: String
        var canReset = true
        do {
            return (try open(), nil, nil, false)
        } catch {
            switch CatalogStore.classify(error) {
            case .other(let text):
                failure = text
                if case .notEnoughSpace? = error as? StoreOpenError { canReset = false }
            case .unreadable:
                do {
                    try moveAside(paths.catalogStore, into: paths.unreadable(at: now))
                    return (try open(), StatusText.storeRecovered, nil, false)
                } catch {
                    failure = StatusText.storeCannotOpen(CatalogStore.reason(error))
                }
            }
        }
        do {
            return (try CatalogStore.inMemory(), nil, failure, canReset)
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

    // MARK: The user folder

    /// iCloud Drive, for "Use iCloud Drive". A Debug build never looks for it: the call is not compiled there.
    private nonisolated static func iCloudDrive() -> URL? {
        #if DEBUG
        return nil
        #else
        return UserFolder.iCloudDriveRoot()
        #endif
    }

    /// At launch. A folder this app owns (`<root>/user`, the Debug folder) is made with its settings file; so is the
    /// stand-in iCloud Drive `<root>/icloud` of `-askUserFolder`. A chosen folder gets access for this run and a fresh
    /// bookmark when its bookmark is stale; it is never made here (Review Focus 3).
    private static func prepareUserFolder(_ setup: UserFolderSetup, defaults: UserDefaults) {
        let fm = FileManager.default
        if setup.boundary != nil, let standIn = setup.iCloudDrive {
            try? fm.createDirectory(at: standIn, withIntermediateDirectories: true)
        }
        switch setup.choice {
        case .testRoot(let folder), .debugLocal(let folder):
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? UserFiles.writeSettingsIfMissing(in: folder)
        case .iCloud(let folder), .picked(let folder):
            _ = folder.startAccessingSecurityScopedResource()
            if let data = defaults.data(forKey: userFolderBookmarkKey), UserFolder.url(fromBookmark: data)?.stale == true,
               let fresh = try? UserFolder.bookmark(for: folder) {
                defaults.set(fresh, forKey: userFolderBookmarkKey)
            }
        case .none:
            break
        }
    }

    /// "Use iCloud Drive": makes `TCG Collection` in iCloud Drive when it is not there (with `-askUserFolder`, in the stand-in
    /// `<root>/icloud`) and keeps the collection in it. The only code that makes a folder in iCloud Drive; a Debug build
    /// has no iCloud Drive (`userFolderSetup.iCloudDrive` is nil or the stand-in).
    func useICloudDrive() async throws {
        guard userFolderSetup.canChoose, let drive = userFolderSetup.iCloudDrive else { throw UserFolderError.fixed }
        try await use(UserFolder.defaultICloudFolder(in: drive), making: true)
    }

    /// "Choose a folder…": keeps the collection in `folder` (it exists; nothing is copied or moved into it).
    func useFolder(_ folder: URL) async throws {
        try await use(folder, making: false)
    }

    /// Writes `settings.json` when the folder has none, keeps the bookmark, then the library loads the folder. A run whose
    /// folder is fixed refuses; a Debug build refuses a folder outside its store root.
    private func use(_ folder: URL, making: Bool) async throws {
        guard userFolderSetup.canChoose else { throw UserFolderError.fixed }
        if let boundary = userFolderSetup.boundary, !UserFolder.isInside(folder, boundary) {
            throw UserFolderError.outside(path: boundary.path)
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        do {
            let bookmark = try await Self.prepareChosenFolder(folder, making: making)
            defaults.set(bookmark, forKey: Self.userFolderBookmarkKey)
        } catch {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            throw error
        }
        needsUserFolder = false
        showsFolderSheet = false
        await library.use(folder: folder)
    }

    /// Off the main actor: coordinated work in iCloud Drive can wait for the sync.
    @concurrent private nonisolated static func prepareChosenFolder(_ folder: URL, making: Bool) async throws -> Data {
        if making { try UserFiles.makeFolder(folder) }
        try UserFiles.writeSettingsIfMissing(in: folder)
        return try UserFolder.bookmark(for: folder)
    }

    // MARK: CSV import

    /// "Import CSV…": opens the system's file panel. Not while a sheet of the window is open (`showsSheet`) or a file is
    /// read, so an import is never left pending behind another sheet.
    func chooseCSVFile() {
        guard canStartImport, !choosesCSVFile else { return }
        choosesCSVFile = true
    }

    /// One import at a time: none is open, no file is being read for one, and no other sheet is open.
    private var canStartImport: Bool { importing == nil && !readsImport && !showsOtherSheet }

    /// Reads the picked file (security-scoped, off the main thread; it is never written) and opens the import sheet on it.
    /// Ignored while another import is open or its file is still read, and while another sheet is open.
    func importCSV(from url: URL) async {
        guard canStartImport else { return }
        readsImport = true
        defer { readsImport = false }
        await beforeImportRead?(url)
        let name = url.lastPathComponent
        do {
            let data = try await Self.readFile(url)
            importing = ImportModel(data: data, fileName: name, library: library, reader: reader, prices: prices,
                                    catalogSettled: { [weak self] game in self?.catalogSettled(game: game) ?? false })
        } catch {
            importing = ImportModel(unreadable: error.localizedDescription, fileName: name, library: library, reader: reader)
        }
    }

    /// The file panel gave no file: the import sheet says why.
    func importFailed(_ error: any Error) {
        guard canStartImport else { return }
        importing = ImportModel(unreadable: error.localizedDescription, fileName: "CSV", library: library, reader: reader)
    }

    @concurrent private nonisolated static func readFile(_ url: URL) async throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// After Import: the sheet closes and the Collection shows the first imported game at once. Once the import's writes
    /// have run, the status line says the summary once (`statusNotice`); when an imported game then has a problem (its
    /// write failed, its file was refused), it says that game's problem instead, never "Imported: …".
    /// An import that took copies off sale (C8) says so after its summary: "Imported: …. 2 copies are no longer for sale.".
    /// After a problem sentence the for-sale notice waits until that sentence is gone.
    func importApplied(_ applied: ImportModel.Applied) async {
        importsBeingSaid += 1
        defer { importsBeingSaid -= 1 }
        importing = nil
        gameID = applied.gameID
        showRoot(of: .collection)
        // An earlier import's notice is not this one's result.
        noticeTask?.cancel()
        statusNotice = nil
        appliedImports += 1
        let number = appliedImports
        await library.flush()
        // A later import (its own wait) says its own result.
        guard number == appliedImports else { return }
        if let problem = applied.games.lazy.compactMap({ self.library.problem(game: $0) }).first {
            say(problem)
            return
        }
        let sale = library.saleNotice
        library.clearSaleNotice()
        say("Imported: \(applied.summary)" + (sale.map { ". \($0)" } ?? ""))
    }

    // MARK: Pasting a deck

    /// "Paste…" of a deck page (`deckID`), or "Paste a deck…" of the New Deck sheet (nil: a new deck with `name` and
    /// `format`): opens the paste sheet on the game shown. Not while another sheet is open.
    func pasteDeck(into deckID: String?, name: String = "", format: String = "", text: String = "") {
        guard pasting == nil, importing == nil, !needsUserFolder, !showsFolderSheet else { return }
        let game = Games.game(gameID)
        pasting = PasteDeckModel(gameID: gameID, deckID: deckID, name: name, format: format, text: text, library: library,
                                 reader: reader,
                                 catalogSettled: { [weak self] game in self?.catalogSettled(game: game) ?? false },
                                 ygoType: { [weak self] name in game?.pictures == .ygoprodeck ? self?.ygoType(cardName: name) : nil },
                                 names: pasteNames,
                                 catalogVersion: { [weak self] in self?.catalogVersion ?? 0 })
    }

    /// The New Deck sheet has closed: the paste sheet it asked for opens now (two sheets never change places at once).
    func openPendingPaste() {
        guard let pending = pendingPaste else { return }
        pendingPaste = nil
        pasteDeck(into: nil, name: pending.name, format: pending.format)
    }

    /// C7: sells `count` copies of a printing on the For Sale list, at the price of this moment (the price table's, for
    /// the printing's finish; none when it has none). When the library refuses, nothing is sold and the status line says
    /// why: the card page's sentence when the game cannot change (the folder is missing or switched, the file refused:
    /// `countsLocked`, A2); else "Nothing was sold: the copies for sale changed." (more than are for sale or owned by
    /// now: they changed while the dialog was open). True when it sold.
    @discardableResult
    func sell(_ count: Int, game: String, key: PrintingKey) -> Bool {
        guard library.sell(count, game: game, key: key, price: prices.shown(game: game, key: key)) else {
            say(library.countsLocked(game: game) ?? StatusText.nothingSold)
            return false
        }
        return true
    }

    /// A list's PDF export ended without a PDF to save (`PDFExport`: none could be drawn, or the list was left before its
    /// save panel opened): the status line says so.
    func pdfEnded(_ notice: String) {
        say(notice)
    }

    /// The save panel of a list's PDF ended (`fileExporter`): a failure that is not a cancel is said in the status line
    /// ("The PDF could not be saved: …", `PDFExport.saveNotice`).
    func pdfSaveEnded(_ result: Result<URL, any Error>) {
        if let notice = PDFExport.saveNotice(result) { say(notice) }
    }

    /// E8: what the status line says when the count of pending cards of the game on screen changes from `was` to `now`:
    /// "1 card needs a sharing decision." / "<n> cards need a sharing decision." when it went up; nil when it did not, and
    /// for a first value (`was` nil: the base, cards already pending when the folder was first read).
    nonisolated static func pendingNotice(was: Int?, now: Int) -> String? {
        guard let was, now > was else { return nil }
        return now == 1 ? "1 card needs a sharing decision." : "\(now) cards need a sharing decision."
    }

    /// E8: the count of pending cards of `game` (the sidebar's, `DeckPage.pendingCount`): nil while it is not known (no read
    /// of the game's active decks yet: their owned copies are unknown). The first known count of the game on screen is the
    /// base and says nothing; a count that goes up says `pendingNotice` once. A count of another game than the one on
    /// screen (a late value after a switch) is not taken; a switch starts a new base.
    /// Final fix A2: the notice never replaces another notice (a problem sentence, "The sale was not saved: …", the
    /// for-sale notice, "Imported: …", a PDF notice) and is never lost: while one is on, or an import's result is still to
    /// come, it waits, and is said once that notice is gone with the count of that moment; nothing when the count is back
    /// at or under the count before the rise by then.
    func pendingCountChanged(_ count: Int?, game: String) {
        guard game == gameID, let count else { return }
        let was = pendingBase?.game == game ? pendingBase?.count : nil
        pendingBase = (game, count)
        if pendingHeld?.game != game { pendingHeld = nil }
        if let was, Self.pendingNotice(was: was, now: count) != nil, pendingHeld == nil { pendingHeld = (game, was) }
        sayHeldPendingNotice()
    }

    /// Says the pending notice that waits (`pendingHeld`) when the status line shows no other notice and no import's result
    /// is to come; drops it when its game is not on screen any more or the count is back at or under its base.
    private func sayHeldPendingNotice() {
        guard let held = pendingHeld else { return }
        guard held.game == gameID, let base = pendingBase, base.game == held.game,
              let notice = Self.pendingNotice(was: held.base, now: base.count) else {
            pendingHeld = nil
            return
        }
        if importsBeingSaid > 0 { return }
        if let shown = statusNotice, shown != pendingSaid { return }
        pendingHeld = nil
        pendingSaid = notice
        say(notice)
    }

    /// Shows `text` in the status line for `noticeDuration`, unless something else is said or the status changes first.
    private func say(_ text: String) {
        noticeTask?.cancel()
        statusNotice = text
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.statusNotice == text else { return }
            self.statusNotice = nil
        }
    }

    /// A3: says a sale the library's write dropped ("The sale was not saved: …") at once, then clears it. C8: says the
    /// library's for-sale notice once, then clears it. That one waits while an import sheet is open or an import's result
    /// is to come (the import says it with its summary), and while the status line shows a problem sentence or a sale
    /// that was not saved (it never hides one); each of those ending calls this again (`watchSaleNotices`).
    private func sayPendingSaleNotice() {
        if let unsaved = library.unsavedSaleNotice {
            library.clearUnsavedSaleNotice()
            unsavedSaleSaid = unsaved
            say(unsaved)
            return
        }
        guard let sale = library.saleNotice, importing == nil, importsBeingSaid == 0 else { return }
        if let shown = statusNotice, library.problems.contains(shown) || shown == unsavedSaleSaid { return }
        library.clearSaleNotice()
        say(sale)
    }

    /// Calls `sayPendingSaleNotice`, then `sayHeldPendingNotice`, whenever the library's notices, the import sheet or the
    /// status line's notice change, for as long as the model lives.
    private func watchSaleNotices() {
        let library = library
        let changes = Observations { [weak self] in
            (library.saleNotice, library.unsavedSaleNotice, self?.importing == nil, self?.statusNotice)
        }
        Task { [weak self] in
            for await _ in changes {
                self?.sayPendingSaleNotice()
                self?.sayHeldPendingNotice()
            }
        }
    }

    // MARK: Launch

    /// Loads the user folder, prices and the Yu-Gi-Oh! index from disk, then syncs (not with `-offline YES`). Once per app
    /// run: every window calls it, and a later call waits for the same work.
    func start() async {
        if launchTask == nil { launchTask = Task { await launch() } }
        await launchTask?.value
    }

    private func launch() async {
        watchSaleNotices()
        // Once per launch, with the window on screen: at background priority, off the main thread and off the picture
        // store's actor, so neither the window nor a picture load waits for it. Only the run's own picture folder.
        let pictures = pictures
        pictureCleaning = Task.detached(priority: .background) { pictures.clean() }
        #if DEBUG
        // `-importCSV` (with `-store`): the sheet opens before the folder is read; the import waits for that read. With
        // `-importCSVDelay` it opens that long after the launch, so a UI test can open a page first; it holds nothing.
        if let file = options.launchImport(isDebugBuild: Self.isDebugBuild) {
            if let delay = options.importCSVDelay {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    await self?.importCSV(from: file)
                }
            } else {
                await importCSV(from: file)
            }
        }
        #endif
        await library.load()
        // A stored or launched deck screen whose deck is not in the game's file opens the Collection.
        let checked = Screen.checked(screen, deckIDs: library.decks(game: gameID).map(\.id))
        if checked != screen { screen = checked }
        #if DEBUG
        // `-pasteDeck` (with `-store`): the paste sheet with the file's text, on the deck shown, else for a new deck.
        if let file = options.launchPaste(isDebugBuild: Self.isDebugBuild), let text = try? String(contentsOf: file, encoding: .utf8) {
            if case .deck(let id) = screen { pasteDeck(into: id, text: text) } else { pasteDeck(into: nil, name: DeckRules.uniqueName("Deck", among: library.decks(game: gameID).map(\.name)), text: text) }
        }
        #endif
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
        await sync(rebuild: false)
    }

    /// A game with products and no facets file (a store migrated from phase 1 has none) gets its lists computed once
    /// (`storeFacetLists`), so the menus do not wait for a sync.
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
    /// The scan (2.6 s for Magic) runs on a store of its own on the same container, released after it, so a search or a
    /// card page on `reader` does not wait behind it (M1).
    private func storeFacetLists(of game: GameDefinition) async -> Bool {
        let scan = CatalogStore(modelContainer: store.modelContainer)
        guard let lists = try? await scan.facetLists(game: game.id) else { return false }
        facetLists[game.id] = lists
        try? lists.write(to: paths.facets(game.id))
        return true
    }

    /// `-card <productId>`: switches to the product's game and to All cards (card pages live there), and asks the window
    /// to open its card page.
    private func openLaunchCard() async {
        guard let id = options.card, let product = try? await reader.product(id),
              let game = Games.game(product.gameID) else { return }
        gameID = game.id
        showRoot(of: .allCards)
        pendingCard = CardTarget(gameID: game.id, cardKey: CardName.searchKey(product.cardName), startProductID: product.productID)
    }

    /// False offline and with a store that cannot be opened: then nothing is downloaded.
    var canSync: Bool { !options.offline && storeFailure == nil }

    /// Does nothing when the app cannot sync, or while a sync runs. Its catalog steps wait as `catalogHeld` says.
    func refresh(rebuild: Bool) async {
        guard canSync else { return }
        await sync(rebuild: rebuild)
    }

    /// I2: the catalog steps wait for the next UTC day when the last catalog step that fetched a set ran today (UTC) and
    /// the store has no set with a fetch date. The sets were then fetched today into a store that is gone (reset,
    /// unreadable, deleted), in this launch or an earlier one. A brand-new install (no day), a download cut short today
    /// (the store has fetched sets) and the next UTC day do not wait. A store that cannot be read waits.
    private func catalogHeld(now: Date) async -> Bool {
        guard defaults.string(forKey: Self.lastFetchDayKey) == SyncPlan.utcDay(now) else { return false }
        return !((try? await reader.anySetFetched()) ?? false)
    }

    /// The game on screen gets its cards and prices first; Magic and Yu-Gi-Oh! take many minutes.
    private func sync(rebuild: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            catalogPending = []
        }
        let now = self.now()
        // A held sync skips only the catalog steps: the price and index steps keep their own once-a-day rules.
        let held = await catalogHeld(now: now)
        catalogWaits = held
        catalogPending = held ? [] : Set(Games.all.map(\.id))
        let chosen = game
        var first = SyncResult(fetched: 0, failed: 0, newSets: [:]), rest = first
        if !held {
            first = await syncCatalog(of: [chosen], now: now, rebuild: rebuild)
            catalogPending.remove(chosen.id)
        }
        let priceFailure = await syncPrices(now: now)
        if !held {
            rest = await syncCatalog(of: Games.all.filter { $0.id != chosen.id }, now: now, rebuild: rebuild)
            catalogPending = []
        }
        let result = SyncResult(fetched: first.fetched + rest.fetched, failed: first.failed + rest.failed,
                                failedSetLists: first.failedSetLists + rest.failedSetLists,
                                removedSets: first.removedSets + rest.removedSets,
                                newSets: first.newSets.merging(rest.newSets, uniquingKeysWith: +))
        // The new sets of the game whose pictures come from YGOPRODeck: the index maps their printings to pictures.
        let indexSets = Games.all.filter { $0.pictures == .ygoprodeck }.reduce(0) { $0 + result.newSets[$1.id, default: 0] }
        let indexFailure = await refreshYGOIndexIfNeeded(newSets: indexSets, now: now)
        if held {
            let failure = priceFailure ?? indexFailure
            status = failure.map { .failed(StatusText.resetWaits + " · " + $0) } ?? .idle(StatusText.resetWaits)
            return
        }
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
        finishedOnScreen = 0
        async let result = Self.run(catalogSync, games: games, now: now, rebuild: rebuild, reportingTo: sink)
        var touched = Set<String>()
        for await progress in updates {
            touched.insert(progress.gameID)
            show(progress)
        }
        let done = await result
        // Nothing reads the store's change history, and a full re-fetch writes about 12 MB of it (B12).
        if done.fetched > 0 || done.failed > 0 || done.removedSets > 0 { try? await store.deleteHistory() }
        if done.fetched > 0 || done.removedSets > 0 {
            // A game that reported progress had a set stored or failed; its lists are read again before the menus are told.
            // A removal can leave a game with no event (every set excluded), so then every game of the step is read.
            for game in games where done.removedSets > 0 || touched.contains(game.id) { _ = await storeFacetLists(of: game) }
            catalogVersion += 1
            filtersVersion += 1
        }
        if done.fetched > 0 { defaults.set(SyncPlan.utcDay(now), forKey: Self.lastFetchDayKey) }
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
        if progress.gameID == gameID {
            finishedOnScreen += 1
            if finishedOnScreen % 20 == 0 { catalogVersion += 1 }
        }
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
        let attemptedToday = defaults.string(forKey: Self.lastYGOIndexAttemptDayKey) == SyncPlan.utcDay(now)
        guard Self.needsYGOIndex(hasIndex: ygoIndex != nil, isCurrent: ygoIndex?.isCurrent ?? true, newSets: newSets,
                                 attemptedToday: attemptedToday, writtenAt: writtenAt, now: now) else { return nil }
        defaults.set(SyncPlan.utcDay(now), forKey: Self.lastYGOIndexAttemptDayKey)   // before the request: a failure counts
        status = .syncing(StatusText.ygoIndex)
        do {
            ygoIndex = try await ygoLoader.refresh()
            return nil
        } catch {
            return "Yu-Gi-Oh! pictures: \(Self.describe(error))"
        }
    }

    /// D9: fetch the index when there is none, or when the sync added a Yu-Gi-Oh! set and the index is not from today (UTC).
    /// An index of an older version (no types, D14) is fetched once more. No request is made twice in one UTC day,
    /// whatever else holds (`attemptedToday`: the last request of the day may have failed, so the file did not change).
    nonisolated static func needsYGOIndex(hasIndex: Bool, isCurrent: Bool, newSets: Int, attemptedToday: Bool,
                                          writtenAt: Date?, now: Date) -> Bool {
        guard !attemptedToday else { return false }
        guard hasIndex else { return true }
        guard newSets > 0 || !isCurrent else { return false }
        guard let writtenAt else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return !calendar.isDate(writtenAt, inSameDayAs: now)
    }

    /// The YGOPRODeck type (`frameType`) of a Yu-Gi-Oh! card by name; nil when the index lacks it (A15: fall back).
    func ygoType(cardName: String) -> String? {
        ygoIndex?.type(name: cardName)
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
