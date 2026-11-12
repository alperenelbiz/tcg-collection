import Foundation
import Observation

/// What the user owns, per game, in memory, kept in the user folder as one `<game id>.json` per game. Every change goes
/// through it: memory first, then the whole game file, written on one serial path in the order of the changes.
/// - It keeps each game's `GameUserFile`, not only its rows, so that what a newer app wrote survives a rewrite.
/// - A game whose file was refused (newer, unreadable, not downloaded) is read-only for this run: no rows, no change,
///   and the file is never touched. The other games keep working.
/// - A folder that is missing at launch is said (`problem`) and nothing is written; a write never makes a folder.
/// - When another device changed a file (the watcher), the file is read again on the same serial path. A write of ours
///   that is still queued for that game goes first, then the file is read again: the last writer wins on disk.
@Observable
final class UserLibrary {
    private(set) var folder: URL?
    /// A conflict was settled: "Two devices changed <game>. The older version is saved as <file name>." Until
    /// `clearNotice()`.
    private(set) var notice: String?
    /// Goes up on every change of the rows (here or from another device), so views read them again.
    private(set) var version = 0
    /// True when `load` found no folder at `folder`: changes are refused until another folder is used.
    private(set) var folderIsMissing = false

    /// Each game's file as read or changed here. No entry: the game has no file yet (or it is refused).
    private var files: [String: GameUserFile] = [:]
    /// Games whose file is not used in this run, with the sentence that says why.
    private var refused: [String: String] = [:]
    /// Games whose last write failed, with the sentence. Memory then holds a change the file does not have: a reload of
    /// the game is not applied until the next successful write (the next change writes the whole state) clears it.
    private var writeFailures: [String: String] = [:]
    /// Games whose conflict versions could not be settled at the last read, with the sentence.
    private var conflictFailures: [String: String] = [:]
    /// False until the first `load()` of the current folder has finished, and again while the folder is switched or
    /// missing. A change while it is false is refused: it would start from an empty file and replace the owner's file.
    /// Controls that change the collection disable themselves on it.
    private(set) var isLoaded = false
    /// Tests only: runs on the main actor before each game file is read, so a test can act while a read is in progress.
    @ObservationIgnored var beforeRead: (@MainActor (URL) async -> Void)?
    #if DEBUG
    /// `-writeDelay` (DEBUG): each write of a game file waits this long first, so a UI test can quit the app while a write
    /// is still queued (the quit must wait for it).
    @ObservationIgnored var writeDelay: Duration?
    #endif

    @ObservationIgnored private let watcher: (any UserFileWatching)?
    @ObservationIgnored private let now: () -> Date
    /// The serial path: every write and every read of a game file runs after the one queued before it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var queued = 0
    @ObservationIgnored private var finished = 0
    /// Per game: the number of the last change made here, and of the last change whose write ran.
    @ObservationIgnored private var changes: [String: Int] = [:]
    @ObservationIgnored private var written: [String: Int] = [:]
    /// Per game: the number of the last reload asked for; an older queued reload is skipped.
    @ObservationIgnored private var reloads: [String: Int] = [:]
    /// Goes up at every `load()` and every folder switch: a load that a later one overtook never sets `isLoaded`.
    @ObservationIgnored private var loadGeneration = 0

    init(folder: URL?, watcher: (any UserFileWatching)?, now: @escaping () -> Date = { Date() }) {
        self.folder = folder
        self.watcher = watcher
        self.now = now
    }

    // MARK: Reading

    /// Every problem, folder first, then refused files, failed writes and unsettled conflicts, in game order.
    var problems: [String] {
        var list: [String] = []
        if folderIsMissing, let folder { list.append(Self.missingFolder(folder)) }
        for kind in [refused, writeFailures, conflictFailures] {
            for game in Games.all { if let text = kind[game.id], !list.contains(text) { list.append(text) } }
        }
        return list
    }

    /// The folder is missing, a file is newer than this app or cannot be read, or a write failed.
    var problem: String? { problems.first }

    /// True while a write or a read is queued or running.
    var hasPendingWork: Bool { finished != queued }

    func rows(game: String) -> [CollectionRow] {
        refused[game] == nil ? files[game]?.collection ?? [] : []
    }

    func count(game: String, key: PrintingKey) -> Int {
        CollectionRules.count(rows(game: game), for: key)
    }

    /// False where a change of the game is refused: before the folder is loaded, with no folder or a missing one, for a
    /// game whose file is refused, and for an unknown game id. Controls that change the collection disable themselves on
    /// it, so a refused change is never a silent one; `problem` says why.
    func canChange(game: String) -> Bool {
        isLoaded && folder != nil && !folderIsMissing && refused[game] == nil && Games.game(game) != nil
    }

