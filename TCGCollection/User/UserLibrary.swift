import Foundation
import Observation

/// What the user owns, wants, has for sale and sold, and the user's decks, per game, in memory, kept in the user folder as one `<game id>.json`
/// per game. Every change goes through it: memory first, then the whole game file, written on one serial path in the
/// order of the changes.
/// - It keeps each game's `GameUserFile`, not only its lists, so that what a newer app wrote survives a rewrite.
/// - No for-sale count in memory is over its owned count (C8): each change, and each file read, lowers it and says so
///   (`saleNotice`). A read writes nothing: the file keeps its counts until the next change of that game writes them.
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
    /// of every such change are summed until `clearSaleNotice()`; a load starts the count afresh.
    private(set) var saleNotice: String?
    /// "The sale was not saved: <the game's problem>": the write of a change that held a sale was refused (the file
    /// became one this app must not rewrite between the read and the write), so the sale was dropped with it. Until
    /// `clearUnsavedSaleNotice()`.
    private(set) var unsavedSaleNotice: String?
    /// "The change was not saved: <game> was just read from your folder. Do it again.": a change that would have created
    /// the game's file found a file (or an iCloud placeholder) of it on disk at the write (it arrived after the read; task 5
    /// fix round 1 (c)). Nothing was written, the game was read again. Until `clearUnsavedChangeNotice()`.
    private(set) var unsavedChangeNotice: String?
    /// The games whose change `unsavedChangeNotice` is about, in the order they were refused (final fix A3, B6: an import
    /// and "Continue" say them their own way). Until `clearUnsavedChangeNotice()`.
    private(set) var unsavedChangeGames: [String] = []
    /// "The change was not saved: <the game's problem>": the write of a profile change (a Settings toggle) failed or was
    /// refused (not "appeared", which `unsavedChangeNotice` says). G13 hides the problem of a game just turned off from the
    /// sidebar, so it is said once in the status line (final fix A9). Until `clearUnsavedProfileNotice()`.
    private(set) var unsavedProfileNotice: String?
    /// True when `load` found no folder at `folder`, or a reload found it gone: changes are refused until another folder
    /// is used, or (gone after the load) until a reload finds it back.
    private(set) var folderIsMissing = false

    /// Each game's file as read or changed here. No entry: the game has no file yet (or it is refused).
    private var files: [String: GameUserFile] = [:]
    /// Per game, the decks of its file as read that this build cannot parse (kept whole, not listed). A change keeps them
    /// (`GameUserFile` writes them back), so the count changes only with a read.
    private var unreadableDeckCounts: [String: Int] = [:]
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
    /// The id of a new deck (a UUID string; tests inject their own).
    @ObservationIgnored private let newID: () -> String
    /// The time zone of a sold record's day.
    @ObservationIgnored private let timeZone: TimeZone
    /// The copies `saleNotice` counts.
    @ObservationIgnored private var copiesOffSale = 0
    /// Games whose memory holds a sale that no write has saved yet: a refused write of such a game drops a sale.
    @ObservationIgnored private var unsavedSales: Set<String> = []
    /// Games whose state in memory started from no file (a change with no file of the game read): their next write creates
    /// the file, and refuses when one is on disk by then (`UserFilesError.appeared`). A read of the game or a write that
    /// succeeded ends it.
    @ObservationIgnored private var creates: Set<String> = []
    /// Per game, the profile last known on disk: read (`apply`), or written by a write that succeeded. A refused game
    /// shows it (final fix A8). Emptied at a load and a folder switch.
    @ObservationIgnored private var knownProfiles: [String: GameProfile] = [:]
    /// Games whose memory holds a profile change that no write has saved yet: a failed or refused write of such a game is
    /// said (`unsavedProfileNotice`, final fix A9).
    @ObservationIgnored private var unsavedProfiles: Set<String> = []
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
         timeZone: TimeZone = .autoupdatingCurrent, newID: @escaping () -> String = { UUID().uuidString }) {
        self.folder = folder
        self.watcher = watcher
        self.now = now
        self.timeZone = timeZone
        self.newID = newID
    }

    // MARK: Reading

    /// Every problem, folder first, then refused files, failed writes and unsettled conflicts, in game order. G13: only
    /// followed games' problems (a game that is not followed keeps its own, `problem(game:)`). A refused file's profile is
    /// not read, so its game counts as followed.
    var problems: [String] {
        var list: [String] = []
        if folderIsMissing, let folder { list.append(Self.missingFolder(folder)) }
        let followed = followedGames
        for kind in [refused, writeFailures, conflictFailures] {
            for game in followed { if let text = kind[game], !list.contains(text) { list.append(text) } }
        }
        return list
    }

    /// The ids of the followed games (G3), in the games' order, from the profiles in memory (all on for a game without a
    /// file, a refused file, and before the first read): every game when none is followed.
    var followedGames: [String] {
        let ids = Games.all.map(\.id)
        return GameSelection.followed(Dictionary(uniqueKeysWithValues: ids.map { ($0, profile(game: $0)) }), games: ids)
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

    /// The game's decks, in the user's deck order.
    func decks(game: String) -> [Deck] { shown(game).decks }

    func deck(game: String, id: String) -> Deck? { decks(game: game).first { $0.id == id } }

    /// The decks of the game's file that this build cannot read (a key of the wrong type, no id, a second deck of one id):
    /// kept in the file, not listed. 0 for a game with no file or a refused one.
    func unreadableDecks(game: String) -> Int {
        refused[game] == nil && files[game] != nil ? unreadableDeckCounts[game] ?? 0 : 0
    }

    /// The cards of a deck that this build cannot read (kept inside the deck in the file, not listed; final fix B8). 0 for
    /// a deck without any, a deck that is not there, and a game with no file or a refused one.
    func unreadableCards(game: String, deck id: String) -> Int {
        refused[game] == nil ? files[game]?.unreadableCards(deck: id) ?? 0 : 0
    }

    /// The user's sharing answers of the game (E1) by card key: `true` shared between decks, `false` bought for each deck.
    /// A card without an answer is not in it. Empty for a game with no file or a refused one.
    func sharing(game: String) -> [String: Bool] {
        Dictionary(shown(game).sharing.map { ($0.cardKey, $0.shared) }, uniquingKeysWith: { first, _ in first })
    }

    /// The game's profile (G1, G2): whether the user follows it and his roles in it. All on for a game without a file, a
    /// file refused at its first read (its profile is not read) and an unknown game.
    /// Final fix A8: a game whose file is refused after it was known (a write refused, a reload refused) keeps the profile
    /// last known on disk (read or written here) for the rest of the run, so a game set off does not show again.
    func profile(game: String) -> GameProfile {
        refused[game] != nil ? knownProfiles[game] ?? .all : shown(game).profile
    }

    /// After the folder's first read: whether it has a file of any known game, read or refused (newer, unreadable, not
    /// downloaded from iCloud), or one written here since (G11: a folder without one is new); a file still to be created,
    /// or whose create failed, does not count (`hasFile`). False before the read and for a missing folder.
    var hasGameFile: Bool { Games.all.contains { hasFile(game: $0.id) } }

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

    func clearUnsavedSaleNotice() { unsavedSaleNotice = nil }

    func clearUnsavedChangeNotice() {
        unsavedChangeNotice = nil
        unsavedChangeGames = []
    }

    func clearUnsavedProfileNotice() { unsavedProfileNotice = nil }

    /// What `unsavedChangeNotice` says for one game.
    nonisolated static func unsavedChangeText(_ game: String) -> String {
        "The change was not saved: \(Games.game(game)?.name ?? game) was just read from your folder. Do it again."
    }

    /// The game has a file in the folder as far as this run knows: one read (or refused at a read), or one written here.
    /// Not a file this app is still to create, or failed to create (`creates`): it is not on disk (final fix A2).
    func hasFile(game: String) -> Bool { (files[game] != nil && !creates.contains(game)) || refused[game] != nil }

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

    /// Refused as `setCount` is. `nil` takes the pin away, also a pin this build cannot read (its keys are not written any
    /// more); a card not on the list changes nothing.
    func setPin(_ pin: PrintingKey?, game: String, cardKey: String) {
        change(game) { $0.setPin(pin, cardKey: cardKey) }
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
    /// finds nothing left. A sale whose write is refused is said (`unsavedSaleNotice`).
    @discardableResult
    func sell(_ count: Int, game: String, key: PrintingKey, price: ShownPrice?) -> Bool {
        let day = Self.day(of: now(), in: timeZone)
        let sold = change(game) { file in
            guard let sold = ListRules.selling(file, key: key, count: count, day: day, price: price) else { return }
            file = sold
        }
        if sold { unsavedSales.insert(game) }
        return sold
    }

    /// Refused as `setCount` is (nil). Appends a new deck that is not active (A14) and returns its id. An empty or blank
    /// name becomes "Deck" made unique among the game's deck names; a name another deck has is kept (the id tells them
    /// apart).
    /// `cards` (a paste) are summed into the new deck in the same change (`DeckRules.adding`): one write, and a refused
    /// change leaves no deck.
    @discardableResult
    func addDeck(game: String, name: String, format: String, cards: [DeckCard] = []) -> String? {
        let id = newID()
        var added = false
        change(game) { file in
            guard !file.decks.contains(where: { $0.id == id }) else { return }
            let blank = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let shownName = blank ? DeckRules.uniqueName("Deck", among: file.decks.map(\.name)) : name
            file.decks.append(DeckRules.adding(DeckRules.new(name: shownName, format: format, id: id), cards))
            added = true
        }
        return added ? id : nil
    }

    /// The one way to change a deck: `edit` gets the deck as it is in memory at this moment, inside the change, so two
    /// edits made one after the other both count (Review Focus 5). Its result replaces the deck, with the deck's id kept.
    /// Nothing happens when the deck is gone, or when refused as `setCount` is; an edit that changes nothing writes
    /// nothing.
    func changeDeck(game: String, id: String, _ edit: (Deck) -> Deck) {
        change(game) { file in
            guard let i = file.decks.firstIndex(where: { $0.id == id }) else { return }
            var deck = edit(file.decks[i])
            deck.id = id
            file.decks[i] = deck
        }
    }

    /// Refused as `setCount` is. A18: sets or clears one deck card's printing ("Use this printing" / "Any printing" on a
    /// card page); clearing also drops a `productID` this build could not read (`GameUserFile.setPrinting`). A deck or a
    /// card that is gone changes nothing.
    func setDeckPrinting(_ productID: Int?, game: String, deck id: String, key: DeckCardKey) {
        change(game) { $0.setPrinting(productID, deck: id, key: key) }
    }

    /// Refused as `setCount` is. A deck that is gone changes nothing.
    func removeDeck(game: String, id: String) {
        change(game) { file in file.decks.removeAll { $0.id == id } }
    }

    /// Refused as `setCount` is. Puts the deck at `index` of the deck order (an index past the end is the end).
    func moveDeck(game: String, id: String, to index: Int) {
        change(game) { file in
            guard let i = file.decks.firstIndex(where: { $0.id == id }) else { return }
            let deck = file.decks.remove(at: i)
            file.decks.insert(deck, at: min(max(index, 0), file.decks.count))
        }
    }

    /// Refused as `setCount` is. Sets several cards' sharing answers in one change (one write): `nil` removes a card's
    /// answer. An answer already there keeps its place in the file; a new one is added after the others, in card-key
    /// order. Answers equal to the stored ones write nothing.
    func setShared(_ answers: [String: Bool?], game: String) {
        change(game) { file in
            for (cardKey, answer) in answers.sorted(by: { $0.key < $1.key }) {
                let i = file.sharing.firstIndex { $0.cardKey == cardKey }
                switch (i, answer) {
                case let (i?, shared?): file.sharing[i].shared = shared
                case let (i?, nil): file.sharing.remove(at: i)
                case let (nil, shared?): file.sharing.append(SharingEntry(cardKey: cardKey, shared: shared))
                case (nil, nil): break
                }
            }
        }
    }

    /// Whether `setProfile` can change the game's profile: as `canChange` (G2: a game whose file this app must not rewrite
    /// keeps its read profile).
    func canSetProfile(game: String) -> Bool { canChange(game: game) }

    /// Refused as `setCount` is. Sets the game's profile in one change (G1, G2); a game without a file gets its file. The
    /// same profile writes nothing (a file without `profile` keeps its bytes), except over a `profile` this build could not
    /// read, which it replaces (`GameUserFile.setProfile`). `writesKey` (onboarding's "Continue", G11): the `profile` key is
    /// written also when the profile is all on, so a game without a file gets one and the folder is no longer new.
    func setProfile(_ profile: GameProfile, game: String, writesKey: Bool = false) {
        if change(game, { $0.setProfile(profile, writesKey: writesKey) }) { unsavedProfiles.insert(game) }
    }

    /// Memory first, then a write of the whole file is queued. Refused without a trace when the game cannot change.
    /// `edit` changes the game's file in place; a for-sale count it leaves over its owned count is lowered in the same
    /// change (C8). False when refused, or when the edit changed nothing the file holds (nothing is written then).
    @discardableResult
    private func change(_ game: String, _ edit: (inout GameUserFile) -> Void) -> Bool {
        // Only a known game (`canChange`): its id becomes a file name.
        guard canChange(game: game), let folder else { return false }
        let current = files[game] ?? GameUserFile()
        var file = current
        edit(&file)
        // Not only the lists: a pin this build cannot read, cleared, changes what is written (B3).
        guard file != current else { return false }
        addToSaleNotice(clampForSale(&file))
        if files[game] == nil { creates.insert(game) }
        files[game] = file
        version += 1
        let number = changes[game, default: 0] + 1
        changes[game] = number
        enqueue { await self.write(game, change: number, to: folder) }
        return true
    }

    /// C8, the one clamp: every for-sale count over its printing's owned count is lowered to it. Run on every change and
    /// on every file read into memory. Returns the copies taken off.
    private func clampForSale(_ file: inout GameUserFile) -> Int {
        let (forSale, lost) = ListRules.clamped(file.forSale, to: file.collection)
        if lost > 0 { file.forSale = forSale }
        return lost
    }

    /// Adds `lost` copies to `saleNotice` (nothing for 0).
    private func addToSaleNotice(_ lost: Int) {
        guard lost > 0 else { return }
        copiesOffSale += lost
        saleNotice = copiesOffSale == 1 ? "1 copy is no longer for sale." : "\(copiesOffSale) copies are no longer for sale."
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
            error = await Self.store(try file.data(), at: folder.appending(path: "\(game).json"),
                                     creating: creates.contains(game))
        } catch let encoding {
            error = encoding
        }
        guard let error else {
            creates.remove(game)
            writeFailures[game] = nil
            // The whole state is on disk, every sale and profile in it too.
            unsavedSales.remove(game)
            unsavedProfiles.remove(game)
            knownProfiles[game] = file.profile
            return
        }
        if case .appeared? = error as? UserFilesError {
            // Fix round 1 (c): a file of the game arrived after the read. Nothing was written; memory drops the change and
            // reads the game from disk, so it holds the real file; the change is said once.
            let shownBefore = shown(game)
            files[game] = nil
            creates.remove(game)
            writeFailures[game] = nil
            unsavedSales.remove(game)
            unsavedProfiles.remove(game)
            if !shown(game).hasSameLists(as: shownBefore) { version += 1 }
            unsavedChangeNotice = Self.unsavedChangeText(game)
            unsavedChangeGames.removeAll { $0 == game }
            unsavedChangeGames.append(game)
            queueReload(game, in: folder)
            return
        }
        if let refusal = error as? UserFilesError {
            // The file on disk must not be replaced (item 5): the game is read-only for this run, as a refused file at load.
            let shownBefore = shown(game)
            files[game] = nil
            refused[game] = Self.refusedText("\(game).json", refusal)
            writeFailures[game] = nil
            if !shown(game).hasSameLists(as: shownBefore) { version += 1 }
            // The dropped state held a sale (A3): say so once. Other dropped changes are said by the problem line only.
            if unsavedSales.remove(game) != nil, let problem = problem(game: game) {
                unsavedSaleNotice = "The sale was not saved: \(problem)"
            }
            sayUnsavedProfile(game)
            return
        }
        var isDirectory: ObjCBool = false
        let folderThere = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        writeFailures[game] = folderThere ? "\(game).json could not be saved (\(error.localizedDescription))." : Self.missingFolder(folder)
        sayUnsavedProfile(game)
    }

    /// A9: the dropped or failed write held a profile change: "The change was not saved: <the game's problem>", once.
    private func sayUnsavedProfile(_ game: String) {
        guard unsavedProfiles.remove(game) != nil, let problem = problem(game: game) else { return }
        unsavedProfileNotice = "The change was not saved: \(problem)"
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
        unreadableDeckCounts = [:]
        refused = [:]
        writeFailures = [:]
        conflictFailures = [:]
        unsavedSales = []
        unsavedProfiles = []
        creates = []
        knownProfiles = [:]
        // The reads of this load say what they take off sale; a notice not yet said about the memory just dropped would
        // count the same copies twice (B2).
        clearSaleNotice()
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
        unreadableDeckCounts = [:]
        refused = [:]
        writeFailures = [:]
        conflictFailures = [:]
        unsavedSales = []
        unsavedProfiles = []
        creates = []
        knownProfiles = [:]
        notice = nil
        folderIsMissing = false
        watcher?.stop()
        self.folder = folder
        await load()
    }

    /// Reads every game's file of the folder again, now (not from memory; task 5 fix round 1 (b): "Continue" looks at the
    /// folder before it writes). Returns when the reads have run. Nothing before the folder's load or for a folder missing
    /// at the load; a folder that went away after the load is looked at again (its return is seen: final fix A2).
    /// A file this app failed to create (`creates` with a failed write) is not on disk: memory drops that change, so the
    /// read applies and the next change creates the file again (final fix A2: "Continue" again after a failed write).
    func readAgain() async {
        guard let folder, readsAgain else { return }
        await flush()
        for game in creates where writeFailures[game] != nil {
            let shownBefore = shown(game)
            files[game] = nil
            writeFailures[game] = nil
            creates.remove(game)
            unsavedSales.remove(game)
            unsavedProfiles.remove(game)
            if !shown(game).hasSameLists(as: shownBefore) { version += 1 }
        }
        var last: Task<Void, Never>?
        for game in Games.all { last = queueReload(game.id, in: folder) }
        await last?.value
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
    /// added then survive the next write. A for-sale count over its owned count (a phase 2B device lowered an owned count;
    /// Review Focus 2) is lowered in memory and said (`clampForSale`); the read writes nothing, and the file keeps it
    /// until the next change of the game writes the lowered list. A refused file is not shown, so not clamped.
    private func apply(_ result: GameRead, to game: String) {
        unreadableDeckCounts[game] = result.unreadableDecks
        switch result.content {
        case .file(var file):
            creates.remove(game)
            let lost = clampForSale(&file)
            // A read that changes nothing on screen (the same file read again) says nothing again. With no file of the game
            // in memory (a load, a file that was missing or refused) what it takes off is new, also when the clamp leaves
            // every list empty (B1).
            if files[game].map({ !file.hasSameLists(as: $0) }) ?? true { addToSaleNotice(lost) }
            files[game] = file
            refused[game] = nil
            knownProfiles[game] = file.profile
        case .missing:
            files[game] = nil
            refused[game] = nil
            knownProfiles[game] = nil
        case .refused(let text):
            creates.remove(game)
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
        /// The elements of the file's `decks` that `GameUserFile` did not parse.
        var unreadableDecks = 0
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
        var unreadableDecks = 0
        do {
            if let data = try UserFiles.read(url) {
                let file = try GameUserFile(data: data)
                content = .file(file)
                unreadableDecks = Self.deckElements(in: data) - file.decks.count
            } else {
                content = .missing
            }
        } catch let error as UserFilesError {
            content = .refused(refusedText(name, error))
        } catch GameUserFileError.newerVersion {
            content = .refused(refusedText(name, .notRewritable(newerVersion: true)))
        } catch {
            content = .refused(refusedText(name, .notRewritable(newerVersion: false)))
        }
        return GameRead(content: content, backup: backup, conflictFailure: conflictFailure,
                        unreadableDecks: max(0, unreadableDecks))
    }

    /// The number of elements of the file's `decks` array (0 without one). Every element is either a parsed deck or a deck
    /// `GameUserFile` keeps whole, so the difference to its parsed decks is the unreadable ones.
    private nonisolated static func deckElements(in data: Data) -> Int {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["decks"] as? [Any])?.count ?? 0
    }

    /// The problem of a game file that is not used in this run.
    private nonisolated static func refusedText(_ name: String, _ reason: UserFilesError) -> String {
        switch reason {
        case .notRewritable(newerVersion: true): "\(name) was written by a newer version of the app."
        case .notRewritable(newerVersion: false): "\(name) cannot be read."
        case .notDownloaded: "\(name) is not downloaded from iCloud yet."
        case .appeared: "\(name) was just read from your folder."
        }
    }

    @concurrent private nonisolated static func store(_ data: Data, at url: URL, creating: Bool) async -> (any Error)? {
        do {
            try UserFiles.writeGameFile(data, to: url, creating: creating)
            return nil
        } catch {
            return error
        }
    }

    private nonisolated static func missingFolder(_ folder: URL) -> String {
        "The collection folder is not at \(folder.path)."
    }
}
