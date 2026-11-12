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
