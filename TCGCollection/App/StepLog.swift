import Foundation

/// Phase 6B (A65): the file a step line names. Only its kind and its game id: never its path.
nonisolated enum StepLogFile: Sendable, Equatable {
    case game(String)
    case history(String)
    case settings

    /// The known file of the user folder named `name` (`<game>.json`, `<game>.prices.json`, `settings.json`), else nil.
    init?(named name: String) {
        if let game = HistoryFiles.gameID(ofFileNamed: name) {
            self = .history(game)
        } else if let game = UserFiles.gameID(ofFileNamed: name) {
            self = .game(game)
        } else if name == UserFiles.settingsName {
            self = .settings
        } else {
            return nil
        }
    }

    var isGameFile: Bool {
        if case .game = self { true } else { false }
    }
}

/// Phase 6B (A65): one event of the app's steps, for the device run (Claude reads the lines over the cable). Its values
/// are game ids, day strings, counts of sets, days and files, and durations only: no card name, collection count, file
/// content, folder path or account.
nonisolated enum StepLogEvent: Sendable, Equatable {
    enum Platform: String, Sendable { case mac, iphone }
    enum Build: String, Sendable { case debug, release }
    enum Result: String, Sendable { case ok, failed, cut }
    enum BackfillResult: String, Sendable { case done, cut, stopped }

    /// The app's launch began.
    case launch(platform: Platform, build: Build)
    /// The user folder's first read ended: the games with a file read, those only in iCloud, the time.
    case folderRead(games: Int, notDownloaded: Int, seconds: Double)
    /// The user folder's first read found no folder.
    case folderMissing
    /// A known file of the folder is only an iCloud placeholder.
    case fileNotDownloaded(file: StepLogFile)
    /// A file that was only in iCloud is on the device now.
    case fileArrived(file: StepLogFile)
    /// A catalog step began (one line per step, never per set).
    case catalogStart(games: [String])
    /// A catalog step ended: the sets fetched and failed, the games whose set list could not be read, whether the
    /// background cut it.
    case catalogEnd(games: [String], sets: Int, failed: Int, listsFailed: Int, cut: Bool, seconds: Double)
    /// The price step began.
    case priceStart
    /// The price step ended: the price day of the game on screen.
    case priceEnd(day: String?, result: Result, seconds: Double)
    /// The launch's move of the archives on disk into day files began.
    case migrationStart(archives: Int)
    /// It ended: the days decoded.
    case migrationEnd(days: Int, seconds: Double)
    /// The 90-day download began with this many missing days.
    case backfillStart(days: Int)
    /// Every 10 days of it.
    case backfillProgress(done: Int, total: Int)
    /// It ended.
    case backfillEnd(done: Int, total: Int, result: BackfillResult)
    /// The iPhone's background task around the library's flush began (A64).
    case backgroundSaveStart
    /// Its time ran out before the flush ended.
    case backgroundSaveExpired
    /// The flush ended.
    case backgroundSaveEnd(seconds: Double)
    /// The app went to the background: whether a sync or the 90-day download was cut.
    case background(syncCut: Bool, backfillCut: Bool)
    /// The app is active again after the background.
    case resume
}

/// Phase 6B (A65): the step log. One line per event, `tcg: <step>[ key=value]…`, to standard output in every build.
nonisolated enum StepLog {
    /// The line of `event`. Pure. A game id not in `Games.all` reads `unknown`; a day that is not `yyyy-MM-dd` too.
    static func line(_ event: StepLogEvent) -> String {
        let (step, pairs) = parts(event)
        return (["tcg: " + step] + pairs.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
    }

    /// Prints the line of `event` with one unbuffered write (a pipe would hold a buffered `print` back), from any thread.
    static func note(_ event: StepLogEvent) {
        FileHandle.standardOutput.write(Data((line(event) + "\n").utf8))
    }

    private static func parts(_ event: StepLogEvent) -> (String, [(String, String)]) {
        switch event {
        case .launch(let platform, let build):
            ("launch", [("platform", platform.rawValue), ("build", build.rawValue)])
        case .folderRead(let games, let notDownloaded, let seconds):
            ("folder-read", [("games", count(games)), ("not-downloaded", count(notDownloaded)), ("seconds", duration(seconds))])
        case .folderMissing:
            ("folder-missing", [])
        case .fileNotDownloaded(let file):
            ("file-not-downloaded", fileParts(file))
        case .fileArrived(let file):
            ("file-arrived", fileParts(file))
        case .catalogStart(let games):
            ("catalog-start", [("games", gameList(games))])
        case .catalogEnd(let games, let sets, let failed, let listsFailed, let cut, let seconds):
            ("catalog-end", [("games", gameList(games)), ("sets", count(sets)), ("failed", count(failed)),
                             ("lists-failed", count(listsFailed)), ("cut", cut ? "yes" : "no"),
                             ("seconds", duration(seconds))])
        case .priceStart:
            ("price-start", [])
        case .priceEnd(let day, let result, let seconds):
            ("price-end", [("day", day.map(self.day) ?? "none"), ("result", result.rawValue), ("seconds", duration(seconds))])
        case .migrationStart(let archives):
            ("migration-start", [("archives", count(archives))])
        case .migrationEnd(let days, let seconds):
            ("migration-end", [("days", count(days)), ("seconds", duration(seconds))])
        case .backfillStart(let days):
            ("backfill-start", [("days", count(days))])
        case .backfillProgress(let done, let total):
            ("backfill-progress", [("done", count(done)), ("total", count(total))])
        case .backfillEnd(let done, let total, let result):
            ("backfill-end", [("done", count(done)), ("total", count(total)), ("result", result.rawValue)])
        case .backgroundSaveStart:
            ("background-save-start", [])
        case .backgroundSaveExpired:
            ("background-save-expired", [])
        case .backgroundSaveEnd(let seconds):
            ("background-save-end", [("seconds", duration(seconds))])
        case .background(let syncCut, let backfillCut):
            ("background", [("sync", syncCut ? "cut" : "idle"), ("backfill", backfillCut ? "cut" : "idle")])
        case .resume:
            ("resume", [])
        }
    }

    private static func fileParts(_ file: StepLogFile) -> [(String, String)] {
        switch file {
        case .game(let id): [("game", game(id)), ("file", "game")]
        case .history(let id): [("game", game(id)), ("file", "history")]
        case .settings: [("file", "settings")]
        }
    }

    /// A known game id, else `unknown`: the only name a line may hold.
    private static func game(_ id: String) -> String {
        Games.all.contains { $0.id == id } ? id : "unknown"
    }

    private static func gameList(_ ids: [String]) -> String {
        ids.isEmpty ? "none" : ids.map(game).joined(separator: ":")
    }

    /// A UTC day string `yyyy-MM-dd`, else `unknown`.
    private static func day(_ text: String) -> String {
        text.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil ? text : "unknown"
    }

    private static func count(_ n: Int) -> String { String(max(0, n)) }

    /// Seconds with two decimals, `.` as the separator whatever the locale; 0 for a value that is not a finite duration.
    private static func duration(_ seconds: Double) -> String {
        String(format: "%.2f", seconds.isFinite && seconds > 0 ? seconds : 0)
    }

    /// A `Duration` in seconds, for the call sites.
    static func seconds(_ duration: Duration) -> Double {
        let (s, attoseconds) = duration.components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