    /// The game's own problem (its file refused, its last write failed, its conflict versions not settled), else the
    /// folder's (missing), else nil. The Collection and the card page show this one; the sidebar shows `problem`.
    func problem(game: String) -> String? {
        if let own = refused[game] ?? writeFailures[game] ?? conflictFailures[game] { return own }
        if folderIsMissing, let folder { return Self.missingFolder(folder) }
        return nil
    }

    /// Why a card page shows no counts and its controls are off; nil when the game can change (`canChange`).
    func countsLocked(game: String) -> String? {
        guard !canChange(game: game) else { return nil }
        return problem(game: game).map { "The counts cannot change: \($0)" } ?? "Reading your collection…"
    }

    func clearNotice() { notice = nil }

    // MARK: Changing

    /// Refused (nothing changes, nothing is written) while `isLoaded` is false, for a game whose file is refused, and for
    /// an unknown game id.
    func setCount(_ count: Int, game: String, key: PrintingKey, name: String) {
        change(game) { CollectionRules.setting($0, count: count, for: key, name: name) }
    }

    /// Refused as `setCount` is.
    func replace(game: String, rows: [CollectionRow]) {
        change(game) { _ in rows }
    }

    /// Memory first, then a write of the whole file is queued. Refused without a trace when the game cannot change.
    private func change(_ game: String, _ edit: ([CollectionRow]) -> [CollectionRow]) {
        // Only a known game (`canChange`): its id becomes a file name.
        guard canChange(game: game), let folder else { return }
        var file = files[game] ?? GameUserFile()
        let rows = edit(file.collection)
        guard rows != file.collection else { return }
        file.collection = rows
        files[game] = file
        version += 1
        let number = changes[game, default: 0] + 1
        changes[game] = number
        enqueue { await self.write(game, change: number, to: folder) }
    }

    /// Writes the game's state of change `number` into `target`, the folder of the change, unless a later change is
    /// queued (its write has the newer state) or the folder was switched since (the state belonged to the old folder).
    private func write(_ game: String, change number: Int, to target: URL) async {
        guard changes[game] == number else { return }
        defer { written[game] = number }
        #if DEBUG
        // After the check above, so a write that a later change replaced (it is skipped) does not wait.
        if let writeDelay { try? await Task.sleep(for: writeDelay) }
        #endif
        guard folder == target, let folder, let file = files[game] else { return }
        let error: (any Error)?
        do {
            error = await Self.store(try file.data(), at: folder.appending(path: "\(game).json"))
        } catch let encoding {
            error = encoding
        }
        guard let error else {
            writeFailures[game] = nil
            return
        }
        if let refusal = error as? UserFilesError {
            // The file on disk must not be replaced (item 5): the game is read-only for this run, as a refused file at load.
            let shown = rows(game: game)
            files[game] = nil
            refused[game] = Self.refusedText("\(game).json", refusal)
            writeFailures[game] = nil
            if rows(game: game) != shown { version += 1 }
            return
        }
        var isDirectory: ObjCBool = false
        let folderThere = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        writeFailures[game] = folderThere ? "\(game).json could not be saved (\(error.localizedDescription))." : Self.missingFolder(folder)
    }

    // MARK: Loading and reloading

