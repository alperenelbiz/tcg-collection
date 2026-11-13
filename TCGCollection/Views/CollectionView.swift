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
