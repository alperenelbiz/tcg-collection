import Foundation
import Observation

/// One CSV import, from the file's bytes to the rows written: parse, look the products up, compare with the collection
/// (`CollectionImport`), and apply what the user confirmed. `ImportSheet` shows it; nothing is written before `apply()`.
/// - `prepare` waits until the collection has been read: compared with a collection not read yet, every printing of the
///   file would be new and no row would be offered for removal.
/// - A game of the file is imported only when its collection can change and its catalog is settled with products, now and
///   when its comparison was made (`block(game:)`). While its catalog step is still to come or running, every line could
///   read as "not in the catalog". While a `prepare` runs, Import is off (`isPreparing`).
/// - Import is on only when it would write (`writes`): rows that are only kept write nothing.
/// - `apply` writes only the comparison that is shown: when the collection changed since it was made, it is made again,
///   nothing is written, and the sheet shows the new one (`notice`).
@Observable
final class ImportModel: Identifiable {
    enum State: Equatable {
        case reading
        /// One sentence: the file is not an export, or it could not be read.
        case failed(String)
        case ready
    }

    /// Why the lines of one game are not imported.
    nonisolated enum Block: Equatable, Sendable {
        /// The collection cannot change (the folder is missing, the game's file is refused): the comparison is shown with
        /// the reason.
        case collection(String)
        /// The game's catalog is not ready: the comparison would be wrong, so only the reason is shown.
        case catalog(String)

        var text: String {
            switch self {
            case .collection(let text), .catalog(let text): text
            }
        }

        /// The comparison is not shown: made on a catalog that is not ready, it would be wrong.
        var hidesComparison: Bool {
            if case .catalog = self { true } else { false }
        }
    }

    /// What `apply` did: the first game it imported (the Collection shows it), every game it changed, in order (their
    /// writes are queued; `AppModel.importApplied` waits for them), and the summary it applied.
    nonisolated struct Applied: Equatable, Sendable {
        let gameID: String
        let games: [String]
        let summary: String
    }

    nonisolated static let notAnExport = "This is not a TCGplayer collection export."
    nonisolated static let matches = "This file matches your collection."
    nonisolated static let noGame = "This file has no cards of the four games."
    nonisolated static let nothingImportable = "Nothing in this file can be imported now."
    nonisolated static let nothingToImport = "Nothing to import: this file adds nothing to your collection."
    nonisolated static let catalogUpdating = "The catalog is being updated. This game can be imported when the update is done."
    nonisolated static let catalogEmpty = "The catalog has no cards of this game yet. Import the file again once it has downloaded."
    nonisolated static let noFolder = "No collection folder is chosen."
    nonisolated static let collectionChanged = "Your collection changed while this sheet was open. Check the comparison again."

    nonisolated static func unreadable(_ reason: String) -> String { "This file could not be read (\(reason))." }

    let fileName: String
    private(set) var state: State = .reading
    /// One per game that the file has lines of, in the order of `Games.all`.
    private(set) var comparisons: [ImportComparison] = []
    /// Lines of no game: what the parse skipped and the lines of other games, by line.
    private(set) var skipped: [SkippedLine] = []
    /// The rows of "In your collection, not in this file" chosen for removal. Off by default (spec 5.2).
    var remove: Set<PrintingKey> = []
    /// The comparison was made again because the collection changed while it was shown; it stays while the sheet is open.
    private(set) var notice: String?

    @ObservationIgnored private let data: Data?
    @ObservationIgnored private let readFailure: String?
    @ObservationIgnored private let library: UserLibrary
    @ObservationIgnored private let reader: CatalogStore
    /// The finishes it has for a product give a new row its finish's spelling (`CollectionImport.compare`).
    @ObservationIgnored private let prices: PriceTable?
    @ObservationIgnored private let catalogSettled: @MainActor (String) -> Bool
    /// What a game's catalog was when the game's comparison was made. Only `.ready` makes the game importable: a
    /// comparison made during a download stays blocked until a `prepare` made after the step ended (fix round 1).
    private nonisolated enum CatalogState: Sendable { case downloading, empty, ready }

    /// True while a `prepare` runs: Import is off, and the comparison on screen stays until the new one is made.
    private(set) var isPreparing = false
    /// Tests only: runs on the main actor before the products are looked up, so a test can act while a `prepare` runs.
    @ObservationIgnored var beforeLookup: (@MainActor () async -> Void)?

