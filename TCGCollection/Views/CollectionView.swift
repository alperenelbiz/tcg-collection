import SwiftUI

/// What the Collection shows for one game: the search text, the filters, the sort, the gallery's scroll position, the
/// open pages, and the last join of the rows with the catalog. The window keeps it (`CollectionMemory`), so a visit to All
/// cards loses none of it.
@Observable
final class CollectionScreenState {
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
    /// The last join that succeeded on a catalog with this game's sets, in the file's order. Nil until one did.
    var entries: [CollectionEntry]?
    /// The latest join threw (the catalog could not be read): `entries` stays as it was.
    var joinFailed = false
    /// The catalog has fetched sets of this game. Until then no row can be "not in the catalog any more".
    var catalogHasSets = false
    /// The Filter menu's sets (newest first) and rarities (by name): those of the owned printings only.
    var sets: [SetRecord] = []
    var rarities: [String] = []
    /// What the latest join that ended read: a join with the same inputs is not done again (a return from All cards).
    var joined: CollectionJoin?

    init(gameID: String) {
        self.gameID = gameID
    }

    /// How many of the four menu filters are on. The search text is not one of them.
    var filtersOn: Int { [groupID != nil, rarity != nil, price != .any, playset != .any].filter { $0 }.count }

    /// True when the search text has a word to match.
    var searching: Bool { !CardName.searchKey(text).isEmpty }

    func clearFilters() {
        groupID = nil
        rarity = nil
        price = .any
        playset = .any
    }
}

/// The window's Collection state: the current game's only; another game starts afresh, as All cards does. Not observed:
/// it hands out the same `CollectionScreenState` for as long as the game stays.
final class CollectionMemory {
    private var current: CollectionScreenState?

    func state(game: String) -> CollectionScreenState {
        if let current, current.gameID == game { return current }
        let fresh = CollectionScreenState(gameID: game)
        current = fresh
        return fresh
    }
}

/// What a join of the rows with the catalog reads. While none of it changes, the entries are still right.
nonisolated struct CollectionJoin: Equatable {
    let game: String
    let libraryVersion: Int
    let catalogVersion: Int
    /// The game's price day: a new day's prices change the entries' prices.
    let priceDay: String?
}

/// Where the cell of a product that is not in the catalog any more opens (Review Focus 4).
nonisolated struct UnknownPrinting: Hashable, Sendable {
    let gameID: String
    let key: PrintingKey
    let name: String
}

/// The printings the user owns in the selected game: the totals as the window's subtitle, one search field, the Filter
/// menu (set, rarity, price, playset) and the Sort menu, and a gallery of `CardCell`s. A click opens the card page on that
/// printing, in this screen's own navigation stack. While the catalog has none of the game's sets, or cannot be read, the
/// rows are listed by their saved names with one line that says why (`CollectionList.content`), and a cell opens nothing.
struct CollectionView: View {
    /// Placeholder cells while the folder is read: about one window of the gallery.
    private static let placeholders = 12

    @Environment(AppModel.self) private var model
    @Bindable var state: CollectionScreenState

    private enum Phase {
        /// The folder is still read, or the first join of the game runs.
        case loading
        /// Nothing can be shown or changed (the folder is missing, the game's file is refused): the problem line says why.
        case unavailable
        case empty
        case list
    }

    var body: some View {
        // Nil until a join of this game has ended.
        let listed = state.joined == nil ? nil : CollectionList.content(
            rows: model.library.rows(game: state.gameID), joined: state.entries, joinFailed: state.joinFailed,
            catalogHasSets: state.catalogHasSets, syncing: model.status.isSyncing)
        let all = listed?.entries ?? []
        let shown = CollectionList.sorted(
            CollectionList.filtered(all, text: state.text, groupID: state.groupID, rarity: state.rarity, price: state.price,
                                    playset: state.playset, playsetSize: model.game.playset),
            by: state.sort)
        let phase = phase(listed)
        content(phase, shown: shown, linked: listed?.linked ?? false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { note(phase == .list ? listed?.note : nil) }
            .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            .background { Theme.ground.ignoresSafeArea() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("collection-screen")
            .navigationTitle("Collection")
            .navigationSubtitle(subtitle(phase, all: all, shown: shown))
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    filterMenu
                    sortMenu
                }
            }
            .navigationDestination(for: CardTarget.self) { target in
                CardPageView(cardKey: target.cardKey, startProductID: target.startProductID)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
            .navigationDestination(for: UnknownPrinting.self) { printing in
                UnknownPrintingPage(printing: printing)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
            .task(id: join) { await joinRows() }
    }

    private func phase(_ listed: CollectionContent?) -> Phase {
        let library = model.library
        if let listed, !listed.entries.isEmpty { return .list }
        if library.canChange(game: state.gameID) { return listed == nil ? .loading : .empty }
        return library.problem(game: state.gameID) == nil ? .loading : .unavailable
    }

    /// What the catalog cannot give yet (`CollectionContent.note`): one muted line above the gallery.
    @ViewBuilder private func note(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.margin)
                .padding(.top, Theme.ruleSpacing)
                .accessibilityIdentifier("collection-catalog-note")
        }
    }

