import Foundation
import Testing
@testable import TCGCollection2

/// Keeps the callback of the library so a test can fire it, as `FolderPresenter` does when another device changed a file.
final class FakeWatcher: UserFileWatching, @unchecked Sendable {
    private(set) var started: [URL] = []
    private(set) var stops = 0
    private var changed: (@Sendable (URL) async -> Void)?

    func start(folder: URL, changed: @escaping @Sendable (URL) async -> Void) {
        started.append(folder)
        self.changed = changed
    }

    func stop() {
        stops += 1
        changed = nil
    }

    /// Returns when the library has handled the change.
    func fire(_ url: URL) async { await changed?(url) }
}

struct UserLibraryTests {
    private let riftFoil = PrintingKey(productID: 721334, finish: "Foil")

    @MainActor @Test func aChangeReachesTheFileAndSurvivesAReload() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(2, game: "riftbound", key: .init(productID: 721334, finish: "Foil"), name: "Dockside Lock-Up")
        lib.setCount(3, game: "riftbound", key: .init(productID: 721334, finish: "Foil"), name: ""); await lib.flush()
        let again = UserLibrary(folder: dir, watcher: nil); await again.load()
        #expect(again.rows(game: "riftbound") == [.init(productID: 721334, finish: "Foil", count: 3, condition: "", name: "Dockside Lock-Up")])
        #expect(again.rows(game: "cyberpunk").isEmpty); #expect(again.problem == nil)
    }

    @MainActor @Test func manyFastChangesAllReachTheFile() async throws {                 // Review Focus 5
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        for n in 1...50 { lib.setCount(n, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A") }
        await lib.flush(); #expect(try GameUserFile(data: try #require(try UserFiles.read(dir.appending(path: "riftbound.json")))).collection.first?.count == 50)
    }

    /// Changes to two games, interleaved: each file ends with its own last state.
    @MainActor @Test func interleavedChangesToTwoGamesEndInTheirLastStates() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        for n in 1...20 {
            lib.setCount(n, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A")
            lib.setCount(100 + n, game: "yu-gi-oh", key: .init(productID: 2, finish: "Normal"), name: "B")
        }
        lib.setCount(0, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "")
        await lib.flush()
        #expect(try stored(dir, "riftbound").isEmpty)
        #expect(try stored(dir, "yu-gi-oh").map(\.count) == [120])
    }

    @MainActor @Test func aChangeFromAnotherDeviceIsLoaded() async throws {
        let dir = tempDir(), watcher = FakeWatcher(); let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        var other = GameUserFile(); other.collection = [.init(productID: 5, finish: "Normal", count: 1, condition: "", name: "B")]
        try UserFiles.write(try other.data(), to: dir.appending(path: "yu-gi-oh.json")); let before = lib.version
        await watcher.fire(dir.appending(path: "yu-gi-oh.json"))
        #expect(lib.rows(game: "yu-gi-oh").map(\.productID) == [5]); #expect(lib.version > before)
    }

    /// The same with the real `FolderPresenter`: another process's coordinated write reaches memory; our own write bumps
    /// nothing.
    @MainActor @Test(.timeLimit(.minutes(1))) func theRealPresenterReloadsAChangedFile() async throws {
        let dir = tempDir(), watcher = FolderPresenter()
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        defer { watcher.stop() }
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        var other = GameUserFile(); other.collection = [.init(productID: 5, finish: "Normal", count: 1, condition: "", name: "B")]
        try UserFiles.write(try other.data(), to: dir.appending(path: "yu-gi-oh.json"))
        while lib.rows(game: "yu-gi-oh").isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let after = lib.version
        try await Task.sleep(for: .seconds(2)); await lib.flush()          // the notice of our own riftbound write, if late
        #expect(lib.version == after); #expect(lib.rows(game: "riftbound").map(\.count) == [1])
    }

    @MainActor @Test func aMissingFolderIsSaidAndNothingIsWritten() async throws {         // Review Focus 3
        let gone = tempDir().appending(path: "not-there"); let lib = UserLibrary(folder: gone, watcher: nil); await lib.load()
        #expect(lib.problem?.contains("not-there") == true)
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A"); await lib.flush()
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    /// The exact text, the folder stays set, and a change is refused (not shown as if it were kept).
    @MainActor @Test func aMissingFolderRefusesChanges() async throws {
        let gone = tempDir().appending(path: "not-there"); let lib = UserLibrary(folder: gone, watcher: nil); await lib.load()
        #expect(lib.problem == "The collection folder is not at \(gone.path).")
        #expect(lib.folder == gone); #expect(lib.folderIsMissing)
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A")
        lib.replace(game: "riftbound", rows: [.init(productID: 2, finish: "Normal", count: 1, condition: "", name: "B")])
        #expect(lib.rows(game: "riftbound").isEmpty)
    }

    @MainActor @Test func aNewerFileIsNotOverwritten() async throws {
        let dir = tempDir(); try UserFiles.write(Data(#"{"version":2,"collection":[],"x":1}"#.utf8), to: dir.appending(path: "riftbound.json"))
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A"); await lib.flush()
        #expect(try UserFiles.read(dir.appending(path: "riftbound.json")) == Data(#"{"version":2,"collection":[],"x":1}"#.utf8))
        #expect(lib.problem?.contains("newer") == true); #expect(lib.rows(game: "riftbound").isEmpty)
    }

    /// A refused file is read-only for this run; the other games keep working.
    @MainActor @Test func aRefusedFileLeavesTheOtherGamesWorking() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json"), broken = Data(#"{"version":1,"collection":{"a":1}}"#.utf8)
        try UserFiles.write(broken, to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.problem == "riftbound.json cannot be read.")
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A")
        lib.replace(game: "riftbound", rows: [.init(productID: 2, finish: "Normal", count: 1, condition: "", name: "B")])
        lib.setCount(2, game: "cyberpunk", key: .init(productID: 3, finish: "Normal"), name: "C")
        await lib.flush()
        #expect(try UserFiles.read(file) == broken); #expect(lib.rows(game: "riftbound").isEmpty)
        #expect(try stored(dir, "cyberpunk").map(\.count) == [2]); #expect(lib.rows(game: "cyberpunk").map(\.count) == [2])
    }

    @MainActor @Test func theProblemTexts() async throws {
        let dir = tempDir()
        try UserFiles.write(Data(#"{"version":3}"#.utf8), to: dir.appending(path: "riftbound.json"))
        try UserFiles.write(Data("not json".utf8), to: dir.appending(path: "yu-gi-oh.json"))
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.problems == ["yu-gi-oh.json cannot be read.", "riftbound.json was written by a newer version of the app."])
        #expect(lib.problem == "yu-gi-oh.json cannot be read.")
    }

    /// What the file keeps that this app does not know (another device's newer app) survives a change made here.
    @MainActor @Test func unknownKeysSurviveAChange() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        try UserFiles.write(Data(#"{"version":1,"collection":[{"productID":1,"finish":"Normal","count":1,"grade":"A"}],"wanted":[1]}"#.utf8), to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(4, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "")
        await lib.flush()
        let object = try jsonObject(file)
        #expect(object["wanted"] as? [Int] == [1])
        #expect((object["collection"] as? [[String: Any]])?.first?["grade"] as? String == "A")
        #expect((object["collection"] as? [[String: Any]])?.first?["count"] as? Int == 4)
    }

    /// A reload with the same rows still takes the file: keys another device added survive the next change made here.
    @MainActor @Test func aReloadWithTheSameRowsKeepsTheNewKeys() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A"); await lib.flush()
        try UserFiles.write(Data(#"{"version":1,"collection":[{"productID":1,"finish":"Normal","count":1,"name":"A","condition":""}],"decks":[]}"#.utf8), to: file)
        let before = lib.version
        await watcher.fire(file)
        #expect(lib.version == before)
        lib.setCount(2, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: ""); await lib.flush()
        let object = try jsonObject(file)
        #expect(object["decks"] as? [Int] == [])
    }

    /// A file we wrote ourselves causes no reload loop and no version bump.
    @MainActor @Test func ourOwnWriteIsNotAChange() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        let before = lib.version
        await watcher.fire(file); await watcher.fire(file); await lib.flush()
        #expect(lib.version == before); #expect(try stored(dir, "riftbound").map(\.count) == [1])
    }

    /// A change made here while another device's file comes in: our write finishes first, then the file is read again.
    /// The last writer wins on disk; nothing is merged.
    @MainActor @Test func aPendingWriteOfOursWinsOverAChangeThatArrivesWithIt() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        var other = GameUserFile(); other.collection = [.init(productID: 9, finish: "Normal", count: 7, condition: "", name: "Other")]
        try UserFiles.write(try other.data(), to: file)
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")       // queued, not written yet
        let reload = lib.fileChanged(file)                                 // the other device's file, queued after it
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A")       // a change of ours, queued after the reload
        await reload?.value; await lib.flush()
        let mine = [CollectionRow(productID: 721334, finish: "Foil", count: 2, condition: "", name: "A")]
        #expect(lib.rows(game: "riftbound") == mine); #expect(try stored(dir, "riftbound") == mine)
    }

    /// The other device's file arrives after our last write: it is loaded.
    @MainActor @Test func aChangeAfterOurWriteIsLoaded() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")
        let reload = lib.fileChanged(file)
        await lib.flush()
        var other = GameUserFile(); other.collection = [.init(productID: 9, finish: "Normal", count: 7, condition: "", name: "Other")]
        try UserFiles.write(try other.data(), to: file)
        await reload?.value
        await lib.fileChanged(file)?.value
        #expect(lib.rows(game: "riftbound").map(\.productID) == [9])
    }

    /// A file deleted on another device reads as an empty collection, as a missing file does at launch.
    @MainActor @Test func aFileDeletedElsewhereEmptiesTheGame() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        try FileManager.default.removeItem(at: file)
        let before = lib.version
        await watcher.fire(file)
        #expect(lib.rows(game: "riftbound").isEmpty); #expect(lib.version > before)
    }

    /// A refused file that another device makes readable again is loaded and can be changed.
    @MainActor @Test func aRefusedFileThatBecomesReadableIsLoaded() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        try UserFiles.write(Data(#"{"version":2}"#.utf8), to: file)
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        #expect(lib.problem != nil)
        try UserFiles.write(Data(#"{"version":1,"collection":[{"productID":4,"finish":"Normal","count":1}]}"#.utf8), to: file)
        await watcher.fire(file)
        #expect(lib.problem == nil); #expect(lib.rows(game: "riftbound").map(\.productID) == [4])
        lib.setCount(2, game: "riftbound", key: .init(productID: 4, finish: "Normal"), name: ""); await lib.flush()
        #expect(try stored(dir, "riftbound").map(\.count) == [2])
    }

    /// Other files in the folder and files of other folders are not game files.
    @MainActor @Test func otherFilesAreIgnored() async throws {
        let dir = tempDir(), elsewhere = tempDir(), watcher = FakeWatcher()
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        var other = GameUserFile(); other.collection = [.init(productID: 5, finish: "Normal", count: 1, condition: "", name: "B")]
        for url in [dir.appending(path: "riftbound.conflict-2026-11-12-101500.json"), dir.appending(path: "settings.json"),
                    dir.appending(path: "pokemon.json"), elsewhere.appending(path: "riftbound.json")] {
            try UserFiles.write(try other.data(), to: url)
            let before = lib.version
            await watcher.fire(url)
            #expect(lib.version == before, "\(url.lastPathComponent)"); #expect(lib.rows(game: "riftbound").isEmpty)
        }
    }

    /// A failed write says so; the next change writes the whole state again and clears the problem.
    @MainActor @Test func aFailedWriteIsSaidAndTheNextChangeRetries() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A")
        lib.setCount(1, game: "cyberpunk", key: .init(productID: 2, finish: "Normal"), name: "B"); await lib.flush()
        #expect(lib.problem?.hasPrefix("riftbound.json could not be saved") == true)
        #expect(lib.rows(game: "riftbound").map(\.count) == [1])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        lib.setCount(2, game: "riftbound", key: .init(productID: 3, finish: "Normal"), name: "C"); await lib.flush()
        #expect(try stored(dir, "riftbound").map(\.productID) == [1, 3])
        #expect(lib.problem?.hasPrefix("cyberpunk.json could not be saved") == true)
        lib.setCount(2, game: "cyberpunk", key: .init(productID: 2, finish: "Normal"), name: ""); await lib.flush()
        #expect(lib.problem == nil)
    }

    /// The folder goes away while the app runs: the write fails, the folder is not made again, and the problem names it.
    @MainActor @Test func aFolderRemovedWhileRunningIsNotMadeAgain() async throws {
        let dir = tempDir().appending(path: "TCG Collection")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        try FileManager.default.removeItem(at: dir)
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A"); await lib.flush()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(lib.problem == "The collection folder is not at \(dir.path).")
    }

    /// `use(folder:)` writes what is queued to the old folder, stops watching it, and loads the new one. Nothing is copied.
    @MainActor @Test func switchingTheFolder() async throws {
        let old = tempDir(), new = tempDir(), watcher = FakeWatcher()
        var there = GameUserFile(); there.collection = [.init(productID: 8, finish: "Normal", count: 1, condition: "", name: "H")]
        try UserFiles.write(try there.data(), to: new.appending(path: "cyberpunk.json"))
        let lib = UserLibrary(folder: old, watcher: watcher); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")
        let before = lib.version
        await lib.use(folder: new)
        #expect(try stored(old, "riftbound").map(\.count) == [1])
        #expect(lib.folder == new); #expect(lib.version > before)
        #expect(lib.rows(game: "riftbound").isEmpty); #expect(lib.rows(game: "cyberpunk").map(\.productID) == [8])
        #expect(watcher.started == [old, new]); #expect(watcher.stops >= 1)
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "riftbound.json").path))
    }

    /// No folder yet (the first-run sheet is open): nothing is kept and nothing is written.
    @MainActor @Test func noFolderMeansNoChange() async {
        let lib = UserLibrary(folder: nil, watcher: nil); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        #expect(lib.rows(game: "riftbound").isEmpty); #expect(lib.problem == nil)
    }

    @MainActor @Test func countsAndReplace() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A")
        #expect(lib.count(game: "riftbound", key: riftFoil) == 2); #expect(lib.count(game: "riftbound", key: .init(productID: 1, finish: "Foil")) == 0)
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 3, condition: "Near Mint", name: "B")]
        let before = lib.version
        lib.replace(game: "riftbound", rows: rows); await lib.flush()
        #expect(lib.version > before); #expect(lib.rows(game: "riftbound") == rows); #expect(try stored(dir, "riftbound") == rows)
        // A change that changes nothing does not count as one.
        let same = lib.version
        lib.setCount(3, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "")
        #expect(lib.version == same)
    }

    /// The JSON object stored in `file`.
    private func jsonObject(_ file: URL) throws -> [String: Any] {
        let data = try #require(try UserFiles.read(file))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The rows stored in `<dir>/<game>.json`.
    private func stored(_ dir: URL, _ game: String) throws -> [CollectionRow] {
        try GameUserFile(data: try #require(try UserFiles.read(dir.appending(path: "\(game).json")))).collection
    }
}