    /// The file, parsed once by the first `prepare`.
    @ObservationIgnored private var parsed: (lines: [CSVLine], skipped: [SkippedLine])?
    /// What the last `prepare` read: the products of the file and of the collection's rows (per game), the set names, and
    /// each game's catalog at that time.
    private var products: [Int: ProductRecord] = [:]
    private var setNames: [Int: String] = [:]
    private var catalogAtCompare: [String: CatalogState] = [:]
    /// The product ids the last `prepare` asked the catalog for: the file's and the collection's, of the file's games.
    @ObservationIgnored private var lookedUp: Set<Int> = []
    /// The collection holds a product of a game of the file that the last lookup did not read (a row added elsewhere):
    /// the comparison is not trusted, and Import is off, until a full `prepare` (`needsPrepare`) has read it.
    private(set) var lookupIsStale = false
    /// `library.version` when `comparisons` were made.
    @ObservationIgnored private var comparedVersion: Int?
    /// Each `prepare` takes the next number; only the latest one stores what it made.
    @ObservationIgnored private var preparation = 0

    /// `catalogSettled`: `AppModel.catalogSettled(game:)`, read whenever the sheet asks (it changes while the sheet is open).
    /// `prices`: the app's price table, read at every comparison; without one, a new row keeps the file's spelling.
    init(data: Data, fileName: String, library: UserLibrary, reader: CatalogStore, prices: PriceTable? = nil,
         catalogSettled: @escaping @MainActor (String) -> Bool) {
        self.fileName = fileName
        self.data = data
        readFailure = nil
        self.library = library
        self.reader = reader
        self.prices = prices
        self.catalogSettled = catalogSettled
    }

    /// A file that could not be read: `prepare` ends in `.failed` with the reason.
    init(unreadable reason: String, fileName: String, library: UserLibrary, reader: CatalogStore) {
        self.fileName = fileName
        data = nil
        readFailure = Self.unreadable(reason)
        self.library = library
        self.reader = reader
        prices = nil
        catalogSettled = { _ in false }
    }

    // MARK: Preparing

    /// Waits for the collection's first read, parses the file (once), looks the products up (through `reader`, off the
    /// main thread) and compares. Called again when `needsPrepare` turns true: the comparison then stays on screen, with
    /// Import off (`isPreparing`), until the new one is made; a Remove choice that still applies is kept. A `prepare` that
    /// a later one overtook, or that was cancelled, stores nothing and never fails.
    func prepare() async {
        guard let data else {
            state = .failed(readFailure ?? Self.notAnExport)
            return
        }
        preparation += 1
        let number = preparation
        isPreparing = true
        defer { if number == preparation { isPreparing = false } }
        if state != .ready { state = .reading }
        await waitForCollection()
        guard !Task.isCancelled else { return }
        let file: (lines: [CSVLine], skipped: [SkippedLine])
        if let parsed {
            file = parsed
        } else {
            do {
                file = try await Self.parse(data)
            } catch {
                state = .failed(Self.notAnExport)
                return
            }
            parsed = file
        }
        await beforeLookup?()
        var found: [Int: ProductRecord] = [:], names: [Int: String] = [:], catalogs: [String: CatalogState] = [:]
        var queried: Set<Int> = []
        for game in Games.all {
            let fileIDs = file.lines.filter { Games.game(productLine: $0.productLine)?.id == game.id }.map(\.productID)
            guard !fileIDs.isEmpty else { continue }
            // Read before the lookup: a step that ends during the lookup may have left products out of it.
            let settled = catalogSettled(game.id)
            do {
                // A closed sheet cancels its `prepare`: no lookup is started for it.
                try Task.checkCancellation()
                let ids = fileIDs + library.rows(game: game.id).map(\.productID)
                queried.formUnion(ids)
                found.merge(try await reader.products(ids: ids, game: game.id)) { first, _ in first }
                for set in try await reader.sets(game: game.id) { names[set.groupID] = set.name }
                let hasProducts = try await reader.hasProducts(game: game.id)
                catalogs[game.id] = !settled ? .downloading : hasProducts ? .ready : .empty
            } catch {
                // A cancelled `prepare` (the sheet closed, or a newer one took over) is no failure.
                guard !(error is CancellationError), !Task.isCancelled else { return }
                // A comparison already shown stays; a first one cannot be made.
                if state != .ready { state = .failed("The catalog could not be read (\(error.localizedDescription)).") }
                return
            }
        }
        guard !Task.isCancelled, number == preparation else { return }
        products = found
        setNames = names
        catalogAtCompare = catalogs
        lookedUp = queried
        let (made, otherGames) = compare(file.lines)
        comparisons = made
        comparedVersion = library.version
        // A row added during the lookup may hold a product it did not read: then one more `prepare`.
        lookupIsStale = collectionHasUnreadProducts
        skipped = (file.skipped + otherGames).sorted { $0.line < $1.line }
        remove.formIntersection(missingKeys)
        state = .ready
    }

