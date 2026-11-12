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
    /// Games whose last write (or conflict step) failed, with the sentence. The next successful write clears it.
    private var failures: [String: String] = [:]
    /// False until the first read of the folder is done: a change before it would be lost by that read.
    private var loaded = false

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

    init(folder: URL?, watcher: (any UserFileWatching)?, now: @escaping () -> Date = { Date() }) {
        self.folder = folder
        self.watcher = watcher
        self.now = now
    }

    // MARK: Reading

    /// Every problem, folder first, then refused files, then failed writes, in game order.
    var problems: [String] {
        var list: [String] = []
        if folderIsMissing, let folder { list.append(Self.missingFolder(folder)) }
        for game in Games.all { if let text = refused[game.id] { list.append(text) } }
        for game in Games.all { if let text = failures[game.id], !list.contains(text) { list.append(text) } }
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

    func clearNotice() { notice = nil }

    // MARK: Changing

    func setCount(_ count: Int, game: String, key: PrintingKey, name: String) {
        change(game) { CollectionRules.setting($0, count: count, for: key, name: name) }
    }

    func replace(game: String, rows: [CollectionRow]) {
        change(game) { _ in rows }
    }

    /// Memory first, then a write of the whole file is queued. Refused without a trace when the game cannot change.
    private func change(_ game: String, _ edit: ([CollectionRow]) -> [CollectionRow]) {
        // Only a known game: its id becomes a file name.
        guard loaded, folder != nil, !folderIsMissing, refused[game] == nil, Games.game(game) != nil else { return }
        var file = files[game] ?? GameUserFile()
        let rows = edit(file.collection)
        guard rows != file.collection else { return }
        file.collection = rows
        files[game] = file
        version += 1
        let number = changes[game, default: 0] + 1
        changes[game] = number
        enqueue { await self.write(game, change: number) }
    }

    /// Writes the game's state of change `number`, unless a later change is queued: its write has the newer state.
    private func write(_ game: String, change number: Int) async {
        guard changes[game] == number else { return }
        defer { written[game] = number }
        guard let folder, let file = files[game] else { return }
        let error: (any Error)?
        do {
            error = await Self.store(try file.data(), at: folder.appending(path: "\(game).json"))
        } catch let encoding {
            error = encoding
        }
        guard let error else {
            failures[game] = nil
            return
        }
        var isDirectory: ObjCBool = false
        let folderThere = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        failures[game] = folderThere ? "\(game).json could not be saved (\(error.localizedDescription))." : Self.missingFolder(folder)
    }

    // MARK: Loading and reloading

    /// Reads every game's file of `folder` (conflicts settled first) and starts watching it. A missing folder is said;
    /// nothing is read, watched or written then. Nothing happens without a folder (the first-run sheet is open).
    func load() async {
        guard let folder else { return }
        // A queued write keeps its state: it is written before memory is read again.
        await flush()
        watcher?.stop()
        loaded = false
        files = [:]
        refused = [:]
        failures = [:]
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
                let result = await Self.read(folder.appending(path: "\(game.id).json"), now: self.now())
                self.apply(result, to: game.id)
            }
        }.value
        loaded = true
        version += 1
    }

    /// After the folder sheet: writes what is queued to the old folder, stops watching it and loads `folder`. It does not
    /// copy or move a file.
    func use(folder: URL) async {
        await flush()
        watcher?.stop()
        self.folder = folder
        notice = nil
        await load()
    }

    /// A file of the folder changed (the watcher). Queues a read of it when it is a game file of this folder; returns that
    /// read, or nil.
    @discardableResult
    func fileChanged(_ url: URL) -> Task<Void, Never>? {
        guard let folder, !folderIsMissing, let game = UserFiles.gameID(ofFileNamed: url.lastPathComponent),
              UserFolder.isSameFolder(url.deletingLastPathComponent(), folder) else { return nil }
        return queueReload(game)
    }

    @discardableResult
    private func queueReload(_ game: String) -> Task<Void, Never> {
        let number = reloads[game, default: 0] + 1
        reloads[game] = number
        return enqueue { await self.reload(game, number: number) }
    }

    private func reload(_ game: String, number: Int) async {
        guard reloads[game] == number, let folder, !folderIsMissing else { return }
        // A write of ours for this game is queued: it goes first, then the file is read again (the last writer wins).
        guard changes[game, default: 0] == written[game, default: 0] else {
            queueReload(game)
            return
        }
        let before = changes[game, default: 0]
        let result = await Self.read(folder.appending(path: "\(game).json"), now: now())
        guard self.folder == folder else { return }
        // A change was made here during the read: memory is newer than what was read.
        guard changes[game, default: 0] == before else {
            queueReload(game)
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
        if let failure = result.conflictFailure { failures[game] = failure }
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
        } catch GameUserFileError.newerVersion {
            content = .refused("\(name) was written by a newer version of the app.")
        } catch UserFilesError.notDownloaded {
            content = .refused("\(name) is not downloaded from iCloud yet.")
        } catch {
            content = .refused("\(name) cannot be read.")
        }
        return GameRead(content: content, backup: backup, conflictFailure: conflictFailure)
    }

    @concurrent private nonisolated static func store(_ data: Data, at url: URL) async -> (any Error)? {
        do {
            try UserFiles.write(data, to: url, creatingFolder: false)
            return nil
        } catch {
            return error
        }
    }

    private nonisolated static func missingFolder(_ folder: URL) -> String {
        "The collection folder is not at \(folder.path)."
    }
}
