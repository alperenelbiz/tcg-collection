import SwiftUI

/// What the Collection shows for one game: the search text, the filters, the sort, the gallery's scroll position, the
/// open pages, and the last join of the rows with the catalog. The window keeps it (`CollectionMemory`), so a visit to All
/// cards loses none of it.
@Observable
final class CollectionScreenState: GameScreenState {
    let gameID: String
    var text = ""
    var groupID: Int?
    var rarity: String?
    var price: PriceFilter = .any
    var playset: CollectionRules.PlaysetFilter = .any
    var sort: CollectionSort = .name
    var path = NavigationPath()
    /// The printing at the top of the gallery.
    var scrolledTo: PrintingKey?
    /// The rows joined with the catalog.
    let join = RowsJoin()
    /// The Filter menu's sets (newest first) and rarities (by name): those of the owned printings only.
    var sets: [SetRecord] = []
    var rarities: [String] = []

    init(gameID: String) {
        self.gameID = gameID
    }

    /// How many of the four menu filters are on. The search text is not one of them.
    var filtersOn: Int { [groupID != nil, rarity != nil, price != .any, playset != .any].filter { $0 }.count }

    /// True when the search text has a word to match.
    var searching: Bool { !CardName.searchKey(text).isEmpty }

    /// What the Collection lists (`RowsJoin.content`); nil until a join of this game has ended.
    func content(rows: [CollectionRow]) -> CollectionContent? {
        join.content(rows: rows)
    }

    func clearFilters() {
        groupID = nil
        rarity = nil
        price = .any
        playset = .any
    }
}

/// The window's Collection state.
typealias CollectionMemory = ScreenMemory<CollectionScreenState>

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

/// What a join of the rows with the catalog reads. While none of it changes, the entries are still right.
nonisolated struct CollectionJoin: Equatable {
    let game: String
    let libraryVersion: Int
    let catalogVersion: Int
    /// The game's price day: a new day's prices change the entries' prices.
    let priceDay: String?
    /// The game's catalog step has ended in this run (`AppModel.catalogSettled`): only then may a Set or Rarity choice
    /// go back to "All", and a product the join did not find read as not in the catalog any more (`content(rows:)`).
    let catalogSettled: Bool
}

/// Where the cell of a product that is not in the catalog any more opens (Review Focus 4).
nonisolated struct UnknownPrinting: Hashable, Sendable {
    let gameID: String
    let key: PrintingKey
    let name: String
}

