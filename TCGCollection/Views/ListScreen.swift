import SwiftUI

// The parts of a list screen (the Collection, Wanted, For Sale): its state memory, the join of the rows with the
// catalog, and the shared views.

/// The state of a list screen (the Collection, Wanted, For Sale; a deck's is `DeckScreenState`) for one game, kept by `ScreenMemory`.
protocol GameScreenState: AnyObject {
    var gameID: String { get }
    init(gameID: String)
}

/// The window's state of one list screen: the current game's only; another game starts afresh, as All cards does. Not
/// observed: it hands out the same state for as long as the game stays.
final class ScreenMemory<State: GameScreenState> {
    private var current: State?

    func state(game: String) -> State {
        if let current, current.gameID == game { return current }
        let fresh = State(gameID: game)
        current = fresh
        return fresh
    }

    /// The window's game is now `game`: a state of another game is dropped, also while this screen is not on show, so
    /// every screen of the old game starts afresh (`RootView` calls it on every game switch).
    func keep(game: String) {
        if let current, current.gameID != game { self.current = nil }
    }
}

/// A list screen's join with the catalog (the Collection, For Sale, Wanted): what the latest join read, and what the
/// catalog said. Each list screen's state has its own, so the window keeps it with the screen. `Read` is what a screen
/// reads (`RowsJoin`: the collection's entries; `WantedJoin`: the wanted cards' printings).
@Observable
final class CatalogJoin<Read: Equatable & Sendable> {
    /// The last join that succeeded on a catalog with this game's products. Nil until one did.
    var read: Read?
    /// The latest join threw (the catalog could not be read): `read` stays as it was, and the next appearance of the
    /// screen tries again.
    var failed = false
    /// The catalog has products of this game. Without, the screen lists its rows alone.
    var catalogHasProducts = false
    /// What the latest join that ended read: a join with the same inputs is not done again (a return from another
    /// screen), unless it failed (`CollectionList.joinIsDue`).
    var joined: CollectionJoin?

    /// What a join of the game reads now.
    static func key(game: String, model: AppModel) -> CollectionJoin {
        CollectionJoin(game: game, libraryVersion: model.library.version, catalogVersion: model.catalogVersion,
                       priceDay: model.prices.day(game: game), catalogSettled: model.catalogSettled(game: game))
    }

    /// Joins once per `key`: when `key` differs from the last join or the last one failed, and only once the folder is
    /// read (`loaded`; before, the screen shows its loading layout). `read` reads through `reader` (off the main thread)
    /// with the game; then the join asks whether the game has products.
    /// - A read that throws keeps the last good read (a read error never turns rows into unknown ones), marks the join
    ///   failed with its key, and the next appearance of the screen tries again.
    /// - A cancelled join (the screen went away, or its key changed meanwhile) stores nothing.
    /// - Without products of the game nothing is kept: every product would be missing, the screen lists its rows alone.
    /// - The read is stored only when it differs, so a return to the screen with the same rows redraws nothing.
    /// Returns the read when the join stored it (a catalog with the game's products); else nil.
    @discardableResult
    func run(_ key: CollectionJoin, loaded: Bool, reader: CatalogStore,
             read reading: (CatalogStore, String) async throws -> Read) async -> Read? {
        guard loaded, CollectionList.joinIsDue(key, last: joined, lastFailed: failed) else { return nil }
        let value: Read, hasProducts: Bool
        do {
            value = try await reading(reader, key.game)
            hasProducts = try await reader.hasProducts(game: key.game)
        } catch {
            guard !Task.isCancelled else { return nil }
            failed = true
            joined = key
            return nil
        }
        guard !Task.isCancelled else { return nil }
        failed = false
        catalogHasProducts = hasProducts
        joined = key
        guard hasProducts else {
            read = nil
            return nil
        }
        if read != value { read = value }
        return value
    }
}

/// The game's collection rows joined with the catalog and the prices: what the Collection lists, and what For Sale lays
/// its printings on (`SaleList.entries`).
typealias RowsJoin = CatalogJoin<[CollectionEntry]>

extension CatalogJoin where Read == [CollectionEntry] {
    /// The joined entries, in the file's order (`read`).
    var entries: [CollectionEntry]? {
        get { read }
        set { read = newValue }
    }

