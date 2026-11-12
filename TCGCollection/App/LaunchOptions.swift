import Foundation

/// Launch flags for development and checks. Every flag takes a value, because macOS opens a
/// lone trailing argument as a file and shows no window. A flag without a value is ignored.
nonisolated struct LaunchOptions: Sendable {
    var storeRoot: URL?
    var game: String?
    var search: String?
    var card: Int?
    var offline = false
    var snapshot: URL?
    var catalogReport = false
    /// `-fixtures <dir>` (DEBUG): the network is served from the files in this folder.
    var fixtures: URL?
    /// `-fixtureDelay <milliseconds>` (DEBUG): every fixture products answer waits this long, so a UI test can act
    /// during a sync.
    var fixtureDelay: Int?
    /// `-writeDelay <milliseconds>` (DEBUG): every write of a game file waits this long first, so a UI test can quit
    /// while a write is still queued and see that quitting waits for it.
    var writeDelay: Int?
    /// `-askUserFolder YES` (DEBUG, with `-store`): the first-run folder sheet is shown although the run has a test root,
    /// and "Use iCloud Drive" uses `<root>/icloud/TCG Collection`. For the UI test of the sheet; `UserFolder.setup` ignores
    /// it in a Release build and without `-store`.
    var askUserFolder = false
    /// `-screen collection|all-cards`: the sidebar selection of this launch, for tests and snapshots. Any other value is
    /// ignored (the stored selection is used).
    var screen: Screen?
    /// `-importCSV <path>` (DEBUG, with `-store`): the import sheet opens on this file at launch, for the UI tests. Read
    /// it through `launchImport`, which ignores it where it is not allowed.
    var importCSV: URL?

    /// The file of `-importCSV` when this run may open it: a Debug build with `-store`. Otherwise nil: the flag is ignored
    /// (fails closed, as `-fixtures` does), so it never imports into the real collection.
    func launchImport(isDebugBuild: Bool) -> URL? {
        guard isDebugBuild, storeRoot != nil else { return nil }
        return importCSV
    }

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        storeRoot = value("-store").map { URL(fileURLWithPath: $0) }
        game = value("-game")
        search = value("-search")
        card = value("-card").flatMap { Int($0) }
        offline = value("-offline") == "YES"
        snapshot = value("-snapshot").map { URL(fileURLWithPath: $0) }
        catalogReport = value("-catalogReport") == "YES"
        fixtures = value("-fixtures").map { URL(fileURLWithPath: $0, isDirectory: true) }
        fixtureDelay = value("-fixtureDelay").flatMap { Int($0) }
        writeDelay = value("-writeDelay").flatMap { Int($0) }
        askUserFolder = value("-askUserFolder") == "YES"
        screen = value("-screen").flatMap(Screen.init(rawValue:))
        importCSV = value("-importCSV").map { URL(fileURLWithPath: $0) }
    }
}

/// The network a launch uses (I3). It fails closed: `-fixtures` never falls back to the real network.
nonisolated enum LaunchNetwork: Equatable, Sendable {
    /// tcgcsv, the price archive and the picture servers.
    case internet
    /// `-fixtures <dir>` in a Debug build with `-store`: every request is answered from the files of the folder.
    case fixtures(URL)
    /// `-fixtures` that cannot be honoured (not a Debug build, or no `-store`): no network at all, as `-offline YES`.
    /// `notice` is the one line the app prints.
    case offline(notice: String)

    static func choose(_ options: LaunchOptions, isDebugBuild: Bool) -> LaunchNetwork {
        guard let fixtures = options.fixtures else { return .internet }
        // A Release build has no fixture network; its bundle id is the installed app's.
        guard isDebugBuild else { return .offline(notice: "-fixtures works only in a Debug build: this run is offline") }
        // Fixture data goes only into a store of its own, never into the default one.
        guard options.storeRoot != nil else { return .offline(notice: "-fixtures needs -store <dir>: this run is offline") }
        return .fixtures(fixtures)
    }
}