    /// Until the folder's first read has ended (or there is no folder to read): compared with a collection not read yet,
    /// every printing of the file would be new.
    private func waitForCollection() async {
        let library = library
        let read = Observations { @MainActor in library.isLoaded || library.folderIsMissing || library.folder == nil }
        for await isRead in read where isRead { return }
    }

    @concurrent private nonisolated static func parse(_ data: Data) async throws -> (lines: [CSVLine], skipped: [SkippedLine]) {
        try CollectionCSV.parse(data)
    }

    private func compare(_ lines: [CSVLine]) -> (comparisons: [ImportComparison], otherGames: [SkippedLine]) {
        let current = Dictionary(uniqueKeysWithValues: Games.all.map { ($0.id, library.rows(game: $0.id)) })
        let known = products, prices = prices
        // The price table is per game: a product's finishes are looked up in its own game's.
        let priced = { (id: Int) in
            known[id].map { product in prices?.prices(game: product.gameID, productID: id).map(\.finish) ?? [] } ?? []
        }
        return CollectionImport.compare(lines: lines, current: current, known: { known[$0] }, pricedFinishes: priced,
                                        games: Games.all)
    }

    /// A row of a game of the file holds a product id the last lookup did not ask for.
    private var collectionHasUnreadProducts: Bool {
        comparisons.contains { comparison in
            library.rows(game: comparison.gameID).contains { !lookedUp.contains($0.productID) }
        }
    }

    /// True when the sheet must run `prepare` again (it does when this turns true): a game whose comparison was made while
    /// its catalog downloaded is settled now, or the collection holds a product the last lookup did not read
    /// (`lookupIsStale`). Not while a `prepare` runs. A first `prepare` on a settled catalog leaves nothing due. A game
    /// recorded as `.empty` (settled, no products) is not due: its `prepare` would record the same and run again forever;
    /// the sheet tells the user to import the file again.
    var needsPrepare: Bool {
        guard !isPreparing, state == .ready else { return false }
        return lookupIsStale || comparisons.contains { catalogAtCompare[$0.gameID] == .downloading && catalogSettled($0.gameID) }
    }

    private var missingKeys: Set<PrintingKey> { Set(comparisons.flatMap { $0.missing.map(\.key) }) }

    // MARK: What the sheet shows

    /// Why the lines of `game` are not imported, or nil when they are. The folder and the catalog are read live (they
    /// change while the sheet is open); the catalog must also have been settled, with products of the game, when the
    /// game's comparison was made: a comparison made during a download stays blocked until the next `prepare`.
    func block(game: String) -> Block? {
        if !library.canChange(game: game) {
            return .collection(library.problem(game: game) ?? (library.folder == nil ? Self.noFolder : "Your collection is not read yet."))
        }
        if !catalogSettled(game) { return .catalog(Self.catalogUpdating) }
        switch catalogAtCompare[game] {
        case .ready?: return nil
        case .empty?: return .catalog(Self.catalogEmpty)
        case .downloading?, nil: return .catalog(Self.catalogUpdating)
        }
    }

    /// The comparisons that `apply` writes.
    var importable: [ImportComparison] {
        comparisons.filter { block(game: $0.gameID) == nil }
    }

    /// True when Import would write: a game that can be imported has a new or changed printing, or a row set to Remove.
    /// Rows that are only kept write nothing.
    var writes: Bool { importable.contains(where: writes) }

    private func writes(_ comparison: ImportComparison) -> Bool {
        !comparison.new.isEmpty || !comparison.changed.isEmpty || comparison.missing.contains { remove.contains($0.key) }
    }

    /// True when Import is on: the comparison is made, no `prepare` runs, and Import would write.
    var canApply: Bool { state == .ready && !isPreparing && !lookupIsStale && writes }

    /// What Import does, over the games it imports: "12 new, 3 changed, 2 not in the file (kept)", or one sentence.
    var summary: String {
        guard !comparisons.isEmpty else { return Self.noGame }
        let shown = importable
        guard !shown.isEmpty else { return Self.nothingImportable }
        let new = shown.reduce(0) { $0 + $1.new.count }, changed = shown.reduce(0) { $0 + $1.changed.count }
        let missing = shown.flatMap(\.missing)
        var parts: [String] = []
        if new > 0 { parts.append("\(new) new") }
        if changed > 0 { parts.append("\(changed) changed") }
        if !missing.isEmpty {
            let removed = missing.filter { remove.contains($0.key) }.count, kept = missing.count - removed
            let choice = removed == 0 ? "kept" : kept == 0 ? "removed" : "\(removed) removed, \(kept) kept"
            parts.append("\(missing.count) not in the file (\(choice))")
        }
        if parts.isEmpty { return Self.matches }
        // Only kept rows: Import would write nothing, so it is not offered until a row is set to Remove.
        return writes ? parts.joined(separator: ", ") : Self.nothingToImport
    }