    /// What a list screen lists (`CollectionList.content`); nil until a join of this game has ended. `listing` makes the
    /// screen's entries from the joined ones (For Sale: `SaleList.entries`); `rows` are what it lists without them. The
    /// catalog counts as settled as it was for the join that made the entries (`joined`), not as it is now: when a step
    /// ends, its last batch's products are not in the entries until the next join, and would read as "not in the catalog
    /// any more".
    func content(rows: [CollectionRow], listing: ([CollectionEntry]) -> [CollectionEntry] = { $0 }) -> CollectionContent? {
        guard let joined else { return nil }
        return CollectionList.content(rows: rows, joined: entries.map(listing), joinFailed: failed,
                                      catalogHasProducts: catalogHasProducts, catalogSettled: joined.catalogSettled)
    }

    /// Joins the game's rows with the catalog (products and set names through `reader`) and the prices (`run`). Filtering
    /// and sorting then run in memory on every keystroke. Returns the products and sets it read when it stored the
    /// entries (the Collection's Filter menu comes from them); else nil.
    @discardableResult
    func run(_ key: CollectionJoin, model: AppModel) async -> (products: [Int: ProductRecord], sets: [SetRecord])? {
        let rows = model.library.rows(game: key.game), prices = model.prices
        var menu: (products: [Int: ProductRecord], sets: [SetRecord])?
        let stored = await run(key, loaded: model.library.isLoaded, reader: model.reader) { reader, game in
            let products = try await reader.products(ids: rows.map(\.productID), game: game)
            let sets = try await reader.sets(game: game)
            menu = (products, sets)
            let names = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
            return CollectionList.entries(rows: rows, products: products, setNames: names) { prices.shown(game: game, key: $0) }
        }
        return stored == nil ? nil : menu
    }
}

/// What a list screen shows.
enum ListPhase {
    /// The folder is still read, or the first join of the game runs.
    case loading
    /// Nothing can be shown or changed (the folder is missing, the game's file is refused): the problem line says why.
    case unavailable
    case empty
    case list

    /// `listed`: what the screen lists, nil until a join of the game has ended.
    static func of(_ listed: CollectionContent?, game: String, library: UserLibrary) -> ListPhase {
        of(listing: listed.map { !$0.entries.isEmpty }, game: game, library: library)
    }

    /// `listing`: whether the screen lists anything (Wanted lists cards, not `CollectionContent`); nil until a join of the
    /// game has ended.
    static func of(listing: Bool?, game: String, library: UserLibrary) -> ListPhase {
        if listing == true { return .list }
        if library.canChange(game: game) { return listing == nil ? .loading : .empty }
        return library.problem(game: game) == nil ? .loading : .unavailable
    }
}

extension View {
    /// The frame of a list screen: the catalog's line (`note`, identifier `<name>-catalog-note`) and the library's lines
    /// above the content, the ground, the identifier `<name>-screen`, and the pages it pushes. The library's lines are on
    /// the screen and on its pages; the sidebar shows them only on other screens (`Screen.isList`).
    func listScreen(_ name: String, note: String?) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { CatalogNote(text: note, identifier: "\(name)-catalog-note") }
            .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            .background { Theme.ground.ignoresSafeArea() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(name)-screen")
            .navigationDestination(for: CardTarget.self) { target in
                CardPageView(cardKey: target.cardKey, startProductID: target.startProductID)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
            .navigationDestination(for: UnknownPrinting.self) { printing in
                UnknownPrintingPage(printing: printing)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
    }
}

/// What the catalog cannot give yet (`CollectionContent.note`): one muted line above a list's gallery. A deck page also
/// says with it that cards of the deck cannot be read (final fix B8).
struct CatalogNote: View {
    let text: String?
    let identifier: String

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.margin)
                .padding(.top, Theme.ruleSpacing)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// A gallery's grid (the cell rule): adaptive columns of at least `cellMinWidth`, the gaps and the outer margin. A grid
/// that is one of several in a page (a deck's groups) has no margin of its own (`padded` false): the page has it.
struct GalleryGrid<Cells: View>: View {
    var padded = true
    /// Where a cell sits in its grid row: `.top` when cells of a row may differ in height (a pending Wanted cell).
    var alignment: Alignment? = nil
    @ViewBuilder let cells: Cells

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cellMinWidth), spacing: Theme.columnGap, alignment: alignment)],
                  spacing: Theme.rowGap) {
            cells
        }
        .scrollTargetLayout()
        .padding(padded ? Theme.margin : 0)
    }
}

/// A list screen while the folder is read or its first join runs: the final layout with flat `surface` blocks where the
/// pictures will be. No shimmer.
struct LoadingGallery: View {
    /// About one window of the gallery.
    private static let placeholders = 12

