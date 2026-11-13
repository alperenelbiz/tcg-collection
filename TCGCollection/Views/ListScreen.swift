import SwiftUI

// The parts of a list screen (the Collection, For Sale): its state memory, the join of the rows with the catalog,
// and the shared views.

/// The state of a list screen (the Collection, For Sale) for one game, kept by `ScreenMemory`.
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
}

/// The game's collection rows joined with the catalog and the prices: what the Collection lists, and what For Sale lays
/// its printings on (`SaleList.entries`). Each list screen's state has its own, so the window keeps it with the screen.
@Observable
final class RowsJoin {
    /// The last join that succeeded on a catalog with this game's products, in the file's order. Nil until one did.
    var entries: [CollectionEntry]?
    /// The latest join threw (the catalog could not be read): `entries` stays as it was, and the next appearance of the
    /// screen tries again.
    var failed = false
    /// The catalog has products of this game. Without, the rows are listed alone.
    var catalogHasProducts = false
    /// What the latest join that ended read: a join with the same inputs is not done again (a return from another
    /// screen), unless it failed (`CollectionList.joinIsDue`).
    var joined: CollectionJoin?

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

    /// What a join of the game reads now.
    static func key(game: String, model: AppModel) -> CollectionJoin {
        CollectionJoin(game: game, libraryVersion: model.library.version, catalogVersion: model.catalogVersion,
                       priceDay: model.prices.day(game: game), catalogSettled: model.catalogSettled(game: game))
    }

    /// Joins the game's rows with the catalog (products and set names through `reader`, off the main thread) and the
    /// prices, when `key` differs from the last join or the last one failed. Filtering and sorting then run in memory on
    /// every keystroke. Returns the products and sets it read when it joined on a catalog with the game's products (the
    /// Collection's Filter menu comes from them); else nil.
    @discardableResult
    func run(_ key: CollectionJoin, model: AppModel) async -> (products: [Int: ProductRecord], sets: [SetRecord])? {
        let library = model.library
        // Before the folder is read the rows are empty: no join, the screen shows its loading layout. A failed join is
        // tried again the next time the screen appears.
        guard library.isLoaded, CollectionList.joinIsDue(key, last: joined, lastFailed: failed) else { return nil }
        let game = key.game, rows = library.rows(game: game)
        let products: [Int: ProductRecord], sets: [SetRecord], hasProducts: Bool
        do {
            products = try await model.reader.products(ids: rows.map(\.productID), game: game)
            sets = try await model.reader.sets(game: game)
            hasProducts = try await model.reader.hasProducts(game: game)
        } catch {
            // A read error never turns the rows into unknown printings: the last good entries stay (`content`).
            guard !Task.isCancelled else { return nil }
            failed = true
            joined = key
            return nil
        }
        guard !Task.isCancelled else { return nil }
        failed = false
        catalogHasProducts = hasProducts
        joined = key
        // No product of this game yet: every product would be missing; the rows are listed alone.
        guard hasProducts else {
            entries = nil
            return nil
        }
        let prices = model.prices
        let names = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let joinedEntries = CollectionList.entries(rows: rows, products: products, setNames: names) {
            prices.shown(game: game, key: $0)
        }
        // On a return to the screen with the same rows nothing is written, so nothing redraws.
        if entries != joinedEntries { entries = joinedEntries }
        return (products, sets)
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
        if let listed, !listed.entries.isEmpty { return .list }
        if library.canChange(game: game) { return listed == nil ? .loading : .empty }
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

/// What the catalog cannot give yet (`CollectionContent.note`): one muted line above a list's gallery.
private struct CatalogNote: View {
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

/// A gallery's grid (the cell rule): adaptive columns of at least `cellMinWidth`, the gaps and the outer margin.
struct GalleryGrid<Cells: View>: View {
    @ViewBuilder let cells: Cells

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cellMinWidth), spacing: Theme.columnGap)], spacing: Theme.rowGap) {
            cells
        }
        .scrollTargetLayout()
        .padding(Theme.margin)
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