    /// Reads every game's file of `folder` (conflicts settled first) and starts watching it. A missing folder is said;
    /// nothing is read, watched or written then. Nothing happens without a folder (the first-run sheet is open).
    func load() async {
        guard let folder else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoaded = false
        // A queued write keeps its state: it is written before memory is read again.
        await flush()
        // A later load or a folder switch took over during the wait.
        guard generation == loadGeneration, self.folder == folder else { return }
        watcher?.stop()
        files = [:]
        refused = [:]
        writeFailures = [:]
        conflictFailures = [:]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            folderIsMissing = true
            version += 1
            return
        }
        folderIsMissing = false
        // Watching starts before the first read, so a change during it is read again after it.
        watcher?.start(folder: folder) { [weak self] url in await self?.fileChanged(url)?.value }
        await enqueue {
            for game in Games.all {
                guard generation == self.loadGeneration else { return }
                let url = folder.appending(path: "\(game.id).json")
                await self.beforeRead?(url)
                let result = await Self.read(url, now: self.now())
                guard generation == self.loadGeneration else { return }
                self.apply(result, to: game.id)
            }
        }.value
        guard generation == loadGeneration else { return }
        isLoaded = true
        version += 1
    }

    /// After the folder sheet: writes what is queued to the old folder, stops watching it and loads `folder`. It does not
    /// copy or move a file.
    func use(folder: URL) async {
        await flush()
        // No `await` from here to `load()`: the old folder's state is gone before the new folder is set, so no change can
        // write the old rows into the new folder, and a load of the old folder that is still running never sets `isLoaded`.
        isLoaded = false
        loadGeneration += 1
        files = [:]
        refused = [:]
        writeFailures = [:]
        conflictFailures = [:]
        notice = nil
        folderIsMissing = false
        watcher?.stop()
        self.folder = folder
        await load()
    }

    /// A file of the folder changed (the watcher). Queues a read of it when it is a game file of this folder; returns that
    /// read, or nil.
    @discardableResult
    func fileChanged(_ url: URL) -> Task<Void, Never>? {
        guard let folder, !folderIsMissing, let game = UserFiles.gameID(ofFileNamed: url.lastPathComponent),
              UserFolder.isSameFolder(url.deletingLastPathComponent(), folder) else { return nil }
        return queueReload(game, in: folder)
    }

    @discardableResult
    private func queueReload(_ game: String, in folder: URL) -> Task<Void, Never> {
        let number = reloads[game, default: 0] + 1
        reloads[game] = number
        return enqueue { await self.reload(game, number: number, in: folder) }
    }

    private func reload(_ game: String, number: Int, in folder: URL) async {
        guard reloads[game] == number, self.folder == folder, !folderIsMissing else { return }
        // A write of ours for this game is queued: it goes first, then the file is read again (the last writer wins).
        guard changes[game, default: 0] == written[game, default: 0] else {
            queueReload(game, in: folder)
            return
        }
        // Our last write failed: memory holds a change the file does not have. It is not replaced; the next change writes
        // the whole state, and reloads are applied again after that write succeeded (item 8).
        guard writeFailures[game] == nil else { return }
        let before = changes[game, default: 0]
        let url = folder.appending(path: "\(game).json")
        await beforeRead?(url)
        let result = await Self.read(url, now: now())
        guard self.folder == folder else { return }
        // A change was made here during the read: memory is newer than what was read.
        guard changes[game, default: 0] == before else {
            queueReload(game, in: folder)
            return
        }
        let shown = rows(game: game)
        apply(result, to: game)
        if rows(game: game) != shown { version += 1 }
    }

    /// Takes a read into memory. The whole file replaces memory, also when its rows are the same: keys another device
    /// added then survive the next write.
    private func apply(_ result: GameRead, to game: String) {
        switch result.content {
        case .file(let file):
            files[game] = file
            refused[game] = nil
        case .missing:
            files[game] = nil
            refused[game] = nil
        case .refused(let text):
            files[game] = nil
            refused[game] = text
        }
        conflictFailures[game] = result.conflictFailure
        if let backup = result.backup {
            notice = "Two devices changed \(Games.game(game)?.name ?? game). The older version is saved as \(backup.lastPathComponent)."
        }
    }

    // MARK: The serial path

    /// Waits until every queued write and read is done (the tests, and before the app quits).
    func flush() async {
        while true {
            let mark = queued
            await tail?.value
            if queued == mark { return }
        }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        queued += 1
        let task = Task { @MainActor in
            await previous?.value
            await operation()
            self.finished += 1
        }
        tail = task
        return task
    }

    // MARK: File work, off the main actor

    private nonisolated struct GameRead: Sendable {
        enum Content: Sendable { case file(GameUserFile), missing, refused(String) }
        var content: Content
        var backup: URL?
        var conflictFailure: String?
    }

    /// Settles conflict versions, then reads and decodes one game file.
    @concurrent private nonisolated static func read(_ url: URL, now: Date) async -> GameRead {
        let name = url.lastPathComponent
        var backup: URL?, conflictFailure: String?
        do {
            backup = try UserFiles.resolveConflicts(of: url, now: now)
        } catch {
            // Every version stays where it was; the current one is read, and the next read tries again.
            conflictFailure = "Two devices changed \(name) and the older version could not be saved (\(error.localizedDescription))."
        }
        let content: GameRead.Content
        do {
            if let data = try UserFiles.read(url) { content = .file(try GameUserFile(data: data)) } else { content = .missing }
        } catch let error as UserFilesError {
            content = .refused(refusedText(name, error))
        } catch GameUserFileError.newerVersion {
            content = .refused(refusedText(name, .notRewritable(newerVersion: true)))
        } catch {
            content = .refused(refusedText(name, .notRewritable(newerVersion: false)))
        }
        return GameRead(content: content, backup: backup, conflictFailure: conflictFailure)
    }

    /// The problem of a game file that is not used in this run.
    private nonisolated static func refusedText(_ name: String, _ reason: UserFilesError) -> String {
        switch reason {
        case .notRewritable(newerVersion: true): "\(name) was written by a newer version of the app."
        case .notRewritable(newerVersion: false): "\(name) cannot be read."
        case .notDownloaded: "\(name) is not downloaded from iCloud yet."
        }
    }

    @concurrent private nonisolated static func store(_ data: Data, at url: URL) async -> (any Error)? {
        do {
            try UserFiles.writeGameFile(data, to: url)
            return nil
        } catch {
            return error
        }
    }

    private nonisolated static func missingFolder(_ folder: URL) -> String {
        "The collection folder is not at \(folder.path)."
    }
}
