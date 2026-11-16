import Foundation
import Testing
@testable import TCGCollection2

/// Coordinated reads and writes in a temporary directory. The conflict path itself (`NSFileVersion` conflict versions) needs
/// two devices and iCloud: only its pure parts are tested here.
struct UserFilesTests {
    /// The brief's test; the folder is made by an explicit call now (fix round 1, item 4).
    @Test func readWriteAndMissing() throws {
        let file = tempDir().appending(path: "deep/riftbound.json")
        #expect(try UserFiles.read(file) == nil); try UserFiles.makeFolder(file.deletingLastPathComponent())
        try UserFiles.write(Data("{}".utf8), to: file); #expect(try UserFiles.read(file) == Data("{}".utf8))
    }

    @Test func aWriteReplacesTheWholeFile() throws {
        let file = tempDir().appending(path: "riftbound.json")
        try UserFiles.write(Data("a longer first text".utf8), to: file)
        try UserFiles.write(Data("short".utf8), to: file)
        #expect(try UserFiles.read(file) == Data("short".utf8))
    }

    /// A write never makes a folder: a folder that is gone stays gone (Review Focus 3). Only `makeFolder` makes one.
    @Test func aWriteNeverMakesAFolder() throws {
        let gone = tempDir().appending(path: "not-there")
        #expect(throws: (any Error).self) { try UserFiles.write(Data("{}".utf8), to: gone.appending(path: "riftbound.json")) }
        #expect(throws: (any Error).self) { try UserFiles.write(Data("{}".utf8), to: gone.appending(path: "deep/riftbound.json")) }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    /// iCloud keeps a file that is not downloaded as `.<name>.icloud`. Such a file is not missing: reading it as empty and
    /// writing would replace the owner's file.
    @Test func aFileThatIsNotDownloadedIsNotMissing() throws {
        let dir = tempDir()
        try Data().write(to: dir.appending(path: ".riftbound.json.icloud"))
        #expect(throws: UserFilesError.notDownloaded) { try UserFiles.read(dir.appending(path: "riftbound.json")) }
    }

    @Test func theNewestVersionWins() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func v(_ seconds: TimeInterval, _ text: String) -> (date: Date, data: Data) { (t.addingTimeInterval(seconds), Data(text.utf8)) }
        #expect(UserFiles.newest(of: [v(0, "current"), v(30, "b"), v(10, "c")]) == 1)
        #expect(UserFiles.newest(of: [v(60, "current"), v(30, "b")]) == 0)
        // A tie keeps the current version: nothing is rewritten for nothing.
        #expect(UserFiles.newest(of: [v(5, "current"), v(5, "b")]) == 0)
        #expect(UserFiles.newest(of: [v(0, "current")]) == 0)
    }

    /// Item 5 and 6: what this app may replace. A file that does not read as this version's game file is never replaced.
    @Test func whatThisAppMayNotRewrite() {
        #expect(UserFiles.refusal(Data(#"{"version":1,"collection":[]}"#.utf8)) == nil)
        #expect(UserFiles.refusal(Data("{}".utf8)) == nil)
        #expect(UserFiles.refusal(Data(#"{"version":2}"#.utf8)) == .notRewritable(newerVersion: true))
        for bytes in [#"{"version":"1"}"#, #"{"version":1.5}"#, #"{"collection":{"a":1}}"#, "[1]", "not json", ""] {
            #expect(UserFiles.refusal(Data(bytes.utf8)) == .notRewritable(newerVersion: false), "\(bytes)")
        }
    }

    /// Item 6, the decision of `resolveConflicts` (its `NSFileVersion` part needs two devices): when the current file is one
    /// this app must not rewrite, every version is left as it is (no replace, no backup, no "resolved" mark). Otherwise the
    /// newest wins.
    @Test func aConflictOverAFileThatMustNotBeRewrittenIsLeftAlone() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let mine = Data(#"{"version":1,"collection":[]}"#.utf8)
        for current in [#"{"version":2}"#, #"{"version":"1"}"#, #"{"collection":{"a":1}}"#, "[1]", "not json"] {
            #expect(UserFiles.conflictPlan([(t, Data(current.utf8)), (t.addingTimeInterval(30), mine)]) == .leave, "\(current)")
        }
        #expect(UserFiles.conflictPlan([(t, mine), (t.addingTimeInterval(30), mine)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([(t.addingTimeInterval(60), mine), (t.addingTimeInterval(30), Data(#"{"version":2}"#.utf8))]) == .settle(winner: 0))
    }

