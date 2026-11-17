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
    /// The game's sets, how much of each master set is owned (phase 4A).
    case sets
    case allCards
    /// One deck of the game on screen, by its id.
    case deck(String)

    private static let deckPrefix = "deck:"

    init?(storedValue: String) {
        switch storedValue {
        case "collection": self = .collection
        case "wanted": self = .wanted
        case "for-sale": self = .forSale
        case "sets": self = .sets
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
        case .sets: "sets"
        case .allCards: "all-cards"
        case .deck(let id): Self.deckPrefix + id
        }
    }

    /// A list of the user's (the Collection, Wanted, For Sale, Sets, a deck): it shows the library's lines (a problem, a settled
    /// conflict) itself, on the screen and its pages. On any other screen the sidebar shows them.
    var isList: Bool { self != .allCards }

    /// `screen` as a launch may show it once the folder is read (`GameSections.screen`): a deck that `deckIDs` (the game's
    /// decks) lacks, a deck without the player role and Sets without the collector role open the Collection.
    static func checked(_ screen: Screen, profile: GameProfile = .all, deckIDs: [String]) -> Screen {
        GameSections.screen(screen, profile: profile, deckExists: deckIDs.contains)
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
            // A deck belongs to one game: another game opens the Collection. G8: so does Sets of a game without the
            // collector role.
            if gameID != oldValue, case .deck = screen { screen = .collection }
            if gameID != oldValue, screen == .sets, !GameSections.showsSets(profile(of: gameID)) { screen = .collection }
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
    /// Each game's set index (F3): read from `sets-<game>.json` by the launch, off the main actor (final fix A1: the
    /// window does not wait for it); made again, in the model's own task, after a catalog step that changed the game and
    /// at launch for a game with products and no file, or marked due (`requestSetIndex`). A game with no entry has no
    /// index yet. Observed: the Sets screen reads it.
    private(set) var setIndexes: [String: SetIndex] = [:]
    /// Goes up for a game each time this run sets an index of it (the launch's read of its file, `scanSetIndex`), so the
    /// Sets list makes its rows again (`SetsKey`) without comparing two indexes of a whole game.
    private(set) var setIndexVersions: [String: Int] = [:]
    /// The games whose set index is being read or made (final fix A4): every game until the launch has read the files
    /// and asked for its scans, then the games queued or scanning. Observed: the Sets list's note says so.
    private(set) var setIndexesInWork: Set<String> = Set(Games.all.map(\.id))

    // MARK: Price history (phase 5A task 4; the logic is in AppModel+History.swift)
    // Stored properties cannot live in an extension: they stay here, internal so that file can set them.

    /// Each followed game's price history in memory (H2), as its file holds it (or as the last pass made it). Observed.
    var histories: [String: PriceHistory] = [:]
    /// Goes up for a game each time its history in memory changes (a read, a pass), so views read it again. Observed.
    private(set) var historyVersions: [String: Int] = [:]
    /// The games whose history file must not be rewritten in this run (H3): `.newerVersion` or `.notDownloaded`, from the
    /// last read of the file. Observed (`historyState`).
    var historyBlocked: [String: HistoryState] = [:]
    /// Each game's tracked product ids as the last prepared pass computed them (H6). Observed (`historyState`).
    var historyTracked: [String: Set<Int>] = [:]
    /// What the last read of each game's history file found in `historyFolder`; no entry: not read yet (or forgotten).
    /// Invariant: a game is written only from a read that no report has followed. Every report of the game's file
    /// (`historyReports`) either marks it stale or forgets this entry; a read or a write is recorded here only when no
    /// report came during it (else the entry is forgotten, and the game marked stale while the gates hold).
    @ObservationIgnored var historyOnDisk: [String: HistoryOnDisk] = [:]
    /// Per game, the reports of its history file in this folder (H11), whatever the gates said. A read or a write takes
    /// its count before the await and is recorded only when it is unchanged after it. Reset by `dropHistory`.
    @ObservationIgnored var historyReports: [String: Int] = [:]
    /// Games whose history in memory differs from their file after a write that failed: the next pass writes them.
    @ObservationIgnored var historyUnwritten: Set<String> = []
    /// Games whose history file changed on disk (another device, H11, or a creating write that met a file): the queue
    /// reads it again (a check, or the next pass's first step); a running pass keeps nothing of them.
    @ObservationIgnored var historyStale: Set<String> = []
    /// The archive days that could not be read in this run (H8): not tried again.
    @ObservationIgnored var historyFailedDays: Set<String> = []
    /// The folder whose history files memory holds; a pass on another folder drops memory first.
    @ObservationIgnored var historyFolder: URL?
    /// The task that runs the passes, one at a time; nil while none runs.
    @ObservationIgnored var historyTask: Task<Void, Never>?
    /// A pass is asked for and has not started (a newer request replaces a queued one: it is one flag).
    @ObservationIgnored var historyQueued = false
    /// The wait of `historyQuietTime` after the last library change (H10); nil when none waits.
    @ObservationIgnored var historyQuietTask: Task<Void, Never>?
    /// The library version the change watcher saw last (`waitForHistory`); nil before it runs.
    @ObservationIgnored var historySeenVersion: Int?
    /// True once the launch's price step has ended (or, offline and with a store in memory, the launch has read prices
    /// from disk): passes run only from then on (H10), so a launch makes one pass with the day's archive.
    @ObservationIgnored var historyLaunchReady = false
    /// H10: how long a library change waits for the next one before it asks for a pass. Tests set 0.
    @ObservationIgnored var historyQuietTime: Duration = .seconds(3)
    /// Opens one day file for a pass (phase 5B task 3, K5: a pass reads day files only), given the `price-days` folder.
    /// Tests count the opens.
    @ObservationIgnored var historyDayReader: (URL) -> HistoryPass.Reader = HistoryPass.dayFileReader(in:)
    /// Reads one history file (every read goes through it: `readHistoryFile`). Tests count the reads.
    @ObservationIgnored var historyFileReader: HistoryFileReader = { game, folder in try HistoryFiles.read(game: game, in: folder) }
    #if DEBUG
    /// Test only: called with the games of a pass after their tracked printings are known, before the archives are read.
    @ObservationIgnored var historyPassHook: (@MainActor ([String]) async -> Void)?
    /// Test only: the passes that ran past the gates.
    @ObservationIgnored var historyPassCount = 0
    /// Test only: called on the main actor after each history file write of a pass, with its game.
    @ObservationIgnored var historyWriteHook: (@MainActor (String) async -> Void)?
    #endif

    /// The game's history in memory changed: `historyVersions` goes up (its setter stays private to this file).
    func historyChanged(_ game: String) { historyVersions[game, default: 0] += 1 }

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
    /// G11: the first-run question (which games, which roles) is to be answered: the folder was read, it is new (no game file
    /// of any known game) and this run asks (`Onboarding.isDue`). Decided only when a folder's read has ended (the launch's
    /// load, a folder switch: `decideOnboarding`), never by a reload or during a read, so the owner's folder never sees it
    /// (A30). While it is true nothing is downloaded or scanned (`catalogMayStart`) and no other sheet opens.
    private(set) var onboardingDue = false
    /// The onboarding sheet is presented: `onboardingDue`, once no folder sheet is on screen (two sheets never change places
    /// at once). It cannot be dismissed; "Continue" (`finishOnboarding`) closes it.
    private(set) var showsOnboarding = false
    /// Set by the window while the folder sheet is on screen, from its appearance until its `onDismiss`
    /// (`folderSheetClosed`): the onboarding sheet waits for it.
    @ObservationIgnored var folderSheetOnScreen = false
    /// "Collection Folder…" while the onboarding sheet is open: the folder sheet opens once that one has gone
    /// (`onboardingSheetClosed`).
    @ObservationIgnored private var folderAfterOnboarding = false
    /// True while "Continue" writes the profiles: a second click does nothing.
    private(set) var finishingOnboarding = false
    /// Final fix A2: why the last "Continue" could not finish (the folder is missing or not read, a write failed); the
    /// sheet shows it under its table and stays open, the gate stays closed. Nil otherwise.
    private(set) var onboardingProblem: String?
    /// The games whose file this question's "Continue" wrote: a later "Continue" (after a failed write) does not take
    /// them for a game file found in the folder.
    @ObservationIgnored private var onboardingWrote: Set<String> = []
    /// B5: the launch's local scans (filter lists, set indexes) ran while the question was due (offline, or with a store
    /// in memory: the launch does not wait for the gate): they run for the chosen games when the question closes.
    @ObservationIgnored private var scansWaitForAnswer = false
    /// "Import CSV…" asked for the system's file panel (`chooseCSVFile`).
    var choosesCSVFile = false
    /// The import the sheet shows (`ImportSheet`); nil while no import sheet is open.
    var importing: ImportModel?
    /// "New Deck…" (the sidebar, or a card page's "Add to deck") asked for its sheet (`NewDeckSheet`).
    var showsNewDeck = false
    /// "New Deck…" of a card page's "Add to deck": the card the new deck gets one copy of after Create. Nil when the
    /// sidebar opened the sheet; cleared when the sheet closes.
    var newDeckCard: DeckCardToAdd?
    /// The game the New Deck sheet was opened for (`openNewDeck`): it writes to that game or not at all (final fix A5).
    /// Nil while the sheet is closed.
    private(set) var newDeckGame: String?
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
            || onboardingDue || showsOnboarding
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
    /// Final fix A6: the ids of the followed games last known from the folder (`rememberFollowedGames`).
    private nonisolated static let followedGamesKey = "followedGames"
    /// The stored `followedGamesKey`, read once at launch; nil when none is stored.
    @ObservationIgnored private var knownFollowed: [String]?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogSync: CatalogSync
    @ObservationIgnored private let priceSync: PriceSync
    /// Phase 5B (K3): every archive is decoded through this one gate (the price step, a game turned on, the migration).
    @ObservationIgnored var archiveGate: ArchiveGate { priceSync.gate }
    /// Phase 5B: +1 per day file written in this run (set on the main actor after each call to the gate).
    private(set) var priceDaysVersion = 0
    /// K10: the launch's one clean-up of old day files, old archives and cut-short downloads; nil before the launch.
    @ObservationIgnored private(set) var priceDaysCleaning: Task<Void, Never>?
    /// K11: the archives on disk were migrated into day files in this run (once, after the launch's price step).
    @ObservationIgnored private var priceDaysMigrated = false
    #if DEBUG
    /// Test only: called on the main actor when the launch's migration starts.
    @ObservationIgnored var priceDaysMigrationHook: (@MainActor () async -> Void)?
    #endif
    @ObservationIgnored private let ygoLoader: YGOIndexLoader
    /// The clock (internal: the price history reads it too).
    @ObservationIgnored let now: () -> Date
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
    private(set) var catalogPending: Set<String> = [] {
        // H10: a game whose catalog settled may now get its price history (H7).
        didSet { if !oldValue.isSubset(of: catalogPending) { requestHistory() } }
    }
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
        knownFollowed = defaults.stringArray(forKey: Self.followedGamesKey)
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
        // H11: a history file another device changed.
        library.historyFileChanged = { [weak self] game in self?.historyFileChanged(game) }
    }

    /// True when no catalog step of this run is running or still to come for the game (`catalogPending`): the catalog
    /// then holds every product of the game it is going to hold in this run. A game that is not followed is settled (G5:
    /// it has no step, it blocks nothing).
    func catalogSettled(game: String) -> Bool { !catalogPending.contains(game) || !isFollowed(game) }

    // MARK: Followed games (G3–G6)

    /// The games the app shows and updates (G3, G5), in the games' order: from the profiles in the library once it has read
    /// its folder; every game before that (and while the folder is missing or switched), so nothing changes at launch for
    /// a folder whose games are all followed (A30). Observed: the game picker lists them.
    var followedGames: [GameDefinition] {
        guard library.isLoaded, !library.folderIsMissing else { return lastKnownFollowed }
        return library.followedGames.compactMap { Games.game($0) }
    }

    /// Final fix A6: the followed games last known (`knownFollowed`), for the times the folder cannot tell (before its
    /// read, during a folder switch, a missing folder, a run with no folder); every game when none is stored (a first
    /// launch of this build: A30).
    private var lastKnownFollowed: [GameDefinition] {
        let known = (knownFollowed ?? []).compactMap { Games.game($0) }
        return known.isEmpty ? Games.all : Games.all.filter { game in known.contains { $0.id == game.id } }
    }

    /// Keeps the followed games in the preferences (`followedGamesKey`) whenever the library knows them: read, the folder
    /// there, the first-run question not due (a new folder only seems to follow every game).
    private func rememberFollowedGames() {
        guard library.isLoaded, !library.folderIsMissing, !onboardingDue else { return }
        let ids = library.followedGames
        guard ids != knownFollowed else { return }
        knownFollowed = ids
        defaults.set(ids, forKey: Self.followedGamesKey)
    }

    func isFollowed(_ gameID: String) -> Bool { followedGames.contains { $0.id == gameID } }

    /// The games the sync, the scans and the price fill work on: the followed games, none while the first-run question is
    /// due (task 5 fix round 1 (e): a new folder "follows" every game until "Continue", and nothing may start for them).
    var syncedGames: [GameDefinition] { onboardingDue ? [] : followedGames }

    func isSynced(_ gameID: String) -> Bool { syncedGames.contains { $0.id == gameID } }

    // MARK: Roles (G7–G9)

    /// The game's profile as the library holds it (every member on before the folder is read).
    func profile(of gameID: String) -> GameProfile { library.profile(game: gameID) }

    /// The game's decks as every deck-derived number and view takes them (`GameSections.decks`): none without the player
    /// role. The file keeps them.
    func decksInPlay(game: String) -> [Deck] { GameSections.decks(library.decks(game: game), profile: profile(of: game)) }

    /// The followed games with the collector role (G8): the games whose set index is made.
    private var collectingGames: [String] {
        syncedGames.map(\.id).filter { GameSections.showsSets(profile(of: $0)) }
    }

    /// The games `applyRoles` last saw with the collector role; nil before the launch has read the folder.
    @ObservationIgnored private var lastCollecting: [String]?

    /// G7, G8, Review Focus 3: the roles of the game on screen, applied after a profile change (here or by a reload).
    /// - A screen of a role that is off (a deck page without the player role, Sets without the collector role) leaves to
    ///   the Collection, at its root (a switch made by code); the deck's search and the pages on its stack go with it.
    /// - Without the player role the sheets that only make sense with it close without writing: the sharing sheet, the
    ///   paste sheet, New Deck (and the paste it asked for), Rename Deck.
    /// - A game whose collector role was turned on gets its set index asked for when it is due or missing (its scans were
    ///   dropped meanwhile; the due mark stayed).
    /// A deck that is gone is not judged here: its page says "This deck was removed." (phase 3A).
    private func applyRoles() {
        let profile = profile(of: gameID)
        let shown = GameSections.screen(screen, profile: profile, deckExists: { _ in true })
        if shown != screen { showRoot(of: shown) }
        if !GameSections.showsDecks(profile) {
            closeDeckSheets()
            // B1: a sharing notice waiting behind another notice is not said without the role; the base stays.
            pendingHeld = nil
        }
        // While the first-run question is due nothing is asked for: the roles before it stay the base (fix round 1 (e)).
        guard !onboardingDue else { return }
        let collecting = collectingGames
        defer { lastCollecting = collecting }
        guard let last = lastCollecting else { return }
        for game in collecting where !last.contains(game) {
            if setIndexIsDue(game) {
                enqueueSetIndex(game, onlyWithProducts: false)
            } else if setIndexes[game] == nil {
                enqueueSetIndex(game, onlyWithProducts: true)
            }
        }
    }

    /// G6, the one gate of the sync's steps: they start once the followed games are known, after the library's first read
    /// of the folder (or once it found the folder missing: then every game counts as followed). With no folder chosen yet
    /// (the first-run folder sheet) nothing is downloaded, nor while the first-run question is due or open (G11): the
    /// catalogs of the chosen games download after "Continue".
    var catalogMayStart: Bool {
        !needsUserFolder && (library.isLoaded || library.folderIsMissing) && !onboardingDue
    }

    /// The followed games' ids that `profilesChanged` last saw on a loaded library; nil before the first.
    @ObservationIgnored private var lastFollowed: [String]?
    /// Games turned on whose catalog step is still to run (G5): `runTurnedOnGames` takes them, or a running sync's
    /// other-games step when it starts after they were turned on.
    @ObservationIgnored private var turnedOn: [String] = []
    /// The work a profile change started (prices from disk, the turned-on games' steps), each after the one before.
    @ObservationIgnored private var profileWork: Task<Void, Never>?
    /// True once the launch's sync has begun: before it, a game turned on is covered by that sync.
    @ObservationIgnored private var syncBegan = false

    /// The sheets that belong to one game's decks close without writing (A5, G7): the sharing sheet, the paste sheet, New
    /// Deck (and the paste it asked for), Rename Deck.
    private func closeDeckSheets() {
        if showsSharing { showsSharing = false }
        if pasting != nil { pasting = nil }
        if showsNewDeck { showsNewDeck = false }
        if newDeckCard != nil { newDeckCard = nil }
        if newDeckGame != nil { newDeckGame = nil }
        pendingPaste = nil
        if renamingDeck { renamingDeck = false }
    }

    /// Applies a profile change (the library's version moved; the model observes it, `watchProfiles`, and Settings or
    /// onboarding may call it too: a second call with nothing new does nothing).
    /// - G4: when the game on screen is not followed, the first followed game is shown, on its Collection (a switch made by
    ///   code).
    /// - G5: each game turned on gets its prices from the day's archive on disk (no download), its missing filter lists
    ///   and set index, and its catalog step at once (the day rules hold). A game turned off is only left alone: nothing
    ///   is fetched or removed.
    /// Nothing happens before the library has read its folder.
    func profilesChanged() {
        guard library.isLoaded else { return }
        rememberFollowedGames()
        let followed = followedGames.map(\.id)
        if !followed.contains(gameID) {
            gameID = GameSelection.shown(asked: gameID, followed: followed)
            showRoot(of: .collection)
            // A5: the old game's sheets close without writing; none is rebuilt for the new game.
            closeDeckSheets()
        }
        applyRoles()
        // Fix round 1 (e): while the first-run question is due no game is "turned on" (the folder only seems to follow
        // every game); the followed games before it stay the base, and closing the question calls this again.
        guard !onboardingDue else { return }
        guard let last = lastFollowed else {
            lastFollowed = followed
            return
        }
        guard followed != last else { return }
        lastFollowed = followed
        turnedOn.removeAll { !followed.contains($0) }
        let added = followed.filter { !last.contains($0) }
        guard !added.isEmpty else { return }
        for game in added where !turnedOn.contains(game) { turnedOn.append(game) }
        if canSync, !catalogWaits { catalogPending.formUnion(added) }
        for game in added where GameSections.showsSets(profile(of: game)) {
            if setIndexIsDue(game) {
                enqueueSetIndex(game, onlyWithProducts: false)
            } else if setIndexes[game] == nil {
                enqueueSetIndex(game, onlyWithProducts: true)
            }
        }
        let previous = profileWork
        let games = added.compactMap { Games.game($0) }
        profileWork = Task { [weak self] in
            await previous?.value
            await self?.fillPricesFromDisk(of: games)
            await self?.writeMissingFacetLists()
            await self?.runTurnedOnGames()
        }
    }

    /// Calls `profilesChanged` whenever the library's version (a change here, a reload, a load) moves, for as long as the
    /// model lives.
    private func watchProfiles() {
        let library = library
        let changes = Observations { (library.version, library.isLoaded) }
        Task { [weak self] in
            for await _ in changes { self?.profilesChanged() }
        }
    }

    /// G5: the prices of games turned on, from the day's archive when it is on disk already (none is downloaded).
    private func fillPricesFromDisk(of games: [GameDefinition]) async {
        let days = games.map { prices.day(game: $0.id) }
        let haveDay = days.contains(nil) ? nil : days.compactMap { $0 }.min()
        guard !games.isEmpty,
              let fresh = try? await priceSync.run(games: games, now: now(), haveDay: haveDay, download: false) else {
            await notePriceDays()
            return
        }
        await notePriceDays()
        takeNewerTables(fresh)
    }

    /// K4: the tables of the followed games whose day is newer than the table's day of that game (or that have none).
    private func takeNewerTables(_ tables: [String: GamePrices]) {
        for (game, table) in tables where isSynced(game) && isNewer(table, game: game) {
            try? prices.replace(game, with: table, paths: paths)
        }
    }

    private func isNewer(_ table: GamePrices, game: String) -> Bool {
        guard let have = prices.day(game: game) else { return true }
        return table.day > have
    }

    /// `priceDaysVersion` follows the gate's count of day files written in this run.
    private func notePriceDays() async {
        let written = await archiveGate.writtenCount
        if written > priceDaysVersion { priceDaysVersion = written }
    }

    /// K11, once per launch: every archive on disk in the window becomes its day file through the gate, newest first,
    /// after the launch's clean-up (K10); a decoded day's tables are taken only when newer (K4).
    private func migratePriceDays() async {
        guard !priceDaysMigrated else { return }
        priceDaysMigrated = true
        #if DEBUG
        await priceDaysMigrationHook?()
        #endif
        await priceDaysCleaning?.value
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: now()))
        await archiveGate.migrate(window: window, games: Games.all) { [weak self] _, decoded in
            await self?.tookMigratedDay(decoded)
        }
    }

    private func tookMigratedDay(_ decoded: ArchiveGate.Decoded) async {
        await notePriceDays()
        takeNewerTables(decoded.tables)
    }

    /// G5: the catalog steps of the games turned on, one after the other, when no sync runs (a running sync takes them at
    /// its end). Not before the launch's sync has begun (it covers them), and not when the app cannot sync.
    private func runTurnedOnGames() async {
        guard syncBegan, !isRunning else { return }
        while !turnedOn.isEmpty {
            let games = turnedOn.compactMap { Games.game($0) }.filter { isSynced($0.id) }
            turnedOn = []
            let ids = Set(games.map(\.id))
            guard canSync, catalogMayStart, !games.isEmpty else {
                catalogPending.subtract(ids)
                continue
            }
            isRunning = true
            // B4: a failure in the status line (the launch's price step or picture index) stays said.
            let earlier: String? = if case .failed(let text) = status { text } else { nil }
            let now = self.now()
            let held = await catalogHeld(now: now)
            catalogWaits = held
            // A7: Yu-Gi-Oh! turned on gets its picture index under that step's own once-a-day rule, after its catalog
            // step. While held there is no catalog step, but the index step still runs under its own rule (0 new sets:
            // it asks only for a missing or old index), as in a held sync.
            let indexGames = games.filter { $0.pictures == .ygoprodeck }
            if held {
                catalogPending.subtract(ids)
                let indexFailure = indexGames.isEmpty ? nil : await refreshYGOIndexIfNeeded(newSets: 0, now: now)
                isRunning = false
                if let earlier {
                    status = .failed(([earlier] + [indexFailure].compactMap { $0 }).joined(separator: " · "))
                } else {
                    status = indexFailure.map { .failed(StatusText.resetWaits + " · " + $0) } ?? .idle(StatusText.resetWaits)
                }
                continue
            }
            catalogPending.formUnion(ids)
            let result = await syncCatalog(of: games, now: now, rebuild: false)
            catalogPending.subtract(ids)
            let newSets = indexGames.reduce(0) { $0 + result.newSets[$1.id, default: 0] }
            let indexFailure = indexGames.isEmpty ? nil : await refreshYGOIndexIfNeeded(newSets: newSets, now: now)
            isRunning = false
            let pending = await rulesPendingCount(now: now)
            let done = StatusText.done(result: result, priceDay: prices.day(game: gameID), rulesPending: pending)
            let failures = [earlier, indexFailure].compactMap { $0 }
            if result.failedSetLists > 0 {
                status = .failed(([done] + failures).joined(separator: " · "))
            } else if !failures.isEmpty {
                status = .failed(failures.joined(separator: " · "))
            } else {
                status = .idle(done)
            }
        }
    }

    /// Returns once the sync may start (`catalogMayStart`).
    private func waitUntilCatalogMayStart() async {
        guard !catalogMayStart else { return }
        let changes = Observations { [weak self] in self?.catalogMayStart ?? true }
        for await may in changes where may { return }
    }

    #if DEBUG
    /// Test only: returns when the work of every profile change so far has ended.
    func waitForProfileWork() async {
        while let task = profileWork {
            await task.value
            if profileWork == task { return }
        }
    }
    #endif

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
        // The store is set aside at the next launch: no index scan of it runs on.
        cancelSetIndexes()
        cancelHistoryPass()
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
        // H11: the old folder's history leaves memory before the new folder is read; a running pass keeps nothing.
        historyFolderWillChange()
        await library.use(folder: folder)
        // In the same main-actor turn as the end of the read (no suspension since `isLoaded` was set): the gate never sees
        // the new folder read without its decision.
        decideOnboarding()
        rememberFollowedGames()
        requestHistory()
    }

    // MARK: Onboarding (G11)

    /// After a folder's read has ended (the launch's load, a folder switch): whether the first-run question is due there,
    /// and the sheet follows (it opens, or closes when the new folder has game files). The ledger's ruling: `hasGameFile`
    /// is read only when the library is loaded and the folder is not missing. While a read runs (`isLoaded` false, folder
    /// there) nothing changes: an open sheet is not dismissed by a load.
    private func decideOnboarding() {
        guard library.isLoaded || library.folderIsMissing else { return }
        let due = Onboarding.isDue(loaded: library.isLoaded && !library.folderIsMissing, hasGameFile: library.hasGameFile,
                                   isDebugBuild: Self.isDebugBuild, hasStore: options.storeRoot != nil,
                                   asked: options.onboarding)
        onboardingDue = due
        showsOnboarding = due && !folderSheetUp
        onboardingProblem = nil
        onboardingWrote = []
    }

    /// The folder sheet is on screen or asked for: the onboarding sheet waits.
    private var folderSheetUp: Bool { folderSheetOnScreen || needsUserFolder || showsFolderSheet }

    /// The folder sheet has gone (its `onDismiss`): the onboarding sheet opens now when it is due.
    func folderSheetClosed() {
        folderSheetOnScreen = false
        if onboardingDue, !folderSheetUp { showsOnboarding = true }
    }

    /// "Collection Folder…": the folder sheet; while the onboarding sheet is open, that one closes first and the folder
    /// sheet opens once it has gone (`onboardingSheetClosed`). Cancel there brings the question back (`folderSheetClosed`).
    func askForFolder() {
        if showsOnboarding {
            folderAfterOnboarding = true
            showsOnboarding = false
        } else {
            showsFolderSheet = true
        }
    }

    /// The onboarding sheet has gone (its `onDismiss`): the folder sheet "Collection Folder…" asked for opens now.
    func onboardingSheetClosed() {
        guard folderAfterOnboarding else { return }
        folderAfterOnboarding = false
        showsFolderSheet = true
    }

    /// "Continue" (G11): writes every game's profile (a ticked game as chosen; one not ticked not followed, both roles on;
    /// each its own file, so the next launch finds game files), waits for the writes, closes the sheet, opens the first
    /// followed game's Collection and lets the sync start (`catalogMayStart`). Nothing when no game is ticked, when the
    /// question is not due, or while a call runs.
    func finishOnboarding(_ draft: [String: GameProfile]) async {
        guard onboardingDue, !finishingOnboarding, Onboarding.canContinue(draft) else { return }
        finishingOnboarding = true
        defer { finishingOnboarding = false }
        // Fix round 1 (b): the folder is read again first (not memory). A game file that arrived since the first read
        // means the folder is not new: nothing is written, the question closes.
        await library.readAgain()
        guard onboardingDue else { return }
        // A game file this question did not write: the folder is not new (fix round 1 (b)).
        if foundGameFileNotWritten {
            closeOnboarding()
            return
        }
        // Final fix A2: a folder that cannot be read or written keeps the question open, with its problem, the gate closed.
        guard library.isLoaded, !library.folderIsMissing else {
            onboardingProblem = library.problem ?? "Reading your collection…"
            return
        }
        // A second "Continue" (after a failed write) writes only the games not written yet.
        for game in Games.all where !onboardingWrote.contains(game.id) {
            library.setProfile(Onboarding.written(draft[game.id]), game: game.id, writesKey: true)
        }
        await library.flush()
        // Follow-up 4: a folder switch closed the question meanwhile: the old folder's not-saved notices are not said.
        guard onboardingDue else {
            library.clearUnsavedProfileNotice()
            library.clearUnsavedChangeNotice()
            return
        }
        // The sheet says a failed write itself (below); the status line does not say it a second time.
        library.clearUnsavedProfileNotice()
        // B6: a file that appeared between the read and the write was read, not replaced: the folder has a game file.
        let appeared = library.unsavedChangeGames
        if !appeared.isEmpty {
            library.clearUnsavedChangeNotice()
            say(appeared.map(Self.answerNotSaved).joined(separator: " "))
        }
        // Follow-up 1: every game whose write succeeded is this question's, whatever the folder's state is now (a file
        // still to be created, or whose create failed, is in `creates`: `hasFile` is false for it).
        onboardingWrote.formUnion(Games.all.map(\.id).filter { library.hasFile(game: $0) && !appeared.contains($0) })
        if appeared.isEmpty, let problem = Games.all.lazy.compactMap({ self.library.problem(game: $0.id) }).first {
            onboardingProblem = problem
            return
        }
        let followed = followedGames.map(\.id)
        if let first = followed.first { gameID = first }
        showRoot(of: .collection)
        closeOnboarding()
    }

    /// Follow-up 1: the folder has a game file that this question did not write (`onboardingWrote`): it is not new. The one
    /// test of `finishOnboarding` and `reviseOnboarding`, so a partial "Continue" is never taken for a folder found.
    private var foundGameFileNotWritten: Bool {
        Games.all.contains { library.hasFile(game: $0.id) && !onboardingWrote.contains($0.id) }
    }

    /// B6: what the status line says for a game whose file appeared during "Continue" (there is nothing to do again).
    nonisolated static func answerNotSaved(_ game: String) -> String {
        "\(Games.game(game)?.name ?? game) was just read from your folder; your answer for it was not saved."
    }

    /// The question ends ("Continue", or a game file found meanwhile): the sheet closes, the gate opens, and the profiles
    /// are applied from the base before the question (`profilesChanged`).
    private func closeOnboarding() {
        showsOnboarding = false
        onboardingDue = false
        onboardingProblem = nil
        onboardingWrote = []
        profilesChanged()
        // H10: the chosen games' history (nothing was read or written while the question was due).
        requestHistory()
        // B5: the local scans an offline (or store-failure) launch left out while the question was due.
        guard scansWaitForAnswer else { return }
        scansWaitForAnswer = false
        let previous = profileWork
        profileWork = Task { [weak self] in
            await previous?.value
            await self?.writeMissingFacetLists()
            self?.requestMissingSetIndexes()
        }
    }

    /// Fix round 1 (a): while the question is due, a read that finds a game file (a reload, the watcher, the folder coming
    /// back) closes it: nothing is written, the gate opens. Revised in that direction only. Not during "Continue" (its own
    /// writes make the files).
    private func reviseOnboarding() {
        guard onboardingDue, !finishingOnboarding, library.isLoaded, !library.folderIsMissing, foundGameFileNotWritten else {
            return
        }
        closeOnboarding()
    }

    /// Calls `reviseOnboarding` whenever the library's read state or its game files change, for as long as the model lives.
    private func watchOnboarding() {
        let library = library
        let changes = Observations { (library.isLoaded, library.folderIsMissing, library.hasGameFile, library.version) }
        Task { [weak self] in
            for await _ in changes { self?.reviseOnboarding() }
        }
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
        // Final fix A3: a game whose file appeared before its write was not written: its not-saved sentence, and
        // "Imported: …" only for the games written (none: not at all).
        let appeared = library.unsavedChangeGames
        if !appeared.isEmpty { library.clearUnsavedChangeNotice() }
        var parts = appeared.map(UserLibrary.unsavedChangeText)
        let written = applied.games.filter { !appeared.contains($0) }
        if let problem = written.lazy.compactMap({ self.library.problem(game: $0) }).first {
            say((parts + [problem]).joined(separator: " "))
            return
        }
        if !written.isEmpty {
            let sale = library.saleNotice
            library.clearSaleNotice()
            parts.append("Imported: \(applied.summary(of: written))" + (sale.map { ". \($0)" } ?? ""))
        }
        if !parts.isEmpty { say(parts.joined(separator: " ")) }
    }

    // MARK: Pasting a deck

    /// "Paste…" of a deck page (`deckID`), or "Paste a deck…" of the New Deck sheet (nil: a new deck with `name` and
    /// `format`): opens the paste sheet on the game shown. Not while another sheet is open.
    func pasteDeck(into deckID: String?, name: String = "", format: String = "", text: String = "") {
        guard pasting == nil, importing == nil, !needsUserFolder, !showsFolderSheet, !onboardingDue,
              GameSections.showsDecks(profile(of: gameID)) else { return }
        let game = Games.game(gameID)
        pasting = PasteDeckModel(gameID: gameID, deckID: deckID, name: name, format: format, text: text, library: library,
                                 reader: reader,
                                 catalogSettled: { [weak self] game in self?.catalogSettled(game: game) ?? false },
                                 ygoType: { [weak self] name in game?.pictures == .ygoprodeck ? self?.ygoType(cardName: name) : nil },
                                 names: pasteNames,
                                 catalogVersion: { [weak self] in self?.catalogVersion ?? 0 })
    }

    /// "New Deck…" (the sidebar; a card page's "Add to deck" with its `card`): the sheet, bound to `game` (A5).
    func openNewDeck(game: String, card: DeckCardToAdd? = nil) {
        newDeckGame = game
        newDeckCard = card
        showsNewDeck = true
    }

    /// The New Deck sheet has gone: it forgets its game and card.
    func newDeckClosed() {
        newDeckGame = nil
        newDeckCard = nil
    }

    /// The New Deck sheet's Create: the deck (with `cards`) in `game`, its game at opening; nil, and nothing written, when
    /// that game's decks may not be written now (`decksWritable`: A5, B2) or the library refuses.
    func addNewDeck(game: String, name: String, format: String, cards: [DeckCard]) -> String? {
        guard decksWritable(game: game) else { return nil }
        return library.addDeck(game: game, name: name, format: format, cards: cards)
    }

    /// B2: whether a deck sheet's write action (New Deck's Create, the paste's apply, the sharing sheet's Done, Rename's
    /// Save, Delete Deck) may write to `game`: the game is followed and has the player role (`GameSections`). A click
    /// during a sheet's dismiss, after a role or game went off, writes nothing.
    func decksWritable(game: String) -> Bool {
        GameSections.decksWritable(profile(of: game), followed: library.followedGames.contains(game))
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
        // Fix round 1 (c): a change whose new file met a file that arrived meanwhile; it is said at once, as a lost sale.
        // Not while an import's result or "Continue" is to come: they say it their own way (final fix A3, B6).
        if let unsaved = library.unsavedChangeNotice, importsBeingSaid == 0, !finishingOnboarding {
            library.clearUnsavedChangeNotice()
            unsavedSaleSaid = unsaved
            say(unsaved)
            return
        }
        // A9: a profile change whose write failed (a Settings toggle), once; "Continue" says its own in its sheet.
        if let unsaved = library.unsavedProfileNotice, !finishingOnboarding {
            library.clearUnsavedProfileNotice()
            unsavedSaleSaid = unsaved
            say(unsaved)
            return
        }
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
            (library.saleNotice, library.unsavedSaleNotice, library.unsavedChangeNotice, library.unsavedProfileNotice,
             self?.importing == nil, self?.statusNotice)
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
        watchHistoryChanges()
        readSetIndexFiles()
        // Once per launch, with the window on screen: at background priority, off the main thread and off the picture
        // store's actor, so neither the window nor a picture load waits for it. Only the run's own picture folder.
        let pictures = pictures
        pictureCleaning = Task.detached(priority: .background) { pictures.clean() }
        // K10: once per launch, on the gate (off the main actor). A file of the archives folder counts as cut short only
        // when it was last changed before this launch (the real clock: file dates are real).
        let gate = archiveGate, window = PriceDay.window(endingOn: PriceDay.wanted(now: now())), launchedAt = Date()
        priceDaysCleaning = Task.detached(priority: .utility) { await gate.cleanUp(window: window, olderThan: launchedAt) }
        #if DEBUG
        // `-importCSV` (with `-store`): the sheet opens before the folder is read; the import waits for that read. With
        // `-onboarding YES` it waits for the onboarding decision instead, and opens no sheet under the question.
        if !options.onboarding { await openLaunchImport() }
        #endif
        await library.load()
        // G11: in the same turn as the end of the read, before anything waits on the gate.
        decideOnboarding()
        watchOnboarding()
        #if DEBUG
        if options.onboarding { await openLaunchImport() }
        #endif
        rememberFollowedGames()
        // G4: a stored or launched game that is not followed opens the first followed one (with a missing folder: of the
        // followed games last known, A6).
        if library.folderIsMissing { gameID = GameSelection.shown(asked: gameID, followed: followedGames.map(\.id)) }
        if library.isLoaded {
            let followed = followedGames.map(\.id)
            gameID = GameSelection.shown(asked: gameID, followed: followed)
            // With the question due the base is taken when it closes (`profilesChanged`), from the answer.
            if !onboardingDue {
                lastFollowed = followed
                lastCollecting = collectingGames
            }
        }
        watchProfiles()
        // A stored or launched deck screen whose deck is not in the game's file, or of a role that is off (G7, G8), opens
        // the Collection.
        let checked = Screen.checked(screen, profile: profile(of: gameID), deckIDs: library.decks(game: gameID).map(\.id))
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
        // G6: a run that syncs waits for the followed games (the folder's first read) before its scans and its steps. One
        // that does not sync goes on: its scans then cover every game while no folder is read.
        if canSync { await waitUntilCatalogMayStart() }
        // B5: offline (or with a store in memory) the launch does not wait for the gate: while the first-run question is
        // due its scans cover no game, and they run for the chosen games when it closes.
        if onboardingDue { scansWaitForAnswer = true }
        await writeMissingFacetLists()
        await setIndexRead?.value
        requestMissingSetIndexes()
        // H10: a run that does not sync has no price step; its passes read the archives on disk from here on. K11: the
        // archives on disk become day files first (it only reads the disk, as `fillPricesFromDisk` does: offline and
        // with a store in memory too).
        if !canSync {
            await migratePriceDays()
            historyPriceStepEnded(newDay: true)
        }
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

    #if DEBUG
    /// `-importCSV` (with `-store`): the import sheet on the file. With `-importCSVDelay` it opens that long after the
    /// launch, so a UI test can open a page first; it holds nothing.
    private func openLaunchImport() async {
        guard let file = options.launchImport(isDebugBuild: Self.isDebugBuild) else { return }
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

    /// A game with products and no facets file (a store migrated from phase 1 has none) gets its lists computed once
    /// (`storeFacetLists`), so the menus do not wait for a sync.
    private func writeMissingFacetLists() async {
        let chosen = gameID
        var wrote = false
        for game in syncedGames.sorted(by: { $0.id == chosen && $1.id != chosen }) where facetLists[game.id] == nil {
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

    // MARK: Set indexes (F3)

    /// A queued scan of a game's set index. `onlyWithProducts`: a launch's request for a game without a file, which is
    /// made only when the game has products (as the facets file at launch).
    private struct SetIndexRequest {
        let game: String
        let onlyWithProducts: Bool
    }

    /// The scans still to run, one per game (a newer request replaces a queued one of its game).
    @ObservationIgnored private var setIndexQueue: [SetIndexRequest] = []
    /// The task that runs the queue, one scan at a time; nil while the queue is empty and nothing runs.
    @ObservationIgnored private var setIndexTask: Task<Void, Never>?
    /// The game whose scan runs now; nil between scans.
    @ObservationIgnored private var scanningSetIndex: String?
    /// The launch's read of the `sets-<game>.json` files (A1), made by `launch()`; nil before it.
    @ObservationIgnored private var setIndexRead: Task<Void, Never>?
    /// True once the launch has read the files and asked for its scans: `setIndexesInWork` then follows the queue.
    @ObservationIgnored private var launchAskedForSetIndexes = false
    #if DEBUG
    /// Test only: called with the game before each scan (after a launch request's products check); a throw counts as a
    /// failed scan.
    @ObservationIgnored var setIndexScanHook: (@MainActor (String) async throws -> Void)?
    #endif

    /// The preferences key that marks a game's set index due (final fix A3): set when a catalog step stores, removes or
    /// fails the game's first set (`CatalogSync.run`'s `changing`) and when a step asks for the game's scan; removed when
    /// the game's index is stored. It outlives a quit, so the next launch scans the game although its file exists. In the
    /// preferences of `lastCatalogFetchDay` (with `-store`: the root's own). Its value is a new token at every mark, so a
    /// scan clears only the mark it started under, never one set while it ran.
    nonisolated static func setIndexDueKey(_ game: String) -> String { "setIndexDue-\(game)" }

    /// Marks the game's set index due with a new token (any thread: the catalog step calls it from its actor).
    nonisolated static func markSetIndexDue(_ game: String, in defaults: UserDefaults) {
        SetIndexDueMarks(defaults: defaults).mark(game)
    }

    /// True when the game's set index is marked due (A3).
    func setIndexIsDue(_ game: String) -> Bool { defaults.string(forKey: Self.setIndexDueKey(game)) != nil }

    /// A3: the mark a scan stored an index under while the game's catalog step was still to come or running: the step
    /// may change the game after the scan's read, so the mark stays until the step ends without a change of the game
    /// (`settleHeldSetIndexMarks`) or a later scan clears it.
    @ObservationIgnored private var heldSetIndexMarks: [String: String] = [:]

    /// After a catalog step: a game the step did not change whose index was stored in this run under the mark that is
    /// still set (and no scan of it is queued or running) is up to date: its mark goes.
    private func settleHeldSetIndexMarks(of games: [GameDefinition], changed: Set<String>) {
        for game in games.map(\.id) where !changed.contains(game) {
            guard let held = heldSetIndexMarks.removeValue(forKey: game),
                  held == defaults.string(forKey: Self.setIndexDueKey(game)),
                  !setIndexQueue.contains(where: { $0.game == game }), scanningSetIndex != game else { continue }
            defaults.removeObject(forKey: Self.setIndexDueKey(game))
        }
    }

    /// True while the game's set index is being read or made (A4): the launch has not read the files and asked for its
    /// scans yet, or the game's scan is queued or running.
    func setIndexInWork(_ game: String) -> Bool { setIndexesInWork.contains(game) }

    /// A1: the launch reads the four files off the main actor (decoding Magic's takes about 20–60 ms); the window does
    /// not wait for it. Each index read is set, and its version raised, on the main actor.
    private func readSetIndexFiles() {
        guard setIndexRead == nil else { return }
        let paths = paths
        setIndexRead = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                var found: [String: SetIndex] = [:]
                for game in Games.all {
                    if let index = SetIndex.read(paths.sets(game.id)) { found[game.id] = index }
                }
                return found
            }.value
            // A scan stored this run is newer than its file (none runs before the launch asks for one; kept as a rule).
            for (game, index) in read where self?.setIndexes[game] == nil {
                self?.setIndexes[game] = index
                self?.setIndexVersions[game, default: 0] += 1
            }
        }
    }

    /// A launch: every game without a set index gets one made when it has products (F3), and every game marked due (A3)
    /// gets its scan. Nothing waits for it.
    private func requestMissingSetIndexes() {
        for game in syncedGames where GameSections.showsSets(profile(of: game.id)) {
            if setIndexIsDue(game.id) {
                enqueueSetIndex(game.id, onlyWithProducts: false)
            } else if setIndexes[game.id] == nil {
                enqueueSetIndex(game.id, onlyWithProducts: true)
            }
        }
        launchAskedForSetIndexes = true
        updateSetIndexesInWork()
    }

    /// Asks for a scan of the game's set index after a catalog step that changed it, and marks it due until the index is
    /// stored (A3). It runs in the model's own task, after the scans before it (the game on screen first), on throwaway
    /// stores: nothing waits for it.
    func requestSetIndex(_ game: String) {
        Self.markSetIndexDue(game, in: defaults)
        enqueueSetIndex(game, onlyWithProducts: false)
    }

    /// Drops every queued scan and stops the running one; the stopped scan stores nothing (its due mark stays).
    func cancelSetIndexes() {
        setIndexQueue = []
        setIndexTask?.cancel()
        updateSetIndexesInWork()
    }

    #if DEBUG
    /// Test only: returns when the launch's read of the files is done and no set index scan is queued or running.
    func waitForSetIndexes() async {
        await setIndexRead?.value
        while let task = setIndexTask { await task.value }
    }
    #endif

    /// No scan while the store runs in memory (its file could not be opened, `storeFailure`): the empty store would write
    /// an empty index over a good file and clear the mark. The marks stay for a launch on an open store.
    private func enqueueSetIndex(_ game: String, onlyWithProducts: Bool) {
        guard storeFailure == nil else { return }
        setIndexQueue.removeAll { $0.game == game }
        setIndexQueue.append(SetIndexRequest(game: game, onlyWithProducts: onlyWithProducts))
        updateSetIndexesInWork()
        runSetIndexes()
    }

    /// `setIndexesInWork` from the queue and the running scan, once the launch has asked for its scans; set only when it
    /// changes, so the Sets list is told only then.
    private func updateSetIndexesInWork() {
        guard launchAskedForSetIndexes else { return }
        let now = Set(setIndexQueue.map(\.game) + [scanningSetIndex].compactMap { $0 })
        if now != setIndexesInWork { setIndexesInWork = now }
    }

    /// The next request: the game on screen when it is queued, else the oldest. A request of a game that is not followed
    /// (any more, G5) or has no collector role (G8) is dropped: its due mark stays until the game is followed and collected
    /// again (`profilesChanged`, `applyRoles`).
    private func takeSetIndexRequest() -> SetIndexRequest? {
        setIndexQueue.removeAll { !isSynced($0.game) || !GameSections.showsSets(profile(of: $0.game)) }
        guard let i = setIndexQueue.firstIndex(where: { $0.game == gameID }) ?? setIndexQueue.indices.first else { return nil }
        return setIndexQueue.remove(at: i)
    }

    private func runSetIndexes() {
        guard setIndexTask == nil, !setIndexQueue.isEmpty else { return }
        setIndexTask = Task { [weak self] in
            while !Task.isCancelled, let self, let request = self.takeSetIndexRequest() {
                self.scanningSetIndex = request.game
                await self.scanSetIndex(request)
                self.scanningSetIndex = nil
                self.updateSetIndexesInWork()
            }
            // A cancel leaves its task here; requests made since then get a new one.
            self?.scanningSetIndex = nil
            self?.setIndexTask = nil
            self?.updateSetIndexesInWork()
            self?.runSetIndexes()
        }
    }

    /// One scan on throwaway stores (never `reader`): keeps the index, then writes `sets-<game>.json` off the main actor
    /// (A1) and clears the game's due mark once the file is written (A3): the mark it started under only, and not while
    /// the game's catalog step is still to come or running (then `heldSetIndexMarks`). A failed or cancelled scan keeps the
    /// old index, the old file and the mark; a failed write (atomic) leaves the old file and the mark.
    private func scanSetIndex(_ request: SetIndexRequest) async {
        let game = request.game, dueKey = Self.setIndexDueKey(game)
        let mark = defaults.string(forKey: dueKey)
        if request.onlyWithProducts {
            let scan = CatalogStore(modelContainer: store.modelContainer)
            guard (try? await scan.progress(game: game))?.fetched ?? 0 > 0 else { return }
        }
        do {
            #if DEBUG
            try await setIndexScanHook?(game)
            #endif
            let index = try await CatalogStore.setIndex(game: game, container: store.modelContainer)
            guard !Task.isCancelled else { return }
            setIndexes[game] = index
            setIndexVersions[game, default: 0] += 1
            let file = paths.sets(game)
            let written = await Task.detached(priority: .utility) { (try? index.write(to: file)) != nil }.value
            guard written, let mark, defaults.string(forKey: dueKey) == mark,
                  !setIndexQueue.contains(where: { $0.game == game }) else { return }
            if catalogPending.contains(game) {
                heldSetIndexMarks[game] = mark
            } else {
                defaults.removeObject(forKey: dueKey)
            }
        } catch {
            return
        }
    }

    /// `-card <productId>`: switches to the product's game and to All cards (card pages live there), and asks the window
    /// to open its card page.
    private func openLaunchCard() async {
        guard let id = options.card, let product = try? await reader.product(id),
              let game = Games.game(product.gameID), isFollowed(game.id) else { return }
        gameID = game.id
        showRoot(of: .allCards)
        pendingCard = CardTarget(gameID: game.id, cardKey: CardName.searchKey(product.cardName), startProductID: product.productID)
    }

    /// False offline and with a store that cannot be opened: then nothing is downloaded.
    var canSync: Bool { !options.offline && storeFailure == nil }

    /// Does nothing when the app cannot sync, or while a sync runs. Its catalog steps wait as `catalogHeld` says.
    func refresh(rebuild: Bool) async {
        // Fix round 1 (d): not before the folder is read and not while the first-run question is due ("Try again" too).
        guard canSync, catalogMayStart else { return }
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

    /// The game on screen gets its cards and prices first; Magic and Yu-Gi-Oh! take many minutes. Only the followed games
    /// (G5); games turned on meanwhile get their steps at the end (`runTurnedOnGames`).
    private func sync(rebuild: Bool) async {
        guard !isRunning else { return }
        await syncFollowedGames(rebuild: rebuild)
        await runTurnedOnGames()
    }

    private func syncFollowedGames(rebuild: Bool) async {
        isRunning = true
        syncBegan = true
        defer {
            isRunning = false
            // Games turned on during this sync, after its other-games step began, are still due.
            catalogPending = catalogWaits ? [] : Set(turnedOn)
        }
        let now = self.now()
        // A held sync skips only the catalog steps: the price and index steps keep their own once-a-day rules.
        let held = await catalogHeld(now: now)
        catalogWaits = held
        catalogPending = held ? [] : Set(syncedGames.map(\.id))
        let chosen = game
        turnedOn.removeAll { $0 == chosen.id }
        var first = SyncResult(fetched: 0, failed: 0, newSets: [:]), rest = first
        // The game on screen is followed (G4); with the followed games last known (A6) it is checked again.
        if !held, isSynced(chosen.id) {
            first = await syncCatalog(of: [chosen], now: now, rebuild: rebuild)
        }
        catalogPending.remove(chosen.id)
        let dayBefore = syncedGames.map { prices.day(game: $0.id) }
        let priceFailure = await syncPrices(now: now)
        if !held {
            // The followed games of this moment: a game turned on since the launch is among them.
            let others = syncedGames.filter { $0.id != chosen.id }
            turnedOn.removeAll { id in others.contains { $0.id == id } }
            rest = await syncCatalog(of: others, now: now, rebuild: rebuild)
            catalogPending = Set(turnedOn)
        }
        // K11: once per launch, after the price step and the other games' catalog steps (review 1: the first launch's
        // catalogs do not wait for it), and before the history pass is asked for.
        await migratePriceDays()
        // H10: the launch's price step, and any later one that brought a new day, ask for a pass.
        historyPriceStepEnded(newDay: syncedGames.map { prices.day(game: $0.id) } != dayBefore)
        let result = SyncResult(fetched: first.fetched + rest.fetched, failed: first.failed + rest.failed,
                                failedSetLists: first.failedSetLists + rest.failedSetLists,
                                removedSets: first.removedSets + rest.removedSets,
                                newSets: first.newSets.merging(rest.newSets, uniquingKeysWith: +))
        // The new sets of the game whose pictures come from YGOPRODeck: the index maps their printings to pictures. No
        // index request while that game is not followed (G5).
        let indexGames = syncedGames.filter { $0.pictures == .ygoprodeck }
        let indexSets = indexGames.reduce(0) { $0 + result.newSets[$1.id, default: 0] }
        let indexFailure = indexGames.isEmpty ? nil : await refreshYGOIndexIfNeeded(newSets: indexSets, now: now)
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

    /// Sets of every followed game that are stored under older rules and were fetched today: they wait for the next UTC
    /// day.
    private func rulesPendingCount(now: Date) async -> Int {
        var count = 0
        for game in syncedGames {
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
        let marks = SetIndexDueMarks(defaults: defaults)
        async let result = Self.run(catalogSync, games: games, now: now, rebuild: rebuild, marks: marks, reportingTo: sink)
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
            let changed = games.filter { done.removedSets > 0 || touched.contains($0.id) }
            for game in changed { _ = await storeFacetLists(of: game) }
            // The set indexes follow in the model's own task: neither the menus nor the settled state wait for them.
            for game in changed { requestSetIndex(game.id) }
            catalogVersion += 1
            filtersVersion += 1
            settleHeldSetIndexMarks(of: games, changed: Set(changed.map(\.id)))
        } else {
            settleHeldSetIndexMarks(of: games, changed: [])
        }
        if done.fetched > 0 { defaults.set(SyncPlan.utcDay(now), forKey: Self.lastFetchDayKey) }
        return done
    }

    /// The step itself, off the main actor. A game's set index is marked due (A3) before the step stores or fails its
    /// first set, and after a removal: a quit during the step leaves the mark for the next launch.
    private nonisolated static func run(_ sync: CatalogSync, games: [GameDefinition], now: Date, rebuild: Bool,
                                        marks: SetIndexDueMarks,
                                        reportingTo sink: AsyncStream<SyncProgress>.Continuation) async -> SyncResult {
        defer { sink.finish() }
        return await sync.run(games: games, now: now, rebuild: rebuild, changing: { marks.mark($0) }) { sink.yield($0) }
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
        // G5: the followed games only; the archive is downloaded once for them.
        let games = syncedGames
        let days = games.map { prices.day(game: $0.id) }
        let haveDay = days.contains(nil) ? nil : days.compactMap { $0 }.min()
        do {
            let fresh = try await priceSync.run(games: games, now: now, haveDay: haveDay)
            await notePriceDays()
            if let fresh {
                // K4: a table takes a day only when it is newer than the table's day of that game.
                for (game, table) in fresh where isNewer(table, game: game) {
                    try prices.replace(game, with: table, paths: paths)
                }
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
        if let error = error as? ArchiveGateError {
            switch error {
            case .noArchive(let day): return "no archive of \(day)"
            case .failedBefore(let day): return "the archive of \(day) could not be read"
            case .unreadableDayFile(let day): return "the price day file of \(day) could not be read"
            case .readBackMismatch(let day): return "the price day file of \(day) did not read back"
            }
        }
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

/// The set indexes' due marks (phase 4A final fix A3) for the catalog step, which runs off the main actor. `UserDefaults`
/// is thread-safe (Apple's documentation) but not declared `Sendable`: this wrapper only sets a key.
nonisolated struct SetIndexDueMarks: @unchecked Sendable {
    let defaults: UserDefaults

    /// Marks the game's index due with a new token.
    func mark(_ game: String) {
        defaults.set(UUID().uuidString, forKey: AppModel.setIndexDueKey(game))
    }
}
