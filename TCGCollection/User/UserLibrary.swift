import Foundation
import Observation

/// What the user owns, wants, has for sale and sold, per game, in memory, kept in the user folder as one `<game id>.json`
/// per game. Every change goes through it: memory first, then the whole game file, written on one serial path in the
/// order of the changes.
/// - It keeps each game's `GameUserFile`, not only its lists, so that what a newer app wrote survives a rewrite.
/// - No for-sale count is over its owned count after a change (C8): each change lowers it in the same change and says so
///   (`saleNotice`). A file read with more for sale than owned is kept as it is until the next change of that game.
/// - A game whose file was refused (newer, unreadable, not downloaded) is read-only for this run: no rows, no change,
///   and the file is never touched. The other games keep working.
/// - A folder that is missing at launch is said (`problem`) and nothing is written; a write never makes a folder. A
///   folder that a reload finds gone is said the same way; memory keeps its rows until a reload finds the folder back.
/// - When another device changed a file (the watcher), the file is read again on the same serial path. A write of ours
///   that is still queued for that game goes first, then the file is read again: the last writer wins on disk.
@Observable
final class UserLibrary {
    private(set) var folder: URL?
    /// A conflict was settled: "Two devices changed <game>. The older version is saved as <file name>." Until
    /// `clearNotice()`.
    private(set) var notice: String?
    /// Goes up on every change of a list (here or from another device), so views read them again.
    private(set) var version = 0
    /// "<n> copies are no longer for sale.": a change made here lowered for-sale counts to the owned ones (C8). The copies
    /// of every such change are summed until `clearSaleNotice()`.
    private(set) var saleNotice: String?
    /// True when `load` found no folder at `folder`, or a reload found it gone: changes are refused until another folder
    /// is used, or (gone after the load) until a reload finds it back.
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
    /// False until the first `load()` of the current folder has finished, and again while the folder is switched; it stays
    /// false for a folder missing at load (one that goes away later is `folderIsMissing` only). A change while it is false
    /// is refused: it would start from an empty file and replace the owner's file.
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
    /// The time zone of a sold record's day.
    @ObservationIgnored private let timeZone: TimeZone
    /// The copies `saleNotice` counts.
    @ObservationIgnored private var copiesOffSale = 0
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