    /// "Not imported": what the parse skipped, other games, and every line not recognised, by line. The lines
    /// of a game whose catalog is not ready are left out: they are not known to be missing from it.
    var notImported: [SkippedLine] {
        let lines = comparisons.filter { block(game: $0.gameID)?.hidesComparison != true }
            .flatMap { $0.notRecognised }
        return (skipped + lines).sorted { $0.line < $1.line }
    }

    /// True when a shown group offers Remove ("In your collection, not in this file" of a game whose groups are shown):
    /// the sheet's tables then keep a choice column in every row, so the numbers stay in one column. Else the names take
    /// that width.
    var offersRemove: Bool {
        comparisons.contains { !$0.missing.isEmpty && block(game: $0.gameID)?.hidesComparison != true }
    }

    /// The name of the set of the printing's product; nil when the catalog does not have it.
    func setName(of key: PrintingKey) -> String? {
        products[key.productID].flatMap { setNames[$0.groupID] }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The printings among `changes` that would read the same as another one in a table (same name, any case, and same
    /// finish): the sheet adds their set's name.
    nonisolated static func ambiguous(_ changes: [ImportComparison.Change]) -> Set<PrintingKey> {
        let label = { (change: ImportComparison.Change) in "\(change.name.lowercased())\u{0}\(change.key.finish.lowercased())" }
        let counts = Dictionary(changes.map { (label($0), 1) }, uniquingKeysWith: +)
        return Set(changes.filter { counts[label($0), default: 0] > 1 }.map(\.key))
    }

    // MARK: Choosing

    /// "Remove all" (true) or "Keep all" (false) for the rows of `game` in "In your collection, not in this file".
    func setAllMissing(remove: Bool, game: String) {
        let keys = Set(comparisons.first { $0.gameID == game }?.missing.map(\.key) ?? [])
        if remove { self.remove.formUnion(keys) } else { self.remove.subtract(keys) }
    }

    /// True when every row of `game` in "In your collection, not in this file" is set to Remove.
    func allMissingRemoved(game: String) -> Bool {
        let missing = comparisons.first { $0.gameID == game }?.missing ?? []
        return !missing.isEmpty && missing.allSatisfy { remove.contains($0.key) }
    }

    // MARK: Applying

    /// Makes the comparison again when the collection changed since it was made (a reload from disk, a change elsewhere).
    /// True when the new one differs from the one shown: `notice` then says so.
    @discardableResult
    func refreshComparison() -> Bool {
        guard state == .ready, comparedVersion != library.version else { return false }
        comparedVersion = library.version
        // A row of a product the last lookup did not read: the cached products cannot describe it. A full `prepare` comes
        // (`needsPrepare`); until it has run, Import is off.
        if collectionHasUnreadProducts {
            lookupIsStale = true
            notice = Self.collectionChanged
            return true
        }
        // The lines and products of the last `prepare`: no file read and no lookup, so the new comparison is there at once.
        let fresh = compare(parsed?.lines ?? []).comparisons
        guard fresh != comparisons else { return false }
        comparisons = fresh
        remove.formIntersection(missingKeys)
        notice = Self.collectionChanged
        return true
    }

    /// One `library.replace` per game that can be imported: new and changed rows, and the missing rows set to Remove.
    /// Nil when nothing is written: nothing to import, a `prepare` runs, or the collection changed since the comparison
    /// was shown (it is shown again first). `Applied.gameID` is the first game that is written, `Applied.games` every one.
    @discardableResult
    func apply() -> Applied? {
        guard canApply, !refreshComparison() else { return nil }
        let games = importable
        let changed = games.filter(writes).map(\.gameID)
        guard let first = changed.first else { return nil }
        let applied = Applied(gameID: first, games: changed, summary: summary)
        for comparison in games {
            let rows = library.rows(game: comparison.gameID)
            library.replace(game: comparison.gameID, rows: CollectionImport.apply(comparison, to: rows, remove: remove))
        }
        // Our own change: the sheet closes on it, and must not call it a change made elsewhere meanwhile.
        comparedVersion = library.version
        return applied
    }
}
