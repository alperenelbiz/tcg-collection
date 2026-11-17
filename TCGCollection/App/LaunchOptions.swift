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
    /// `-fixtureDelay <milliseconds>` (DEBUG): every fixture products answer and every fixture archive answer waits this
    /// long, so a UI test can act during a sync or see the 90-day download's progress.
    var fixtureDelay: Int?
    /// `-writeDelay <milliseconds>` (DEBUG): every write of a game file waits this long first, so a UI test can quit
    /// while a write is still queued and see that quitting waits for it.
    var writeDelay: Int?
    /// `-askUserFolder YES` (DEBUG, with `-store`): the first-run folder sheet is shown although the run has a test root,
    /// and "Use iCloud Drive" uses `<root>/icloud/TCG Collection`. For the UI test of the sheet; `UserFolder.setup` ignores
    /// it in a Release build and without `-store`.
    var askUserFolder = false
    /// `-onboarding YES` (DEBUG, with `-store`): the first-run question (games and roles) is asked on a new folder, as in a
    /// Release build. `Onboarding.isDue` ignores it in a Debug build without `-store`, so the UI tests' fresh roots and a
    /// Debug run on its own folder never ask.
    var onboarding = false
    /// `-screen collection|wanted|for-sale|sets|all-cards|deck:<id>`: the sidebar selection of this launch, for tests and
    /// snapshots. Any other value is ignored (the stored selection is used); a deck the game's file lacks opens the
    /// Collection once the folder is read.
    var screen: Screen?
    /// `-importCSV <path>` (DEBUG, with `-store`): the import sheet opens on this file at launch, for the UI tests. Read
    /// it through `launchImport`, which ignores it where it is not allowed.
    var importCSV: URL?
    /// `-importCSVDelay <milliseconds>` (DEBUG, with `-importCSV`): the import sheet opens that long after the launch, so a
    /// UI test can open a page before it.
    var importCSVDelay: Int?
    /// `-pasteDeck <path>` (DEBUG, with `-store`, a readable file): the paste sheet opens at launch with the file's text, on
    /// the deck of `-screen deck:<id>` when the game has it, else for a new deck. For the UI tests, which must not write the
    /// Mac's pasteboard. Read it through `launchPaste`, which ignores it where it is not allowed.
    var pasteDeck: URL?
    /// `-exportPDF <path>` (DEBUG, with `-store` and `-screen wanted|for-sale`, a new `.pdf` file inside the root): that
    /// screen writes the PDF of its list there once it is read on a settled catalog with prices, for the UI tests, which
    /// do not drive the save panel. Read it through `launchPDF`, which ignores it where it is not allowed.
    var exportPDF: URL?
    /// `-pictureDelay <milliseconds>` (DEBUG, with `-fixtures`): every fixture picture answer waits this long, so a UI test
    /// can act while a PDF export waits for its pictures.
    var pictureDelay: Int?

    /// The file of `-importCSV` when this run may open it: a Debug build with `-store`. Otherwise nil: the flag is ignored
    /// (fails closed, as `-fixtures` does), so it never imports into the real collection.
    func launchImport(isDebugBuild: Bool) -> URL? {
        guard isDebugBuild, storeRoot != nil else { return nil }
        return importCSV
    }

    /// The file of `-pasteDeck` when this run may open it: a Debug build with `-store`, and a readable file (not a folder).
    /// Otherwise nil: the flag is ignored (fails closed, as `-importCSV`).
    func launchPaste(isDebugBuild: Bool) -> URL? {
        guard isDebugBuild, storeRoot != nil, let file = pasteDeck else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue,
              FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        return file
    }

    /// The PDF of `-exportPDF` when this run may write it: a Debug build with `-store`, `-screen wanted` or `for-sale`, and
    /// a `.pdf` file inside the store root (as `-askUserFolder` keeps its folders there) that does not exist yet. Otherwise
    /// nil: the flag is ignored (fails closed), so a run never writes outside its own root and never replaces a file (such
    /// as `<root>/user/<game>.json`).
    func launchPDF(isDebugBuild: Bool) -> LaunchPDF? {
        guard isDebugBuild, let root = storeRoot, let file = exportPDF, let screen, screen == .wanted || screen == .forSale,
              file.pathExtension.lowercased() == "pdf", UserFolder.isInside(file, root), !UserFolder.isInside(root, file),
              !FileManager.default.fileExists(atPath: file.path) else { return nil }
        return LaunchPDF(screen: screen, file: file)
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
        onboarding = value("-onboarding") == "YES"
        screen = value("-screen").flatMap(Screen.init(storedValue:))
        importCSV = value("-importCSV").map { URL(fileURLWithPath: $0) }
        importCSVDelay = value("-importCSVDelay").flatMap { Int($0) }
        exportPDF = value("-exportPDF").map { URL(fileURLWithPath: $0) }
        pasteDeck = value("-pasteDeck").map { URL(fileURLWithPath: $0) }
        pictureDelay = value("-pictureDelay").flatMap { Int($0) }
    }
}

/// `-exportPDF` as a run may honour it (`LaunchOptions.launchPDF`): the list screen that writes its PDF, and the file.
nonisolated struct LaunchPDF: Equatable, Sendable {
    let screen: Screen
    let file: URL
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