    init(folder: URL?, watcher: (any UserFileWatching)?, now: @escaping () -> Date = { Date() },
         timeZone: TimeZone = .autoupdatingCurrent) {
        self.folder = folder
        self.watcher = watcher
        self.now = now
        self.timeZone = timeZone
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

    func rows(game: String) -> [CollectionRow] { shown(game).collection }

    func count(game: String, key: PrintingKey) -> Int {
        CollectionRules.count(rows(game: game), for: key)
    }

    func wanted(game: String) -> [WantedEntry] { shown(game).wanted }

    func forSale(game: String) -> [SaleEntry] { shown(game).forSale }

    func sold(game: String) -> [SoldRecord] { shown(game).sold }

    func wantedCount(game: String, cardKey: String) -> Int {
        wanted(game: game).first { $0.cardKey == cardKey }?.count ?? 0
    }

    func forSaleCount(game: String, key: PrintingKey) -> Int {
        forSale(game: game).first { $0.key == key }?.count ?? 0
    }

    /// The game's file as the screens see it: empty when there is none, or when it is refused.
    private func shown(_ game: String) -> GameUserFile {
        refused[game] == nil ? files[game] ?? Self.noFile : Self.noFile
    }

    /// What `shown` gives for a game with no file in memory.
    private static let noFile = GameUserFile()

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

    func clearSaleNotice() {
        saleNotice = nil
        copiesOffSale = 0
    }

    // MARK: Changing

    /// Refused (nothing changes, nothing is written) while `isLoaded` is false, for a game whose file is refused, and for
    /// an unknown game id. Like every change, it lowers a for-sale count over the new owned count.
    func setCount(_ count: Int, game: String, key: PrintingKey, name: String) {
        change(game) { $0.collection = CollectionRules.setting($0.collection, count: count, for: key, name: name) }
    }

    /// Refused as `setCount` is. The CSV import's write: a printing it removes or lowers leaves the For Sale list too.
    func replace(game: String, rows: [CollectionRow]) {
        change(game) { $0.collection = rows }
    }

    /// Refused as `setCount` is. 0 removes the card from the list.
    func setWanted(_ count: Int, game: String, cardKey: String, name: String) {
        change(game) { $0.wanted = ListRules.settingWanted($0.wanted, count: count, cardKey: cardKey, name: name) }
    }

    /// Refused as `setCount` is. `nil` takes the pin away; a card not on the list changes nothing.
    func setPin(_ pin: PrintingKey?, game: String, cardKey: String) {
        change(game) { $0.wanted = ListRules.pinning($0.wanted, cardKey: cardKey, to: pin) }
    }

    /// Refused as `setCount` is. The count is clamped to the owned count of the printing; 0 removes it from the list.
    func setForSale(_ count: Int, game: String, key: PrintingKey, name: String) {
        change(game) { file in
            file.forSale = ListRules.settingForSale(file.forSale, count: count, key: key, name: name,
                                                    owned: CollectionRules.count(file.collection, for: key))
        }
    }

    /// C7: sells `count` copies of a printing on the For Sale list: the owned and for-sale counts go down and one record
    /// with today's day (`now`, in `timeZone`) and `price` is added, in one change. False (nothing changes) when refused
    /// as `setCount` is, or when `count` is under 1 or more than are for sale or owned: a second click on "Sold all"
    /// finds nothing left.
    @discardableResult
    func sell(_ count: Int, game: String, key: PrintingKey, price: ShownPrice?) -> Bool {
        let day = Self.day(of: now(), in: timeZone)
        return change(game) { file in
            guard let sold = ListRules.selling(file, key: key, count: count, day: day, price: price) else { return }
            file = sold
        }
    }

    /// Memory first, then a write of the whole file is queued. Refused without a trace when the game cannot change.
    /// `edit` changes the game's file in place; a for-sale count it leaves over its owned count is lowered in the same
    /// change (C8). False when refused, or when the edit left every list as it was (nothing is written then).
    @discardableResult
    private func change(_ game: String, _ edit: (inout GameUserFile) -> Void) -> Bool {
        // Only a known game (`canChange`): its id becomes a file name.
        guard canChange(game: game), let folder else { return false }
        let current = files[game] ?? GameUserFile()
        var file = current
        edit(&file)
        guard !file.hasSameLists(as: current) else { return false }
        let (forSale, lost) = ListRules.clamped(file.forSale, to: file.collection)
        file.forSale = forSale
        files[game] = file
        if lost > 0 {
            copiesOffSale += lost
            saleNotice = copiesOffSale == 1 ? "1 copy is no longer for sale." : "\(copiesOffSale) copies are no longer for sale."
        }
        version += 1
        let number = changes[game, default: 0] + 1
        changes[game] = number
        enqueue { await self.write(game, change: number, to: folder) }
        return true
    }

    /// `yyyy-MM-dd` of `date` in `timeZone`, in the Gregorian calendar.
    private nonisolated static func day(of date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
            let shownBefore = shown(game)
            files[game] = nil
            refused[game] = Self.refusedText("\(game).json", refusal)
            writeFailures[game] = nil
            if !shown(game).hasSameLists(as: shownBefore) { version += 1 }
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
    /// read, or nil. Not for a folder that was missing at load (nothing of it was read); a folder that went away after
    /// the load is read again, so its return is seen.
    @discardableResult
    func fileChanged(_ url: URL) -> Task<Void, Never>? {
        guard let folder, readsAgain, let game = UserFiles.gameID(ofFileNamed: url.lastPathComponent),
              UserFolder.isSameFolder(url.deletingLastPathComponent(), folder) else { return nil }
        return queueReload(game, in: folder)
    }

    /// A reload may run: the folder is there, or it went away after its load had ended (`isLoaded`).
    private var readsAgain: Bool { !folderIsMissing || isLoaded }

    @discardableResult
    private func queueReload(_ game: String, in folder: URL) -> Task<Void, Never> {
        let number = reloads[game, default: 0] + 1
        reloads[game] = number
        return enqueue { await self.reload(game, number: number, in: folder) }
    }

    private func reload(_ game: String, number: Int, in folder: URL) async {
        guard reloads[game] == number, self.folder == folder, readsAgain else { return }
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
        // The folder itself is gone (moved away while the app runs): its files read as missing, but the rows are not
        // gone. Memory keeps them, and changes are refused while the folder is missing, so no write can leave a file of
        // only the new rows. A reload after the folder is back reads its file.
        var isDirectory: ObjCBool = false
        let folderThere = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if folderIsMissing == folderThere { folderIsMissing = !folderThere }
        guard folderThere else { return }
        let shownBefore = shown(game)
        apply(result, to: game)
        if !shown(game).hasSameLists(as: shownBefore) { version += 1 }
    }

    /// Takes a read into memory. The whole file replaces memory, also when its lists are the same: keys another device
    /// added then survive the next write. A for-sale count over its owned count is kept as read (Review Focus 2): a read
    /// writes nothing, and the next change of the game lowers it.
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