/// The printings the user owns in the selected game: the totals as the window's subtitle, one search field, the Filter
/// menu (set, rarity, price, playset) and the Sort menu, and a gallery of `CardCell`s. A click opens the card page on that
/// printing, in this screen's own navigation stack. While the catalog has no product of the game, or cannot be read, the
/// rows are listed by their saved names with one line that says why, and a cell opens nothing; while the game's catalog
/// is still downloading, a row whose product is not in yet is pending in the same way (`CollectionList.content`).
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: CollectionScreenState

    var body: some View {
        // Nil until a join of this game has ended.
        let listed = state.content(rows: model.library.rows(game: state.gameID))
        let all = listed?.entries ?? []
        let shown = listed.map {
            CollectionList.shown($0, text: state.text, groupID: state.groupID, rarity: state.rarity, price: state.price,
                                 playset: state.playset, playsetSize: model.game.playset, sort: state.sort)
        } ?? []
        let phase = ListPhase.of(listed, game: state.gameID, library: model.library)
        content(phase, shown: shown, listed: listed)
            .listScreen("collection", note: phase == .list ? listed?.note : nil)
            .navigationTitle("Collection")
            .navigationSubtitle(subtitle(phase, all: all, shown: shown))
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    importButton
                    filterMenu
                    SortMenu(sort: $state.sort, identifier: "collection-sort")
                }
            }
            .task(id: RowsJoin.key(game: state.gameID, model: model)) { await joinRows() }
    }

    @ViewBuilder private func content(_ phase: ListPhase, shown: [CollectionEntry], listed: CollectionContent?) -> some View {
        switch phase {
        case .loading:
            LoadingGallery()
        case .unavailable:
            Color.clear
        case .empty:
            EmptyMessage(sentence: "No cards in this collection yet.") {
                Button("Import CSV…") { model.chooseCSVFile() }
                    .accessibilityIdentifier("collection-empty-import")
                Button("Search a card") { model.screen = .allCards }
                    .accessibilityIdentifier("collection-search-catalog")
            }
        case .list:
            if shown.isEmpty {
                EmptyMessage(sentence: state.filtersOn > 0 ? "No card matches these filters." : "No card matches \"\(state.text)\".") {
                    if state.filtersOn > 0 {
                        Button("Clear filters") { state.clearFilters() }
                    }
                }
            } else {
                ScrollView {
                    GalleryGrid {
                        ForEach(shown) { entry in
                            PrintingCell(gameID: state.gameID, entry: entry, link: listed?.link(for: entry) ?? .none)
                                .accessibilityIdentifier("collection-cell-\(entry.row.productID)-\(entry.row.finish)")
                        }
                    }
                }
                .scrollPosition(id: $state.scrolledTo, anchor: .top)
                .accessibilityIdentifier("collection-gallery")
            }
        }
    }

    /// The totals line: all printings, or the shown part of them while a filter or the search text is on.
    private func subtitle(_ phase: ListPhase, all: [CollectionEntry], shown: [CollectionEntry]) -> String {
        guard phase == .list || phase == .empty else { return "" }
        return state.filtersOn > 0 || state.searching ? CollectionList.totals(shown, of: all) : CollectionList.totals(all)
    }

    // MARK: Toolbar

    /// "Import CSV…" as an icon (its name is the help text and the accessibility label), so the toolbar keeps room for
    /// the two menus and the search field.
    private var importButton: some View {
        Button { model.chooseCSVFile() } label: {
            Label("Import CSV…", systemImage: "square.and.arrow.down")
        }
        .help("Import CSV…")
        .accessibilityIdentifier("collection-import")
    }

    /// One menu for the four filters, each a submenu: five menus and a search field do not fit the toolbar.
    private var filterMenu: some View {
        let playset = model.game.playset
        return Menu {
            Picker("Set", selection: $state.groupID) {
                Text("All").tag(Int?.none)
                ForEach(state.sets, id: \.groupID) { Text($0.name).tag(Int?.some($0.groupID)) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("collection-filter-set")
            Picker("Rarity", selection: $state.rarity) {
                Text("All").tag(String?.none)
                ForEach(state.rarities, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("collection-filter-rarity")
            Picker("Price", selection: $state.price) {
                Text("Any price").tag(PriceFilter.any)
                Text("Under $1.00").tag(PriceFilter.under1)
                Text("$1.00 or more").tag(PriceFilter.from1)
                Text("$5.00 or more").tag(PriceFilter.from5)
                Text("$20.00 or more").tag(PriceFilter.from20)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("collection-filter-price")
            Picker("Playset", selection: $state.playset) {
                Text("Any number").tag(CollectionRules.PlaysetFilter.any)
                Text("More than a playset (\(playset))").tag(CollectionRules.PlaysetFilter.moreThanAPlayset)
                Text("A playset (\(playset)) or fewer").tag(CollectionRules.PlaysetFilter.aPlaysetOrFewer)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("collection-filter-playset")
            Divider()
            Button("Clear filters") { state.clearFilters() }
                .disabled(state.filtersOn == 0)
        } label: {
            Text(state.filtersOn == 0 ? "Filter" : "Filter (\(state.filtersOn))")
        }
        .accessibilityIdentifier("collection-filter")
    }

    // MARK: The join

    /// The join (`RowsJoin.run`), then the Filter menu's sets and rarities from what it read.
    private func joinRows() async {
        let key = RowsJoin.key(game: state.gameID, model: model)
        guard let read = await state.join.run(key, model: model) else { return }
        let ownedSets = Set(read.products.values.map(\.groupID))
        state.sets = read.sets.filter { ownedSets.contains($0.groupID) }
        state.rarities = Set(read.products.values.map(\.rarity)).filter { !$0.isEmpty }.sorted()
        // A chosen set or rarity the collection no longer has goes back to "All" (and leaves the Filter count), but only
        // on a settled catalog: while it downloads, the owned sets are not all known yet.
        let groupID = CollectionList.validChoice(state.groupID, among: Set(state.sets.map(\.groupID)), settled: key.catalogSettled)
        if groupID != state.groupID { state.groupID = groupID }
        let rarity = CollectionList.validChoice(state.rarity, among: Set(state.rarities), settled: key.catalogSettled)
        if rarity != state.rarity { state.rarity = rarity }
    }
}

// MARK: The parts of a list screen (the Collection, For Sale)

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

/// The page of a printing whose product is not in the catalog any more (Review Focus 4): its saved name, one sentence,
/// and its count control, so the row can be changed or removed by hand.
struct UnknownPrintingPage: View {
    let printing: UnknownPrinting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(printing.name)
                    .font(Theme.pageTitleFont)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-title")
                Text("This printing is not in the catalog any more.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                RuleLine()
                // No price column: the price table has nothing for a product the catalog does not have.
                OwnedFinishes(gameID: printing.gameID, productID: printing.key.productID, name: printing.name,
                              offered: [printing.key.finish], prices: nil)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { Theme.ground.ignoresSafeArea() }
        .navigationTitle(printing.name)
    }
}