    @ViewBuilder private func content(_ phase: Phase, shown: [CollectionEntry], linked: Bool) -> some View {
        switch phase {
        case .loading:
            // The final layout with flat `surface` blocks where the pictures will be. No shimmer.
            ScrollView {
                grid { ForEach(0..<Self.placeholders, id: \.self) { _ in PlaceholderCell() } }
            }
        case .unavailable:
            Color.clear
        case .empty:
            EmptyMessage(sentence: "No cards in this collection yet.") {
                // Task 7 puts "Import CSV…" (`collection-import`) here, as the first of the two buttons.
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
                    grid {
                        ForEach(shown) { entry in
                            cell(entry, linked: linked)
                                .accessibilityIdentifier("collection-cell-\(entry.row.productID)-\(entry.row.finish)")
                        }
                    }
                }
                .scrollPosition(id: $state.scrolledTo, anchor: .top)
                .accessibilityIdentifier("collection-gallery")
            }
        }
    }

    private func grid<Cells: View>(@ViewBuilder _ cells: () -> Cells) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cellMinWidth), spacing: Theme.columnGap)], spacing: Theme.rowGap) {
            cells()
        }
        .scrollTargetLayout()
        .padding(Theme.margin)
    }

    /// A printing of the catalog opens its card page on that printing; one that left the catalog opens its small page.
    /// Without a linked catalog (`CollectionContent.linked`) a cell opens nothing and takes no hover.
    @ViewBuilder private func cell(_ entry: CollectionEntry, linked: Bool) -> some View {
        let cell = CardCell(content: CellContent(product: entry.product, name: entry.name, left: entry.countText,
                                                 price: entry.price, selected: false))
        if !linked {
            cell
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.accessibilityText)
        } else if let product = entry.product {
            NavigationLink(value: CardTarget(gameID: state.gameID, cardKey: entry.cardKey, startProductID: product.productID)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.accessibilityText)
        } else {
            NavigationLink(value: UnknownPrinting(gameID: state.gameID, key: entry.id, name: entry.name)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.accessibilityText)
        }
    }

    /// The totals line: all printings, or the shown part of them while a filter or the search text is on.
    private func subtitle(_ phase: Phase, all: [CollectionEntry], shown: [CollectionEntry]) -> String {
        guard phase == .list || phase == .empty else { return "" }
        return state.filtersOn > 0 || state.searching ? CollectionList.totals(shown, of: all) : CollectionList.totals(all)
    }

    // MARK: Toolbar

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

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $state.sort) {
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
        .accessibilityIdentifier("collection-sort")
    }

    // MARK: The join

    private var join: CollectionJoin {
        CollectionJoin(game: state.gameID, libraryVersion: model.library.version, catalogVersion: model.catalogVersion,
                       priceDay: model.prices.day(game: state.gameID))
    }

    /// Joins the game's rows with the catalog (products and set names through `reader`, off the main thread) and the
    /// prices, once per `join`. Filtering and sorting then run in memory on every keystroke.
    private func joinRows() async {
        let key = join, library = model.library
        // Before the folder is read the rows are empty: no join, the screen shows its loading layout.
        guard library.isLoaded, state.joined != key else { return }
        let game = state.gameID, rows = library.rows(game: game)
        let products: [Int: ProductRecord], sets: [SetRecord], hasSets: Bool
        do {
            products = try await model.reader.products(ids: rows.map(\.productID), game: game)
            sets = try await model.reader.sets(game: game)
            hasSets = try await model.reader.progress(game: game).fetched > 0
        } catch {
            // A read error never turns the rows into unknown printings: the last good entries stay (`content`).
            guard !Task.isCancelled else { return }
            state.joinFailed = true
            state.joined = key
            return
        }
        guard !Task.isCancelled else { return }
        state.joinFailed = false
        state.catalogHasSets = hasSets
        state.joined = key
        // No fetched set of this game yet: every product would be missing; the rows are listed alone.
        guard hasSets else {
            state.entries = nil
            return
        }
        let prices = model.prices
        let names = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let entries = CollectionList.entries(rows: rows, products: products, setNames: names) { printing in
            prices.prices(game: game, productID: printing.productID).first { $0.finish == printing.finish }?.price.shown
        }
        let ownedSets = Set(products.values.map(\.groupID))
        state.sets = sets.filter { ownedSets.contains($0.groupID) }
        state.rarities = Set(products.values.map(\.rarity)).filter { !$0.isEmpty }.sorted()
        // A chosen set or rarity the collection no longer has goes back to "All" (and leaves the Filter count).
        let groupID = CollectionList.validChoice(state.groupID, among: Set(state.sets.map(\.groupID)))
        if groupID != state.groupID { state.groupID = groupID }
        let rarity = CollectionList.validChoice(state.rarity, among: Set(state.rarities))
        if rarity != state.rarity { state.rarity = rarity }
        // On a return to the Collection with the same rows nothing is written, so nothing redraws.
        if state.entries != entries { state.entries = entries }
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