    /// Final fix A1: a version without data (it reads as a game file and every list is empty; a `profile` is not data)
    /// never wins over a version with data, whatever the dates. Among versions with data, or when none has data, the
    /// newest wins as before. A version that does not read as a game file keeps the rule by date (it is neither).
    @Test func aVersionWithoutDataNeverWinsAConflict() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let empty = Data(#"{"version":1,"collection":[],"profile":{"followed":false}}"#.utf8)
        let emptyAll = Data(#"{"version":1,"collection":[],"wanted":[],"forSale":[],"sold":null,"decks":[],"sharing":[]}"#.utf8)
        let bare = Data("{}".utf8)
        let full = Data(#"{"version":1,"collection":[{"productID":7,"finish":"Normal","count":2,"name":"x"}]}"#.utf8)
        let fullOther = Data(#"{"version":1,"collection":[],"wanted":[{"cardKey":"a","name":"A","count":1}]}"#.utf8)
        func at(_ seconds: TimeInterval, _ data: Data) -> (date: Date, data: Data) { (t.addingTimeInterval(seconds), data) }

        // Empty newer vs full older: the full one wins, whichever is current.
        #expect(UserFiles.conflictPlan([at(60, empty), at(0, full)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([at(0, full), at(60, empty)]) == .settle(winner: 0))
        #expect(UserFiles.conflictPlan([at(0, full), at(60, emptyAll)]) == .settle(winner: 0))
        #expect(UserFiles.conflictPlan([at(0, full), at(60, bare)]) == .settle(winner: 0))
        // Full newer vs empty older: the full one.
        #expect(UserFiles.conflictPlan([at(0, empty), at(60, full)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([at(60, full), at(0, empty)]) == .settle(winner: 0))
        // Two full: the newest.
        #expect(UserFiles.conflictPlan([at(0, full), at(60, fullOther)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([at(60, full), at(0, fullOther)]) == .settle(winner: 0))
        // Two empty: the newest.
        #expect(UserFiles.conflictPlan([at(0, empty), at(60, emptyAll)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([at(60, empty), at(0, emptyAll)]) == .settle(winner: 0))
        // Three versions: the newest of those with data, past newer empty ones.
        #expect(UserFiles.conflictPlan([at(90, empty), at(0, full), at(30, fullOther), at(120, emptyAll)]) == .settle(winner: 2))
        // A tie among versions with data keeps the earlier one.
        #expect(UserFiles.conflictPlan([at(90, empty), at(10, full), at(10, fullOther)]) == .settle(winner: 1))
        // A conflict version that does not read as a game file keeps the rule by date, beside empty and full versions.
        let newer = Data(#"{"version":2}"#.utf8)
        #expect(UserFiles.conflictPlan([at(60, empty), at(0, newer)]) == .settle(winner: 0))
        #expect(UserFiles.conflictPlan([at(0, empty), at(60, newer)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([at(0, full), at(60, newer)]) == .settle(winner: 1))
        #expect(UserFiles.conflictPlan([at(60, full), at(0, newer)]) == .settle(winner: 0))
        #expect(UserFiles.conflictPlan([at(90, empty), at(0, full), at(60, newer)]) == .settle(winner: 2))
        #expect(UserFiles.holdsData(newer) == nil)
        // A current file this app must not rewrite: every version is left, also beside an empty or a full version.
        #expect(UserFiles.conflictPlan([at(0, Data(#"{"version":2}"#.utf8)), at(60, empty)]) == .leave)
        #expect(UserFiles.conflictPlan([at(0, Data("not json".utf8)), at(60, full)]) == .leave)
        // An entry this build cannot parse, or one under count 1, is still data in the file.
        let raw = Data(#"{"version":1,"collection":[{"weird":true}]}"#.utf8)
        #expect(UserFiles.conflictPlan([at(60, empty), at(0, raw)]) == .settle(winner: 1))
        #expect(UserFiles.holdsData(full) == true); #expect(UserFiles.holdsData(fullOther) == true)
        #expect(UserFiles.holdsData(raw) == true)
        #expect(UserFiles.holdsData(empty) == false); #expect(UserFiles.holdsData(emptyAll) == false)
        #expect(UserFiles.holdsData(bare) == false)
        for list in ["forSale", "sold", "decks", "sharing"] {
            #expect(UserFiles.holdsData(Data(#"{"version":1,"\#(list)":[1]}"#.utf8)) == true, "\(list)")
        }
    }

    @Test func theBackupName() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10, minute: 15, second: 0)))
        let file = URL(fileURLWithPath: "/x/riftbound.json")
        #expect(UserFiles.conflictName(for: file, at: date) == "riftbound.conflict-2026-11-12-101500.json")
        #expect(UserFiles.conflictName(for: URL(fileURLWithPath: "/x/yu-gi-oh.json"), at: date) == "yu-gi-oh.conflict-2026-11-12-101500.json")
    }

    /// A second backup in the same second gets a number; an existing file is never overwritten.
    @Test func aBackupNeverOverwritesAFile() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10, minute: 15, second: 0)))
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        #expect(UserFiles.freeConflictURL(for: file, at: date).lastPathComponent == "riftbound.conflict-2026-11-12-101500.json")
        try Data("x".utf8).write(to: dir.appending(path: "riftbound.conflict-2026-11-12-101500.json"))
        #expect(UserFiles.freeConflictURL(for: file, at: date).lastPathComponent == "riftbound.conflict-2026-11-12-101500-2.json")
    }

    /// A local file has no conflict versions: nothing changes and no backup is made.
    @Test func noConflictMeansNoBackup() throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        try UserFiles.write(Data("{}".utf8), to: file)
        #expect(try UserFiles.resolveConflicts(of: file, now: Date()) == nil)
        #expect(try UserFiles.resolveConflicts(of: dir.appending(path: "cyberpunk.json"), now: Date()) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["riftbound.json"])
        #expect(try UserFiles.read(file) == Data("{}".utf8))
    }

    /// Only `<game id>.json` of a known game is a game file; a backup, a hidden file, `settings.json` and anything else are not.
    @Test func whichFilesAreGameFiles() {
        #expect(UserFiles.gameID(ofFileNamed: "riftbound.json") == "riftbound")
        #expect(UserFiles.gameID(ofFileNamed: "magic-the-gathering.json") == "magic-the-gathering")
        for name in ["riftbound.conflict-2026-11-12-101500.json", ".riftbound.json", ".riftbound.json.icloud", "settings.json",
                     "pokemon.json", "riftbound.JSON", "riftbound.json.tmp", "riftbound"] {
            #expect(UserFiles.gameID(ofFileNamed: name) == nil, "\(name)")
        }
    }

    /// The real presenter: a coordinated write (as iCloud makes when another device changed a file) reaches the callback.
    /// A hidden file, a file that is not JSON, a file in a subfolder and anything after `stop()` never do.
    @Test(.timeLimit(.minutes(1))) func thePresenterReportsACoordinatedWrite() async throws {
        let dir = tempDir()
        let (reported, sink) = AsyncStream.makeStream(of: String.self)
        let presenter = FolderPresenter()
        presenter.start(folder: dir) { url in sink.yield(url.lastPathComponent) }
        try UserFiles.makeFolder(dir.appending(path: "sub"))
        for name in [".hidden.json", "notes.txt", "sub/riftbound.json", "riftbound.json"] {
            try UserFiles.write(Data("{}".utf8), to: dir.appending(path: name))
        }
        var names: [String] = []
        for await name in reported {
            names.append(name)
            if name == "riftbound.json" { break }
        }
        #expect(Set(names) == ["riftbound.json"])
        presenter.stop()
        try UserFiles.write(Data("{}".utf8), to: dir.appending(path: "cyberpunk.json"))
        try await Task.sleep(for: .milliseconds(500))
        sink.finish()
        var late: [String] = []
        for await name in reported { late.append(name) }
        #expect(!late.contains("cyberpunk.json"), "\(late)")
    }

    @Test func settingsAreWrittenOnceAndKept() throws {
        let dir = tempDir(), settings = dir.appending(path: "settings.json")
        try UserFiles.writeSettingsIfMissing(in: dir)
        let written = try #require(try UserFiles.read(settings))
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object.count == 1 && object["version"] as? Int == 1)
        try UserFiles.write(Data(#"{"version":1,"games":["riftbound"]}"#.utf8), to: settings)
        try UserFiles.writeSettingsIfMissing(in: dir)
        #expect(try UserFiles.read(settings) == Data(#"{"version":1,"games":["riftbound"]}"#.utf8))
        // A folder that is not there is not made.
        let gone = dir.appending(path: "not-there")
        #expect(throws: (any Error).self) { try UserFiles.writeSettingsIfMissing(in: gone) }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }
}
