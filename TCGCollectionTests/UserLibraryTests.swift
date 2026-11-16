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

/// Holds the library's game-file reads (its `beforeRead` seam) until the test lets them go, so a test can act while a
/// read is in progress.
@MainActor final class ReadGate {
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Which reads are held; the others pass.
    var holds: (URL) -> Bool = { _ in true }

    var waiting: Int { held.count }

    func pass(_ url: URL) async {
        guard holds(url) else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func release() {
        let all = held
        held = []
        for continuation in all { continuation.resume() }
    }

    /// Lets every read pass from now on.
    func open() {
        holds = { _ in false }
        release()
    }

    func waitUntilHolding() async throws {
        let end = ContinuousClock.now + .seconds(10)
        while held.isEmpty {
            guard ContinuousClock.now < end else { throw GateTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    struct GateTimeout: Error {}
}

struct UserLibraryTests {
    private let riftFoil = PrintingKey(productID: 721334, finish: "Foil")
    /// A file in the owner's own form (compact, keys in another order): any rewrite by this app changes its bytes.
    private let ownersFile = Data(#"{"collection":[{"count":2,"finish":"Normal","productID":7,"name":"Owner"}],"version":1}"#.utf8)

    // MARK: Fix round 1: the folder switch (Important 1), isLoaded (item 9), the guards (Important 2)

    /// Important 1, variant 2: the launch's `load()` of A is still reading when "Collection Folder…" switches to B. The
    /// overtaken load must not mark the library loaded while B is read; a change then is refused, and B's file stays as
    /// it is.
    @MainActor @Test(.timeLimit(.minutes(1))) func aLoadThatASwitchOvertookNeverMarksTheLibraryLoaded() async throws {
        let a = tempDir(), b = tempDir(), bFile = b.appending(path: "riftbound.json")
        try ownersFile.write(to: bFile)
        let lib = UserLibrary(folder: a, watcher: nil), gate = ReadGate()
        lib.beforeRead = { await gate.pass($0) }
        let first = Task { await lib.load() }                                   // the launch's load, reading A
        try await gate.waitUntilHolding()
        let switching = Task { await lib.use(folder: b) }                        // "Collection Folder…" meanwhile
        try await Task.sleep(for: .milliseconds(50))                             // use() waits for A's read
        gate.holds = { UserFolder.isInside($0, b) }
        gate.release()                                                          // A's read ends; B's first read waits
        try await gate.waitUntilHolding()
        await first.value
        #expect(!lib.isLoaded)
        lib.setCount(1, game: "riftbound", key: .init(productID: 7, finish: "Normal"), name: "")
        #expect(lib.rows(game: "riftbound").isEmpty)
        gate.open()
        await switching.value; await lib.flush()
        #expect(lib.isLoaded); #expect(lib.folder == b)
        #expect(lib.rows(game: "riftbound").map(\.count) == [2])
        #expect(try Data(contentsOf: bFile) == ownersFile)
    }

    /// Important 1, variant 1: a change made while `use(folder:)` runs goes to the old folder (before the switch) or
    /// nowhere (after it, until the new folder is read). The new folder's file is never written with the old rows.
    @MainActor @Test(.timeLimit(.minutes(1))) func aChangeDuringAFolderSwitchNeverReachesTheNewFolder() async throws {
        let a = tempDir(), b = tempDir(), bFile = b.appending(path: "riftbound.json")
        try ownersFile.write(to: bFile)
        let lib = UserLibrary(folder: a, watcher: nil); await lib.load()
        let gate = ReadGate()
        lib.beforeRead = { await gate.pass($0) }
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")             // queued for A: the switch waits for it
        let switching = Task { await lib.use(folder: b) }
        while lib.folder != b { await Task.yield() }
        lib.setCount(5, game: "riftbound", key: riftFoil, name: "A")             // B is set, B is not read yet
        try await gate.waitUntilHolding()
        lib.setCount(6, game: "riftbound", key: riftFoil, name: "A")             // B is being read
        #expect(!lib.isLoaded)
        gate.open()
        await switching.value; await lib.flush()
        #expect(try Data(contentsOf: bFile) == ownersFile)
        #expect(lib.rows(game: "riftbound").map(\.productID) == [7])
        #expect(try stored(a, "riftbound").map(\.count) == [1])
    }

    /// Item 5: a file this app must not rewrite appears on disk before our queued write runs (another device's newer app,
    /// or a broken file). The write is refused inside the coordinated write, the file stays byte-identical, and the game is
    /// read-only for the run with the problem of a refused file.
    @MainActor @Test func aFileThatAppearsBeforeOurWriteAndMustNotBeRewrittenIsKept() async throws {
        let cases: [(Data, String)] = [
            (Data(#"{"version":2,"collection":[],"x":1}"#.utf8), "riftbound.json was written by a newer version of the app."),
            (Data(#"{"version":1,"collection":{"a":1}}"#.utf8), "riftbound.json cannot be read."),
            (Data(#"{"version":"1"}"#.utf8), "riftbound.json cannot be read."),
            (Data("[1]".utf8), "riftbound.json cannot be read."),
        ]
        for (onDisk, text) in cases {
            let dir = tempDir(), file = dir.appending(path: "riftbound.json")
            let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
            lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")         // version-1 rows; the write is queued
            try onDisk.write(to: file)                                          // before the write runs
            await lib.flush()
            #expect(try Data(contentsOf: file) == onDisk)
            #expect(lib.problem == text); #expect(lib.rows(game: "riftbound").isEmpty)
            lib.setCount(2, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
            #expect(try Data(contentsOf: file) == onDisk)
            lib.setCount(1, game: "cyberpunk", key: riftFoil, name: "A"); await lib.flush()
            #expect(try stored(dir, "cyberpunk").map(\.count) == [1])
        }
    }

    /// Item 5: a file that iCloud has not downloaded (`.riftbound.json.icloud`) is not missing: our write does not make a
    /// new `riftbound.json` beside it.
    @MainActor @Test func aWriteDoesNotReplaceAFileThatIsNotDownloaded() async throws {
        let dir = tempDir()
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")
        try Data().write(to: dir.appending(path: ".riftbound.json.icloud"))
        await lib.flush()
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "riftbound.json").path))
        #expect(lib.problem == "riftbound.json is not downloaded from iCloud yet.")
    }

    /// Item 8: while a game has a failed write, a reload of that game does not replace memory: the change that could not
    /// be saved stays, and so does its problem. The next successful write (the next change, with the whole state) clears
    /// the failure; only then are reloads applied again.
    @MainActor @Test func aFailedWriteIsNotReplacedByAReload() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()      // the folder is read-only
        #expect(lib.problem?.hasPrefix("riftbound.json could not be saved") == true)
        var other = GameUserFile(); other.collection = [.init(productID: 9, finish: "Normal", count: 7, condition: "", name: "Other")]
        try other.data().write(to: file)                                     // another device, in place
        await lib.fileChanged(file)?.value
        #expect(lib.rows(game: "riftbound").map(\.count) == [2])
        #expect(lib.problem?.hasPrefix("riftbound.json could not be saved") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        #expect(try stored(dir, "riftbound").map(\.count) == [3]); #expect(lib.problem == nil)
        try UserFiles.write(try other.data(), to: file)
        await lib.fileChanged(file)?.value
        #expect(lib.rows(game: "riftbound").map(\.productID) == [9])
    }

    /// Item 9: false before the first load, true after it, false while a folder is switched and when the folder is missing.
    @MainActor @Test(.timeLimit(.minutes(1))) func isLoadedFollowsTheFolder() async throws {
        let a = tempDir(), b = tempDir()
        let lib = UserLibrary(folder: a, watcher: nil)
        #expect(!lib.isLoaded)
        await lib.load(); #expect(lib.isLoaded)
        let gate = ReadGate()
        lib.beforeRead = { await gate.pass($0) }
        let switching = Task { await lib.use(folder: b) }
        try await gate.waitUntilHolding()
        #expect(!lib.isLoaded)
        gate.open(); await switching.value
        #expect(lib.isLoaded)
        await lib.use(folder: b.appending(path: "not-there"))
        #expect(!lib.isLoaded)
        #expect(!UserLibrary(folder: nil, watcher: nil).isLoaded)
    }

    /// Important 2, the `isLoaded` guard: a change before the first load, or while it reads, would start from an empty
    /// file and replace the owner's whole file with one row.
    @MainActor @Test(.timeLimit(.minutes(1))) func aChangeBeforeTheFirstLoadLeavesTheFileAsItIs() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        try ownersFile.write(to: file)
        let lib = UserLibrary(folder: dir, watcher: nil)
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")
        lib.replace(game: "riftbound", rows: [.init(productID: 1, finish: "Normal", count: 1, condition: "", name: "B")])
        #expect(lib.rows(game: "riftbound").isEmpty)
        await lib.flush()
        #expect(try Data(contentsOf: file) == ownersFile)
        let gate = ReadGate()
        lib.beforeRead = { await gate.pass($0) }
        let loading = Task { await lib.load() }
        try await gate.waitUntilHolding()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A")             // during the first load
        gate.open(); await loading.value; await lib.flush()
        #expect(try Data(contentsOf: file) == ownersFile)
        #expect(lib.rows(game: "riftbound").map(\.productID) == [7])
    }

    /// Important 2, the re-check after a reload's read: a change made here during the read is newer than what was read.
    /// Our write goes to the file and the read is dropped; the change is not lost.
    @MainActor @Test(.timeLimit(.minutes(1))) func aChangeDuringAReloadReadIsKept() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        var other = GameUserFile(); other.collection = [.init(productID: 9, finish: "Normal", count: 7, condition: "", name: "Other")]
        try UserFiles.write(try other.data(), to: file)                         // another device
        let gate = ReadGate()
        lib.beforeRead = { await gate.pass($0) }
        let reload = lib.fileChanged(file)
        try await gate.waitUntilHolding()
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A")             // during the read
        gate.open(); await reload?.value; await lib.flush()
        let mine = [CollectionRow(productID: 721334, finish: "Foil", count: 2, condition: "", name: "A")]
        #expect(lib.rows(game: "riftbound") == mine); #expect(try stored(dir, "riftbound") == mine)
    }

    /// Important 2, the game guard: an unknown game id, or one that leaves the folder, writes nothing anywhere.
    @MainActor @Test func anUnknownGameWritesNothing() async throws {
        let parent = tempDir(), dir = parent.appending(path: "folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(1, game: "../x", key: riftFoil, name: "A")
        lib.setCount(1, game: "pokemon", key: riftFoil, name: "A")
        lib.replace(game: "../../y", rows: [.init(productID: 1, finish: "Normal", count: 1, condition: "", name: "B")])
        lib.setCount(1, game: "", key: riftFoil, name: "A")
        await lib.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["folder"])
        #expect(lib.rows(game: "../x").isEmpty); #expect(lib.problem == nil)
    }

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

    /// Final fix A5: the folder itself is gone when a reload runs (moved away while the app runs). The read is not applied:
    /// memory keeps its rows (a later write must not leave a file of only the new rows), the folder is said to be
    /// missing, and changes are refused. Once the folder is back with its file, the next reload reads that file.
    @MainActor @Test func aReloadOfAFolderThatIsGoneKeepsTheRows() async throws {
        let parent = tempDir(), dir = parent.appending(path: "TCG Collection"), away = parent.appending(path: "Moved")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "riftbound.json")
        var there = GameUserFile(); there.collection = [.init(productID: 4, finish: "Normal", count: 2, condition: "", name: "D")]
        try UserFiles.write(try there.data(), to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.rows(game: "riftbound").map(\.productID) == [4])

        try FileManager.default.moveItem(at: dir, to: away)
        let before = lib.version
        await lib.fileChanged(file)?.value
        #expect(lib.rows(game: "riftbound").map(\.productID) == [4])               // memory keeps its rows
        #expect(lib.version == before)
        #expect(lib.folderIsMissing && lib.problem == "The collection folder is not at \(dir.path).")
        #expect(!lib.canChange(game: "riftbound"))
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        #expect(lib.rows(game: "riftbound").map(\.productID) == [4])               // refused, nothing written
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        // Back, with a file another device changed meanwhile: the next reload reads it, and changes are allowed again.
        try FileManager.default.moveItem(at: away, to: dir)
        there.collection = [.init(productID: 6, finish: "Foil", count: 1, condition: "", name: "F")]
        try UserFiles.write(try there.data(), to: file)
        await lib.fileChanged(file)?.value
        #expect(!lib.folderIsMissing && lib.problem == nil && lib.canChange(game: "riftbound"))
        #expect(lib.rows(game: "riftbound").map(\.productID) == [6])
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        #expect(try stored(dir, "riftbound").map(\.productID) == [6, 721334])
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

    /// The views disable their controls on it: false wherever `setCount` would be refused.
    @MainActor @Test func canChangeIsFalseWhereAChangeIsRefused() async throws {
        let dir = tempDir()
        try UserFiles.write(Data(#"{"version":2,"collection":[]}"#.utf8), to: dir.appending(path: "riftbound.json"))
        let lib = UserLibrary(folder: dir, watcher: nil)
        #expect(!lib.canChange(game: "cyberpunk"))                                  // not loaded yet
        await lib.load()
        #expect(lib.canChange(game: "cyberpunk"))
        #expect(!lib.canChange(game: "riftbound"))                                  // newer file: refused
        #expect(!lib.canChange(game: "not-a-game"))
        let gone = UserLibrary(folder: tempDir().appending(path: "not-there"), watcher: nil); await gone.load()
        #expect(!gone.canChange(game: "cyberpunk"))                                 // missing folder
        let none = UserLibrary(folder: nil, watcher: nil); await none.load()
        #expect(!none.canChange(game: "cyberpunk"))                                 // no folder chosen yet
    }

    /// Fix round 1, item 6: each game's own problem first (refusal, failed write), then the folder's; `problem` stays the
    /// general one for the sidebar.
    @MainActor @Test func eachGameHasItsOwnProblem() async throws {
        let dir = tempDir()
        try UserFiles.write(Data(#"{"version":3}"#.utf8), to: dir.appending(path: "riftbound.json"))
        try UserFiles.write(Data("not json".utf8), to: dir.appending(path: "yu-gi-oh.json"))
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.problem(game: "riftbound") == "riftbound.json was written by a newer version of the app.")
        #expect(lib.problem(game: "yu-gi-oh") == "yu-gi-oh.json cannot be read.")
        #expect(lib.problem(game: "cyberpunk") == nil)
        #expect(lib.problem == "yu-gi-oh.json cannot be read.")
        // A failed write is the game's own problem.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        lib.setCount(1, game: "cyberpunk", key: .init(productID: 2, finish: "Normal"), name: "B"); await lib.flush()
        #expect(lib.problem(game: "cyberpunk")?.hasPrefix("cyberpunk.json could not be saved") == true)
        #expect(lib.problem(game: "magic-the-gathering") == nil)
        // A missing folder is every game's problem.
        let gone = tempDir().appending(path: "not-there"), missing = UserLibrary(folder: gone, watcher: nil); await missing.load()
        #expect(missing.problem(game: "cyberpunk") == "The collection folder is not at \(gone.path).")
    }

    /// Fix round 1, item 1: why a card page's counts are not shown and cannot change; nil while they can.
    @MainActor @Test func whyTheCountsCannotChange() async throws {
        let dir = tempDir()
        try UserFiles.write(Data(#"{"version":2,"collection":[]}"#.utf8), to: dir.appending(path: "riftbound.json"))
        let lib = UserLibrary(folder: dir, watcher: nil)
        #expect(lib.countsLocked(game: "cyberpunk") == "Reading your collection…")             // not read yet
        await lib.load()
        #expect(lib.countsLocked(game: "cyberpunk") == nil)
        #expect(lib.countsLocked(game: "riftbound") == "The counts cannot change: riftbound.json was written by a newer version of the app.")
        let gone = tempDir().appending(path: "not-there"), missing = UserLibrary(folder: gone, watcher: nil); await missing.load()
        #expect(missing.countsLocked(game: "cyberpunk") == "The counts cannot change: The collection folder is not at \(gone.path).")
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

    // MARK: Phase 2C task 2: Wanted, For Sale, the sold log

    /// 2026-11-13 22:30 UTC: already 2026-11-14 in Istanbul (UTC+3).
    private static let lateEvening = ISO8601DateFormatter().date(from: "2026-11-13T22:30:00Z")!
    private let istanbul = TimeZone(identifier: "Europe/Istanbul")!

    /// The file stored in `<dir>/<game>.json`.
    private func storedFile(_ dir: URL, _ game: String) throws -> GameUserFile {
        try GameUserFile(data: try #require(try UserFiles.read(dir.appending(path: "\(game).json"))))
    }

    /// Each setter and `sell` changes memory at once, bumps `version` and reaches the file; a change that changes nothing
    /// is not one. The sold day is the device's calendar day of `now`, in its time zone.
    @MainActor @Test func eachListChangeIsWrittenAndBumpsTheVersion() async throws {
        let dir = tempDir()
        let lib = UserLibrary(folder: dir, watcher: nil, now: { Self.lateEvening }, timeZone: istanbul); await lib.load()
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "Dockside Lock-Up")
        var before = lib.version
        lib.setWanted(2, game: "riftbound", cardKey: "dockside lock-up", name: "Dockside Lock-Up")
        #expect(lib.version > before); before = lib.version
        lib.setPin(riftFoil, game: "riftbound", cardKey: "dockside lock-up")
        #expect(lib.version > before); before = lib.version
        lib.setForSale(2, game: "riftbound", key: riftFoil, name: "Dockside Lock-Up")
        #expect(lib.version > before); before = lib.version
        #expect(lib.sell(1, game: "riftbound", key: riftFoil, price: ShownPrice(amount: 1.5, isLow: true)))
        #expect(lib.version > before)
        #expect(lib.wantedCount(game: "riftbound", cardKey: "dockside lock-up") == 2)
        #expect(lib.wantedCount(game: "riftbound", cardKey: "other") == 0)
        #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 1)
        #expect(lib.forSaleCount(game: "riftbound", key: .init(productID: 1, finish: "Foil")) == 0)
        #expect(lib.count(game: "riftbound", key: riftFoil) == 2)
        await lib.flush()
        let stored = try storedFile(dir, "riftbound")
        #expect(stored.wanted == [WantedEntry(cardKey: "dockside lock-up", name: "Dockside Lock-Up", count: 2, pinProductID: 721334, pinFinish: "Foil")])
        #expect(stored.forSale == [SaleEntry(productID: 721334, finish: "Foil", count: 1, name: "Dockside Lock-Up")])
        #expect(stored.collection.map(\.count) == [2])
        #expect(stored.sold == [SoldRecord(productID: 721334, finish: "Foil", count: 1, name: "Dockside Lock-Up", day: "2026-11-14", price: 1.5, priceIsLow: true)])
        #expect(lib.wanted(game: "riftbound") == stored.wanted); #expect(lib.forSale(game: "riftbound") == stored.forSale)
        #expect(lib.sold(game: "riftbound") == stored.sold)
        // A change that changes nothing does not count as one.
        let same = lib.version
        lib.setWanted(2, game: "riftbound", cardKey: "dockside lock-up", name: "")
        lib.setPin(riftFoil, game: "riftbound", cardKey: "dockside lock-up")
        lib.setPin(nil, game: "riftbound", cardKey: "not wanted")
        lib.setForSale(1, game: "riftbound", key: riftFoil, name: "")
        lib.setForSale(0, game: "riftbound", key: .init(productID: 1, finish: "Foil"), name: "")
        #expect(!lib.sell(0, game: "riftbound", key: riftFoil, price: nil))
        #expect(lib.version == same); #expect(lib.saleNotice == nil)
        // The same instant in UTC is still the 13th.
        let utc = UserLibrary(folder: dir, watcher: nil, now: { Self.lateEvening }, timeZone: TimeZone(identifier: "UTC")!)
        await utc.load()
        #expect(utc.sell(1, game: "riftbound", key: riftFoil, price: nil))
        #expect(utc.sold(game: "riftbound").last?.day == "2026-11-13")
    }

    /// Review Focus 3: two fast "Sold all 2" clicks sell the two copies once; the second click is refused.
    @MainActor @Test func sellingAllTwiceSellsOnce() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(2, game: "riftbound", key: riftFoil, name: "A")
        #expect(lib.sell(2, game: "riftbound", key: riftFoil, price: nil))
        #expect(!lib.sell(2, game: "riftbound", key: riftFoil, price: nil))
        await lib.flush()
        let stored = try storedFile(dir, "riftbound")
        #expect(stored.collection.isEmpty && stored.forSale.isEmpty)
        #expect(stored.sold.map(\.count) == [2])
    }

    /// Review Focus 3: a sale while another device's file waits in the queue is made on the rows on screen and written
    /// first; the reload then reads our file (the last writer wins), so the copies are sold once. A reload that already
    /// ran leaves its rows (for sale clamped to them in memory): a sale is then made on them, never on more copies than
    /// they own.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleWhileAReloadIsQueuedIsWrittenFirst() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(2, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        var other = try storedFile(dir, "riftbound")
        other.collection = [.init(productID: 9, finish: "Normal", count: 7, condition: "", name: "Other")]
        other.forSale = []
        try UserFiles.write(try other.data(), to: file)                         // another device
        let reload = lib.fileChanged(file)                                     // queued, not run yet
        #expect(lib.sell(2, game: "riftbound", key: riftFoil, price: nil))
        #expect(!lib.sell(1, game: "riftbound", key: riftFoil, price: nil))
        await reload?.value; await lib.flush()
        let stored = try storedFile(dir, "riftbound")
        #expect(stored.collection.isEmpty && stored.forSale.isEmpty); #expect(stored.sold.map(\.count) == [2])
        #expect(lib.rows(game: "riftbound").isEmpty && lib.forSale(game: "riftbound").isEmpty)
        #expect(lib.sold(game: "riftbound") == stored.sold)

        // A phase 2B device lowers the owned count to 1 and keeps the for-sale count (an unknown key there): the reload
        // clamps for sale to 1 in memory, and only 1 copy can be sold.
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(3, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        other = try storedFile(dir, "riftbound")
        other.collection = [.init(productID: 721334, finish: "Foil", count: 1, condition: "", name: "A")]
        try UserFiles.write(try other.data(), to: file)
        await lib.fileChanged(file)?.value
        #expect(lib.count(game: "riftbound", key: riftFoil) == 1); #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 1)
        #expect(!lib.sell(2, game: "riftbound", key: riftFoil, price: nil))
        #expect(lib.sell(1, game: "riftbound", key: riftFoil, price: nil))
        await lib.flush()
        let after = try storedFile(dir, "riftbound")
        #expect(after.collection.isEmpty && after.forSale.isEmpty); #expect(after.sold.map(\.count) == [2, 1])
    }

    /// C8: an owned count that goes under the for-sale count takes it down in the same change, and the library says so
    /// once (until `clearSaleNotice`); copies taken off by several changes are summed.
    @MainActor @Test func aLowerOwnedCountTakesTheForSaleCountDown() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(2, game: "riftbound", key: riftFoil, name: "A")
        #expect(lib.saleNotice == nil)
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "")
        #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 1)
        #expect(lib.saleNotice == "1 copy is no longer for sale.")
        lib.clearSaleNotice(); #expect(lib.saleNotice == nil)
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "")             // up: for sale stays 1, nothing said
        #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 1); #expect(lib.saleNotice == nil)
        lib.setCount(4, game: "riftbound", key: riftFoil, name: "")
        lib.setForSale(4, game: "riftbound", key: riftFoil, name: "")
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "")
        lib.setCount(0, game: "riftbound", key: riftFoil, name: "")
        #expect(lib.forSale(game: "riftbound").isEmpty)
        #expect(lib.saleNotice == "4 copies are no longer for sale.")
        await lib.flush()
        #expect(try storedFile(dir, "riftbound").forSale.isEmpty)
    }

    /// C8 by an import: `replace` that removes a row removes its for-sale entry, and one that lowers a row lowers it.
    @MainActor @Test func anImportThatRemovesARowTakesItOffSale() async throws {
        let dir = tempDir(); let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        let normal = PrintingKey(productID: 1, finish: "Normal")
        lib.setCount(2, game: "riftbound", key: riftFoil, name: "A")
        lib.setCount(3, game: "riftbound", key: normal, name: "B")
        lib.setForSale(2, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(2, game: "riftbound", key: normal, name: "B")
        lib.replace(game: "riftbound", rows: [.init(productID: 1, finish: "Normal", count: 1, condition: "", name: "B")])
        #expect(lib.forSale(game: "riftbound") == [SaleEntry(productID: 1, finish: "Normal", count: 1, name: "B")])
        #expect(lib.saleNotice == "3 copies are no longer for sale.")
        await lib.flush()
        #expect(try storedFile(dir, "riftbound").forSale == lib.forSale(game: "riftbound"))
    }

    /// Review Focus 2, fix round 1: a file whose for-sale count is over its owned count is clamped in memory when it is
    /// loaded, and said; the load writes nothing. The next change of that game, of any list, writes the clamped list and
    /// says nothing more.
    @MainActor @Test func aFileOverTheCollectionIsClampedInMemoryAtLoad() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let onDisk = Data(#"{"collection":[{"productID":721334,"finish":"Foil","count":2}],"forSale":[{"productID":721334,"finish":"Foil","count":5}],"version":1}"#.utf8)
        try onDisk.write(to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load(); await lib.flush()
        #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 2)
        #expect(lib.saleNotice == "3 copies are no longer for sale.")
        #expect(try Data(contentsOf: file) == onDisk); #expect(!lib.hasPendingWork)
        lib.clearSaleNotice()
        lib.setWanted(1, game: "riftbound", cardKey: "x", name: "X")
        #expect(lib.saleNotice == nil)
        await lib.flush()
        #expect(try storedFile(dir, "riftbound").forSale.map(\.count) == [2])
    }

    /// Final fix A3: a change that held a sale is dropped at its write (the file became one this app must not rewrite:
    /// here not downloaded, between the read and the write), and `unsavedSaleNotice` says so with the game's problem. A
    /// sale already written is not said when a later change of its game is dropped.
    @MainActor @Test func aSaleDroppedAtItsWriteIsSaidOnce() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(2, game: "riftbound", key: riftFoil, name: "A")
        #expect(lib.sell(1, game: "riftbound", key: riftFoil, price: nil))
        await lib.flush()                                                        // the sale is on disk
        lib.setWanted(1, game: "riftbound", cardKey: "x", name: "X")             // not a sale; its write is dropped
        try Data(#"{"version":2,"collection":[]}"#.utf8).write(to: file)
        await lib.flush()
        #expect(lib.problem(game: "riftbound") == "riftbound.json was written by a newer version of the app.")
        #expect(lib.unsavedSaleNotice == nil)

        let cyber = PrintingKey(productID: 5, finish: "Normal")
        lib.setCount(2, game: "cyberpunk", key: cyber, name: "C")
        lib.setForSale(1, game: "cyberpunk", key: cyber, name: "C")
        await lib.flush()
        #expect(lib.sell(1, game: "cyberpunk", key: cyber, price: nil))
        try Data().write(to: dir.appending(path: ".cyberpunk.json.icloud"))
        try FileManager.default.removeItem(at: dir.appending(path: "cyberpunk.json"))
        await lib.flush()
        #expect(lib.unsavedSaleNotice == "The sale was not saved: cyberpunk.json is not downloaded from iCloud yet.")
        #expect(lib.sold(game: "cyberpunk").isEmpty)
        lib.clearUnsavedSaleNotice()
        #expect(lib.unsavedSaleNotice == nil)
    }

    /// Final fix B1: a clamp that leaves every list empty (no copy owned, 3 for sale) is said at load too: the game had
    /// no file in memory, so what the read takes off is new, although its lists now equal "no file".
    @MainActor @Test func aClampThatLeavesEveryListEmptyIsSaid() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let onDisk = Data(#"{"version":1,"collection":[],"forSale":[{"productID":721334,"finish":"Foil","count":3}]}"#.utf8)
        try onDisk.write(to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.forSale(game: "riftbound").isEmpty)
        #expect(lib.saleNotice == "3 copies are no longer for sale.")
        #expect(try Data(contentsOf: file) == onDisk)
    }

    /// Final fix B2: a second load of the same file before the notice is said counts its copies once, not twice.
    @MainActor @Test func twoLoadsCountTheCopiesOnce() async throws {
        let dir = tempDir()
        try Data(#"{"collection":[{"productID":721334,"finish":"Foil","count":2}],"forSale":[{"productID":721334,"finish":"Foil","count":5}],"version":1}"#.utf8)
            .write(to: dir.appending(path: "riftbound.json"))
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.saleNotice == "3 copies are no longer for sale.")
        await lib.load()
        #expect(lib.saleNotice == "3 copies are no longer for sale.")
        #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 2)
    }

    /// Final fix B3: "Any printing" (`setPin(nil)`) on a card whose pin this build cannot read (a half pin) writes the
    /// file without its pin keys, and a `null` pin key is no pin key: no pin key is left in the file.
    @MainActor @Test func anyPrintingLeavesNoPinKeyInTheFile() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        try Data(#"{"version":1,"collection":[],"wanted":[{"cardKey":"a","name":"A","count":1,"pinProductID":3},{"cardKey":"b","name":"B","count":1,"pinProductID":null,"pinFinish":null}]}"#.utf8)
            .write(to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        #expect(lib.wanted(game: "riftbound").map(\.pin) == [nil, nil])
        let before = lib.version
        lib.setPin(nil, game: "riftbound", cardKey: "a")
        #expect(lib.version > before)
        await lib.flush()
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains("pinProductID") && !text.contains("pinFinish"), "\(text)")
        #expect(try storedFile(dir, "riftbound").wanted.map(\.cardKey) == ["a", "b"])
        // Cleared once: a second "Any printing" changes nothing.
        let after = lib.version
        lib.setPin(nil, game: "riftbound", cardKey: "a")
        #expect(lib.version == after)
    }

    /// Phase 3A feedback 1, fix round 1: "Any printing" on a deck card whose `productID` this build cannot read writes
    /// the file without the key; a second "Any printing" changes nothing.
    @MainActor @Test func anyPrintingOnADeckLeavesNoUnreadableKey() async throws {
        let dir = tempDir(), file = dir.appending(path: "yu-gi-oh.json")
        try Data(#"{"version":1,"decks":[{"id":"d","name":"D","format":"standard","cards":[{"cardKey":"a","name":"A","section":"main","count":1,"productID":"3"}]}]}"#.utf8)
            .write(to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        let key = DeckCardKey(cardKey: "a", section: "main")
        let before = lib.version
        lib.setDeckPrinting(nil, game: "yu-gi-oh", deck: "d", key: key)
        #expect(lib.version > before)
        await lib.flush()
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("productID"))
        let after = lib.version
        lib.setDeckPrinting(nil, game: "yu-gi-oh", deck: "d", key: key)
        #expect(lib.version == after)
        lib.setDeckPrinting(7, game: "yu-gi-oh", deck: "d", key: key)
        #expect(lib.deck(game: "yu-gi-oh", id: "d")?.cards.map(\.productID) == [7])
    }

    /// Fix round 1: a reload of a file with more for sale than owned (a phase 2B device lowered the owned count) clamps
    /// for sale in memory, says so and bumps `version`, and writes nothing. The next change of another card writes the
    /// clamped list, with no second notice. A refused file is not clamped (it is not shown).
    @MainActor @Test func aReloadOverTheCollectionIsClampedInMemoryOnly() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        lib.setCount(3, game: "riftbound", key: riftFoil, name: "A")
        lib.setForSale(3, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        var other = try storedFile(dir, "riftbound")
        other.collection = [.init(productID: 721334, finish: "Foil", count: 1, condition: "", name: "A")]
        let onDisk = try other.data()
        try UserFiles.write(onDisk, to: file)                                     // owned 1, for sale 3
        let before = lib.version
        await watcher.fire(file)
        #expect(lib.count(game: "riftbound", key: riftFoil) == 1); #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 1)
        #expect(lib.saleNotice == "2 copies are no longer for sale."); #expect(lib.version > before)
        #expect(!lib.hasPendingWork); #expect(try Data(contentsOf: file) == onDisk)
        // The same file reported again (the presenter can report one change more than once): nothing new to say.
        lib.clearSaleNotice()
        let same = lib.version
        await watcher.fire(file)
        #expect(lib.saleNotice == nil); #expect(lib.version == same); #expect(lib.forSaleCount(game: "riftbound", key: riftFoil) == 1)
        lib.setWanted(1, game: "riftbound", cardKey: "other", name: "Other")
        #expect(lib.saleNotice == nil)                                            // no second notice
        await lib.flush()
        let stored = try storedFile(dir, "riftbound")
        #expect(stored.forSale == [SaleEntry(productID: 721334, finish: "Foil", count: 1, name: "A")])
        #expect(stored.wanted.map(\.cardKey) == ["other"])

        let refused = Data(#"{"version":2,"collection":[],"forSale":[{"productID":721334,"finish":"Foil","count":3}]}"#.utf8)
        lib.clearSaleNotice()
        try UserFiles.write(refused, to: file)
        await watcher.fire(file)
        #expect(lib.saleNotice == nil); #expect(lib.forSale(game: "riftbound").isEmpty)
        #expect(try Data(contentsOf: file) == refused)
    }

    /// A reload that changes only a list bumps `version`, so views read it again.
    @MainActor @Test func aReloadThatChangesOnlyAListBumpsTheVersion() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        let lib = UserLibrary(folder: dir, watcher: watcher); await lib.load()
        lib.setCount(1, game: "riftbound", key: riftFoil, name: "A"); await lib.flush()
        var other = try storedFile(dir, "riftbound")
        other.wanted = [WantedEntry(cardKey: "x", name: "X", count: 1, pinProductID: nil, pinFinish: nil)]
        try UserFiles.write(try other.data(), to: file)
        let before = lib.version
        await watcher.fire(file)
        #expect(lib.version > before); #expect(lib.wantedCount(game: "riftbound", cardKey: "x") == 1)
    }

    /// A refused file (newer, or a list of the wrong type) refuses every list change and `sell`: nothing in memory,
    /// nothing written, no version bump.
    @MainActor @Test func aRefusedFileRefusesEveryListChange() async throws {
        for onDisk in [Data(#"{"version":2,"collection":[{"productID":721334,"finish":"Foil","count":2}],"forSale":[{"productID":721334,"finish":"Foil","count":2}]}"#.utf8),
                       Data(#"{"version":1,"collection":[{"productID":721334,"finish":"Foil","count":2}],"forSale":[{"productID":721334,"finish":"Foil","count":2}],"wanted":3}"#.utf8)] {
            let dir = tempDir(), file = dir.appending(path: "riftbound.json")
            try onDisk.write(to: file)
            let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
            #expect(lib.problem(game: "riftbound") != nil)
            let before = lib.version
            lib.setWanted(1, game: "riftbound", cardKey: "x", name: "X")
            lib.setPin(riftFoil, game: "riftbound", cardKey: "x")
            lib.setForSale(1, game: "riftbound", key: riftFoil, name: "A")
            #expect(!lib.sell(1, game: "riftbound", key: riftFoil, price: nil))
            await lib.flush()
            #expect(lib.version == before); #expect(try Data(contentsOf: file) == onDisk)
            #expect(lib.wanted(game: "riftbound").isEmpty && lib.forSale(game: "riftbound").isEmpty && lib.sold(game: "riftbound").isEmpty)
        }
        // Before the first load, too.
        let dir = tempDir(), unloaded = UserLibrary(folder: dir, watcher: nil)
        unloaded.setWanted(1, game: "riftbound", cardKey: "x", name: "X")
        #expect(!unloaded.sell(1, game: "riftbound", key: riftFoil, price: nil))
        #expect(unloaded.wanted(game: "riftbound").isEmpty)
    }

    /// What another device's newer app wrote (top-level keys) survives each list change and a sale.
    @MainActor @Test func unknownKeysSurviveEveryListChange() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        try UserFiles.write(Data(#"{"version":1,"collection":[{"productID":721334,"finish":"Foil","count":3,"name":"A"}],"decks":[{"name":"d"}],"future":1}"#.utf8), to: file)
        let lib = UserLibrary(folder: dir, watcher: nil); await lib.load()
        let steps: [(String, () -> Void)] = [
            ("setWanted", { lib.setWanted(1, game: "riftbound", cardKey: "x", name: "X") }),
            ("setPin", { lib.setPin(self.riftFoil, game: "riftbound", cardKey: "x") }),
            ("setForSale", { lib.setForSale(2, game: "riftbound", key: self.riftFoil, name: "A") }),
            ("sell", { lib.sell(1, game: "riftbound", key: self.riftFoil, price: nil) }),
        ]
        for (name, step) in steps {
            let before = try Data(contentsOf: file)
            step(); await lib.flush()
            #expect(try Data(contentsOf: file) != before, "\(name)")
            let object = try jsonObject(file)
            #expect((object["decks"] as? [[String: String]])?.first?["name"] == "d", "\(name)")
            #expect(object["future"] as? Int == 1, "\(name)")
        }
    }

    // MARK: Phase 3A task 3: decks

    /// Ids "d1", "d2", … in order.
    @MainActor private final class IDs {
        var next = 0
        func make() -> String { next += 1; return "d\(next)" }
    }

    @MainActor private func deckLibrary(_ dir: URL, watcher: FakeWatcher? = nil) async -> UserLibrary {
        let ids = IDs()
        let lib = UserLibrary(folder: dir, watcher: watcher, newID: { ids.make() })
        await lib.load()
        return lib
    }

    /// `addDeck` writes a new deck that is not active (A14) and returns its id; an empty or blank name becomes a unique
    /// "Deck"; a name that is taken is allowed (the id tells the decks apart). A deck-only change writes the file.
    @MainActor @Test func addDeckWritesAndReturnsTheID() async throws {
        let dir = tempDir(), lib = await deckLibrary(dir)
        var before = lib.version
        #expect(lib.addDeck(game: "magic-the-gathering", name: "Burn", format: "constructed") == "d1")
        #expect(lib.version > before); before = lib.version
        #expect(lib.addDeck(game: "magic-the-gathering", name: "  ", format: "commander") == "d2")
        #expect(lib.addDeck(game: "magic-the-gathering", name: "", format: "commander") == "d3")
        #expect(lib.addDeck(game: "magic-the-gathering", name: "Burn", format: "constructed") == "d4")
        #expect(lib.version > before)
        #expect(lib.decks(game: "magic-the-gathering").map(\.name) == ["Burn", "Deck", "Deck 2", "Burn"])
        #expect(lib.deck(game: "magic-the-gathering", id: "d1")
                == Deck(id: "d1", name: "Burn", format: "constructed", active: false, cards: []))
        #expect(lib.deck(game: "magic-the-gathering", id: "none") == nil)
        #expect(lib.decks(game: "riftbound").isEmpty)
        await lib.flush()
        #expect(try storedFile(dir, "magic-the-gathering").decks == lib.decks(game: "magic-the-gathering"))
        #expect(try UserFiles.read(dir.appending(path: "riftbound.json")) == nil)
    }

    /// Review Focus 5: each edit applies to the deck as it is in memory at that moment, so two edits made from one old copy
    /// of the page both count; both reach the file. An edit cannot change the deck's id.
    @MainActor @Test func changeDeckAppliesItsEditToTheDeckAsItIsThen() async throws {
        let dir = tempDir(), lib = await deckLibrary(dir)
        let id = try #require(lib.addDeck(game: "riftbound", name: "Kai'Sa", format: "standard"))
        let plusOne: (Deck) -> Deck = { deck in
            let now = deck.cards.first { $0.id == "bolt|main" }?.count ?? 0
            return DeckRules.setting(deck, count: now + 1, cardKey: "bolt", name: "Bolt", section: "main")
        }
        var before = lib.version
        lib.changeDeck(game: "riftbound", id: id, plusOne)
        #expect(lib.version > before); before = lib.version
        lib.changeDeck(game: "riftbound", id: id, plusOne)
        #expect(lib.version > before)
        #expect(lib.deck(game: "riftbound", id: id)?.cards.map(\.count) == [2])
        lib.changeDeck(game: "riftbound", id: id) { deck in
            var deck = deck
            deck.id = "other"; deck.active = true
            return deck
        }
        #expect(lib.deck(game: "riftbound", id: id)?.active == true); #expect(lib.deck(game: "riftbound", id: "other") == nil)
        // An edit that changes nothing is not a change.
        let same = lib.version
        lib.changeDeck(game: "riftbound", id: id) { $0 }
        #expect(lib.version == same)
        await lib.flush()
        let stored = try storedFile(dir, "riftbound").decks
        #expect(stored.map(\.id) == [id]); #expect(stored[0].cards.map(\.count) == [2]); #expect(stored[0].active)
    }

    /// `changeDeck` on a deck that is gone (removed here or on another device) does nothing and writes nothing.
    @MainActor @Test func changeDeckOnARemovedDeckDoesNothing() async throws {
        let dir = tempDir(), lib = await deckLibrary(dir), file = dir.appending(path: "yu-gi-oh.json")
        let keep = try #require(lib.addDeck(game: "yu-gi-oh", name: "A", format: "standard"))
        let gone = try #require(lib.addDeck(game: "yu-gi-oh", name: "B", format: "standard"))
        lib.removeDeck(game: "yu-gi-oh", id: gone)
        #expect(lib.decks(game: "yu-gi-oh").map(\.id) == [keep])
        await lib.flush()
        let bytes = try Data(contentsOf: file), before = lib.version
        var called = false
        lib.changeDeck(game: "yu-gi-oh", id: gone) { called = true; return $0 }
        lib.removeDeck(game: "yu-gi-oh", id: gone)
        await lib.flush()
        #expect(!called); #expect(lib.version == before); #expect(try Data(contentsOf: file) == bytes)
        #expect(try storedFile(dir, "yu-gi-oh").decks.map(\.id) == [keep])
    }

    /// `moveDeck` puts a deck at an index of the deck order (an index past the end is the end) and writes the order.
    @MainActor @Test func moveDeckReorders() async throws {
        let dir = tempDir(), lib = await deckLibrary(dir)
        for name in ["A", "B", "C"] { lib.addDeck(game: "cyberpunk", name: name, format: "standard") }
        var before = lib.version
        lib.moveDeck(game: "cyberpunk", id: "d3", to: 0)
        #expect(lib.decks(game: "cyberpunk").map(\.name) == ["C", "A", "B"]); #expect(lib.version > before)
        lib.moveDeck(game: "cyberpunk", id: "d3", to: 9)
        #expect(lib.decks(game: "cyberpunk").map(\.name) == ["A", "B", "C"])
        lib.moveDeck(game: "cyberpunk", id: "d1", to: 1)
        #expect(lib.decks(game: "cyberpunk").map(\.name) == ["B", "A", "C"])
        before = lib.version
        lib.moveDeck(game: "cyberpunk", id: "d1", to: 1)                          // where it is already
        lib.moveDeck(game: "cyberpunk", id: "none", to: 0)
        #expect(lib.version == before)
        await lib.flush()
        #expect(try storedFile(dir, "cyberpunk").decks.map(\.name) == ["B", "A", "C"])
    }

    /// A refused file (newer, or `decks` of the wrong type) refuses every deck function: nothing in memory, nothing
    /// written, no version bump. Before the first load, too.
    @MainActor @Test func aRefusedFileRefusesEveryDeckChange() async throws {
        for onDisk in [Data(#"{"version":2,"decks":[{"id":"a","name":"A","format":"standard","cards":[]}]}"#.utf8),
                       Data(#"{"version":1,"collection":[],"decks":3}"#.utf8)] {
            let dir = tempDir(), file = dir.appending(path: "riftbound.json")
            try onDisk.write(to: file)
            let lib = await deckLibrary(dir)
            #expect(lib.problem(game: "riftbound") != nil); #expect(!lib.canChange(game: "riftbound"))
            let before = lib.version
            #expect(lib.addDeck(game: "riftbound", name: "B", format: "standard") == nil)
            lib.changeDeck(game: "riftbound", id: "a") { var d = $0; d.name = "Z"; return d }
            lib.removeDeck(game: "riftbound", id: "a")
            lib.moveDeck(game: "riftbound", id: "a", to: 0)
            await lib.flush()
            #expect(lib.version == before); #expect(try Data(contentsOf: file) == onDisk)
            #expect(lib.decks(game: "riftbound").isEmpty); #expect(lib.deck(game: "riftbound", id: "a") == nil)
        }
        let unloaded = UserLibrary(folder: tempDir(), watcher: nil, newID: { "x" })
        #expect(unloaded.addDeck(game: "riftbound", name: "B", format: "standard") == nil)
        #expect(unloaded.decks(game: "riftbound").isEmpty)
        let loaded = await deckLibrary(tempDir())
        #expect(loaded.addDeck(game: "no-such-game", name: "B", format: "standard") == nil)
    }

    /// A deck change leaves `collection`, `wanted`, `forSale` and `sold` byte-equal in the file, unknown keys included,
    /// and the clamp still runs on a later list change.
    @MainActor @Test func aDeckChangeLeavesTheOtherListsByteEqual() async throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.json")
        let json = #"{"version":1,"collection":[{"productID":1,"finish":"Normal","count":2,"condition":"","name":"A","k":1}],"wanted":[{"cardKey":"a","name":"A","count":1,"pinProductID":3,"note":"x"}],"forSale":[{"productID":1,"finish":"Normal","count":2,"name":"A"}],"sold":[{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","price":0.07,"priceIsLow":false},{"productID":9,"price":"1"}],"future":{"a":1}}"#
        // In this app's own form first, so the comparison is about the lists, not the layout.
        try UserFiles.write(try GameUserFile(data: Data(json.utf8)).data(), to: file)
        let original = try Data(contentsOf: file)
        let lib = await deckLibrary(dir)
        let id = try #require(lib.addDeck(game: "riftbound", name: "D", format: "standard"))
        lib.changeDeck(game: "riftbound", id: id) { DeckRules.setting($0, count: 3, cardKey: "a", name: "A", section: "main") }
        await lib.flush()
        let after = try Data(contentsOf: file)
        #expect(after != original)
        func part(_ data: Data, _ key: String) throws -> Data {
            let value = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?[key])
            return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        for key in ["collection", "wanted", "forSale", "sold", "future"] {
            #expect(try part(after, key) == part(original, key), "\(key)")
        }
        // The text of the file is the original with the decks key added (it sorts between collection and forSale).
        var text = String(decoding: after, as: UTF8.self)
        let decksStart = try #require(text.range(of: "  \"decks\" : ["))
        let decksEnd = try #require(text.range(of: "  \"forSale\" : ["))
        text.removeSubrange(decksStart.lowerBound..<decksEnd.lowerBound)
        #expect(text == String(decoding: original, as: UTF8.self))
        // The one change path still clamps for sale to owned.
        lib.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A")
        #expect(lib.forSaleCount(game: "riftbound", key: .init(productID: 1, finish: "Normal")) == 1)
        #expect(lib.saleNotice == "1 copy is no longer for sale.")
        #expect(lib.decks(game: "riftbound").map(\.id) == [id])
    }

    /// Phase 3A task 5: the decks of a game's file this build cannot read (kept raw, not listed) are counted for the
    /// sidebar's line; a change keeps them and their count; a refused file and a game with no file count none.
    @MainActor @Test func unreadableDecksAreCounted() async throws {
        let dir = tempDir()
        try Data(#"{"version":1,"decks":[{"id":"a","name":"A","format":"standard","active":false,"cards":[]},{"name":"no id"},{"id":"b","name":"B","format":"standard","active":"yes","cards":[]},{"id":"a","name":"twice","format":"standard","active":false,"cards":[]}]}"#.utf8)
            .write(to: dir.appending(path: "riftbound.json"))
        try Data(#"{"version":2,"decks":[{"name":"x"}]}"#.utf8).write(to: dir.appending(path: "cyberpunk.json"))
        let lib = await deckLibrary(dir)
        #expect(lib.decks(game: "riftbound").map(\.id) == ["a"])
        #expect(lib.unreadableDecks(game: "riftbound") == 3)
        #expect(lib.unreadableDecks(game: "cyberpunk") == 0)
        #expect(lib.unreadableDecks(game: "yu-gi-oh") == 0)
        lib.changeDeck(game: "riftbound", id: "a") { var d = $0; d.active = true; return d }
        #expect(lib.unreadableDecks(game: "riftbound") == 3)
        await lib.flush()
        let lib2 = await deckLibrary(dir)
        #expect(lib2.unreadableDecks(game: "riftbound") == 3)
    }

    /// Final fix B8: the library says how many cards of a deck this build cannot read; 0 for a deck without any, a deck
    /// that is not there, and a refused file.
    @MainActor @Test func aDecksUnreadableCardsAreCountedByTheLibrary() async throws {
        let dir = tempDir()
        try Data(#"{"version":1,"decks":[{"id":"a","name":"A","format":"standard","active":false,"cards":[{"cardKey":"k","section":"main","count":"2"}]}]}"#.utf8)
            .write(to: dir.appending(path: "riftbound.json"))
        try Data(#"{"version":2,"decks":[{"id":"a","cards":[1]}]}"#.utf8).write(to: dir.appending(path: "cyberpunk.json"))
        let lib = await deckLibrary(dir)
        #expect(lib.unreadableCards(game: "riftbound", deck: "a") == 1)
        #expect(lib.unreadableCards(game: "riftbound", deck: "b") == 0)
        #expect(lib.unreadableCards(game: "cyberpunk", deck: "a") == 0)
        lib.changeDeck(game: "riftbound", id: "a") { var d = $0; d.active = true; return d }
        #expect(lib.unreadableCards(game: "riftbound", deck: "a") == 1)
    }

    /// Review Focus 4: a reload that removes a deck (deleted on another device) bumps `version`, and the deck is gone.
    @MainActor @Test func aReloadThatRemovesADeckBumpsTheVersion() async throws {
        let dir = tempDir(), watcher = FakeWatcher(), file = dir.appending(path: "riftbound.json")
        let lib = await deckLibrary(dir, watcher: watcher)
        let id = try #require(lib.addDeck(game: "riftbound", name: "D", format: "standard"))
        await lib.flush()
        var other = try storedFile(dir, "riftbound")
        other.decks = []
        try UserFiles.write(try other.data(), to: file)
        let before = lib.version
        await watcher.fire(file)
        #expect(lib.version > before); #expect(lib.deck(game: "riftbound", id: id) == nil)
        #expect(lib.decks(game: "riftbound").isEmpty)
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