    var body: some View {
        ScrollView {
            GalleryGrid { ForEach(0..<Self.placeholders, id: \.self) { _ in PlaceholderCell() } }
        }
    }
}

/// A list's cell of one printing (`CardCell`). A printing of the catalog opens its card page on that printing; one that
/// left a settled catalog opens its small page; a pending one (`CollectionCellLink.none`) opens nothing and takes no
/// hover. The caller gives it its identifier.
struct PrintingCell: View {
    let gameID: String
    let entry: CollectionEntry
    let link: CollectionCellLink

    var body: some View {
        let cell = CardCell(content: CellContent(product: entry.product, name: entry.name, left: entry.countText,
                                                 price: entry.price))
        switch (link, entry.product) {
        case (.card, let product?):
            NavigationLink(value: CardTarget(gameID: gameID, cardKey: entry.cardKey, startProductID: product.productID)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.accessibilityText)
        case (.unknownPrinting, _):
            NavigationLink(value: UnknownPrinting(gameID: gameID, key: entry.id, name: entry.name)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.accessibilityText)
        default:
            cell
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.accessibilityText)
        }
    }
}

/// "Make PDF…" in a list's toolbar, left of Sort (`doc.richtext`; the name is its label and help text): makes the PDF of
/// the screen's whole list (`job`), then the system's save panel opens (`pdfSaving`); when no PDF could be drawn the
/// status line says "The PDF could not be made.". While the export runs, its label is the progress ("Making PDF… 12 /
/// 40") and a click cancels it; a second export cannot start meanwhile. Off until the screen has read its list
/// (`enabled`).
struct PDFButton: View {
    let export: PDFExport
    let identifier: String
    let enabled: Bool
    let job: () -> PDFJob?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = export.progress {
            Button { export.cancel() } label: {
                Text(progress.label).monospacedDigit()
            }
            .help("Cancel the PDF")
            .accessibilityIdentifier(identifier)
        } else {
            Button {
                if let job = job() { export.start(job, pictures: model.pictures) { model.pdfEnded($0) } }
            } label: {
                Label("Make PDF…", systemImage: "doc.richtext")
            }
            .help("Make PDF…")
            .disabled(!enabled)
            .accessibilityIdentifier(identifier)
        }
    }
}

extension View {
    /// `-exportPDF`, on a list screen's root: once `ready` (`PDFExport.launchReady`: the list is read by a join on a settled
    /// catalog with the game's prices), the PDF of `job` is written to the launch's file, once, instead of the save panel.
    func launchPDF(_ export: PDFExport, screen: Screen, ready: Bool, model: AppModel, job: @escaping () -> PDFJob?) -> some View {
        onChange(of: ready, initial: true) { _, ready in
            guard ready, let file = model.takeLaunchPDF(for: screen), let job = job() else { return }
            export.start(job, pictures: model.pictures, writingTo: file) { model.pdfEnded($0) }
        }
    }

    /// The save step and the lifetime of a list's PDF, on the list's navigation stack (`RootView`), which stays while card
    /// pages are pushed on it. A made PDF opens the system's save panel (`fileExporter`, with the job's file name); one made
    /// while a card page is open opens when the list is on show again (macOS 27 does not present it over a pushed page). A
    /// failed save is said in the status line (`AppModel.pdfSaveEnded`). The stack going away (another screen, another
    /// game, the window closing) cancels a running export, which then writes nothing and drops a PDF not yet saved; a card
    /// page pushed on the stack does not. A made PDF dropped that way is said once: "The PDF was not saved: you left the
    /// list." (`PDFExport.leave`).
    func pdfSaving(_ export: PDFExport, model: AppModel) -> some View {
        fileExporter(isPresented: Binding(get: { export.made != nil }, set: { if !$0 { export.made = nil } }),
                     document: export.made.map { PDFFile(data: $0.data) }, contentType: .pdf,
                     defaultFilename: export.made?.fileName) { result in
            export.made = nil
            model.pdfSaveEnded(result)
        }
        .onDisappear {
            if let notice = export.leave() { model.pdfEnded(notice) }
        }
    }
}

/// A list screen's Sort menu: Name, Price high to low, Price low to high, Copies.
struct SortMenu: View {
    @Binding var sort: CollectionSort
    let identifier: String

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Name").tag(CollectionSort.name)
                Text("Price high to low").tag(CollectionSort.priceHigh)
                Text("Price low to high").tag(CollectionSort.priceLow)
                Text("Copies").tag(CollectionSort.count)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Sort")
        }
        .accessibilityIdentifier(identifier)
    }
}
