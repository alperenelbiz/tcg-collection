import Foundation
import Observation

/// One CSV import, from the file's bytes to the rows written: parse, look the products up, compare with the collection
/// (`CollectionImport`), and apply what the user confirmed. `ImportSheet` shows it; nothing is written before `apply()`.
/// - `prepare` waits until the collection has been read: compared with a collection not read yet, every printing of the
///   file would be new and no row would be offered for removal.
/// - A game of the file is imported only when its collection can change and its catalog is settled with products
///   (`block(game:)`). While its catalog step is still to come or running, every line could read as "not in the catalog".
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

    /// What `apply` did: the first game it imported (the Collection shows it) and the summary it applied.
    nonisolated struct Applied: Equatable, Sendable {
        let gameID: String
        let summary: String
    }

    nonisolated static let notAnExport = "This is not a TCGplayer collection export."
    nonisolated static let matches = "This file matches your collection."
    nonisolated static let noGame = "This file has no cards of the four games."
    nonisolated static let nothingImportable = "Nothing in this file can be imported now."
    nonisolated static let catalogDownloading = "The catalog is still downloading. This game can be imported when it is ready."
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
    @ObservationIgnored private let catalogSettled: @MainActor (String) -> Bool
    /// What the last `prepare` read: the file's lines, the products of the file and of the collection's rows (per game),
    /// the set names, and the games the catalog has products of.
    @ObservationIgnored private var lines: [CSVLine] = []
    private var products: [Int: ProductRecord] = [:]
    private var setNames: [Int: String] = [:]
    private var gamesWithProducts: Set<String> = []
    /// `library.version` when `comparisons` were made.
    @ObservationIgnored private var comparedVersion: Int?

    /// `catalogSettled`: `AppModel.catalogSettled(game:)`, read whenever the sheet asks (it changes while the sheet is open).
    init(data: Data, fileName: String, library: UserLibrary, reader: CatalogStore,
         catalogSettled: @escaping @MainActor (String) -> Bool) {
        self.fileName = fileName
        self.data = data
        readFailure = nil
        self.library = library
        self.reader = reader
        self.catalogSettled = catalogSettled
    }

    /// A file that could not be read: `prepare` ends in `.failed` with the reason.
    init(unreadable reason: String, fileName: String, library: UserLibrary, reader: CatalogStore) {
        self.fileName = fileName
        data = nil
        readFailure = Self.unreadable(reason)
        self.library = library
        self.reader = reader
        catalogSettled = { _ in false }
    }

    // MARK: Preparing

    /// Parses the file, waits for the collection's first read, looks the products up (through `reader`, off the main
    /// thread) and compares. Called again when the catalog changed (the sheet does it when a catalog step ends): the
    /// comparison then stays on screen until the new one is ready, and a Remove choice that still applies is kept.
    func prepare() async {
        guard let data else {
            state = .failed(readFailure ?? Self.notAnExport)
            return
        }
        if state != .ready { state = .reading }
        while !library.isLoaded && !library.folderIsMissing && library.folder != nil {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
        }
        let parsed: (lines: [CSVLine], skipped: [SkippedLine])
        do {
            parsed = try await Self.parse(data)
        } catch {
            state = .failed(Self.notAnExport)
            return
        }
        var found: [Int: ProductRecord] = [:], names: [Int: String] = [:], withProducts: Set<String> = []
        for game in Games.all {
            let fileIDs = parsed.lines.filter { Games.game(productLine: $0.productLine)?.id == game.id }.map(\.productID)
            guard !fileIDs.isEmpty else { continue }
            do {
                let ids = fileIDs + library.rows(game: game.id).map(\.productID)
                found.merge(try await reader.products(ids: ids, game: game.id)) { first, _ in first }
                for set in try await reader.sets(game: game.id) { names[set.groupID] = set.name }
                if try await reader.hasProducts(game: game.id) { withProducts.insert(game.id) }
            } catch {
                // A comparison already shown stays; a first one cannot be made.
                if state != .ready { state = .failed("The catalog could not be read (\(error.localizedDescription)).") }
                return
            }
        }
        guard !Task.isCancelled else { return }
        lines = parsed.lines
        products = found
        setNames = names
        gamesWithProducts = withProducts
        let (made, otherGames) = compare()
        comparisons = made
        comparedVersion = library.version
        skipped = (parsed.skipped + otherGames).sorted { $0.line < $1.line }
        remove.formIntersection(missingKeys)
        state = .ready
    }

    @concurrent private nonisolated static func parse(_ data: Data) async throws -> (lines: [CSVLine], skipped: [SkippedLine]) {
        try CollectionCSV.parse(data)
    }

    private func compare() -> (comparisons: [ImportComparison], otherGames: [SkippedLine]) {
        let current = Dictionary(uniqueKeysWithValues: Games.all.map { ($0.id, library.rows(game: $0.id)) })
        let known = products
        return CollectionImport.compare(lines: lines, current: current, known: { known[$0] }, games: Games.all)
    }

    private var missingKeys: Set<PrintingKey> { Set(comparisons.flatMap { $0.missing.map(\.key) }) }

    // MARK: What the sheet shows

    /// Why the lines of `game` are not imported, or nil when they are. Read live: the folder and the catalog change while
    /// the sheet is open.
    func block(game: String) -> Block? {
        if !library.canChange(game: game) {
            return .collection(library.problem(game: game) ?? (library.folder == nil ? Self.noFolder : "Your collection is not read yet."))
        }
        if !catalogSettled(game) { return .catalog(Self.catalogDownloading) }
        if !gamesWithProducts.contains(game) { return .catalog(Self.catalogEmpty) }
        return nil
    }

    /// The comparisons that `apply` writes.
    var importable: [ImportComparison] {
        comparisons.filter { block(game: $0.gameID) == nil }
    }

    /// True when Import is offered: a game that can be imported has a printing in one of the three groups.
    var canApply: Bool {
        state == .ready && importable.contains { !$0.new.isEmpty || !$0.changed.isEmpty || !$0.missing.isEmpty }
    }

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
        return parts.isEmpty ? Self.matches : parts.joined(separator: ", ")
    }

    /// "Not imported": what the parse skipped, other games, and every line not recognised or ignored, by line. The lines
    /// of a game whose catalog is not ready are left out: they are not known to be missing from it.
    var notImported: [SkippedLine] {
        let lines = comparisons.filter { block(game: $0.gameID)?.hidesComparison != true }
            .flatMap { $0.notRecognised + $0.ignoredBasics }
        return (skipped + lines).sorted { $0.line < $1.line }
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
        let fresh = compare().comparisons
        guard fresh != comparisons else { return false }
        comparisons = fresh
        remove.formIntersection(missingKeys)
        notice = Self.collectionChanged
        return true
    }

    /// One `library.replace` per game that can be imported: new and changed rows, and the missing rows set to Remove.
    /// Nil when nothing was applied: nothing to import, or the collection changed since the comparison was shown (it is
    /// shown again first). `Applied.gameID` is the first game with a printing in a group.
    @discardableResult
    func apply() -> Applied? {
        guard canApply, !refreshComparison() else { return nil }
        let games = importable
        let first = games.first { !$0.new.isEmpty || !$0.changed.isEmpty || !$0.missing.isEmpty } ?? games[0]
        let applied = Applied(gameID: first.gameID, summary: summary)
        for comparison in games {
            let rows = library.rows(game: comparison.gameID)
            library.replace(game: comparison.gameID, rows: CollectionImport.apply(comparison, to: rows, remove: remove))
        }
        // Our own change: the sheet closes on it, and must not call it a change made elsewhere meanwhile.
        comparedVersion = library.version
        return applied
    }
}
