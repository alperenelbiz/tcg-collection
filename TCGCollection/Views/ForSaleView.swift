import SwiftUI

/// What For Sale shows for one game: the search text, the sort, the gallery's scroll position, the open pages, and the
/// last join of the collection with the catalog. The window keeps it (`ForSaleMemory`), so a visit to another screen loses
/// none of it.
@Observable
final class ForSaleScreenState: GameScreenState {
    let gameID: String
    var text = ""
    /// The most valuable first.
    var sort: CollectionSort = .priceHigh
    var path = NavigationPath()
    /// The printing at the top of the gallery.
    var scrolledTo: PrintingKey?
    /// The game's collection rows joined with the catalog; the for-sale printings are laid on it.
    let join = RowsJoin()

    init(gameID: String) {
        self.gameID = gameID
    }

    /// What For Sale lists: the for-sale printings on the last join (`SaleList.entries`), with the Collection's catalog
    /// states (`RowsJoin.content`: a printing the catalog lacks is pending while the game's catalog downloads); without a
    /// join's entries, the for-sale printings alone, by their saved names. Nil until a join of this game has ended.
    func content(sale: [SaleEntry]) -> CollectionContent? {
        join.content(rows: SaleList.entries(sale: sale, collection: []).map(\.row)) {
            SaleList.entries(sale: sale, collection: $0)
        }
    }
}

/// The window's For Sale state.
typealias ForSaleMemory = ScreenMemory<ForSaleScreenState>

/// The printings the user has for sale in the selected game (C3): the totals as the window's subtitle, one search field
/// and the Sort menu (price high to low first), and a gallery of Collection cells (A10), each with its for-sale count and
/// "Sold" under it (C6). A click on a cell's picture or name opens the card page on that printing, in this screen's own
/// navigation stack. The cells follow the catalog as the Collection's do: a printing the catalog lacks is pending while
/// the game's catalog downloads (it opens nothing; its controls still work), and opens the page of a printing that left
/// the catalog once the catalog is settled.
struct ForSaleView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: ForSaleScreenState
    /// The printing "Sold" asks about (C7); nil while no dialog is open.
    @State private var selling: Sale?

    /// What "Sold" asks about: the printing, its name, and its for-sale count when the button was clicked.
    private struct Sale {
        let key: PrintingKey
        let name: String
        let count: Int
    }

    var body: some View {
        let library = model.library
        // Nil until a join of this game has ended. The for-sale counts are read here, so a change shows at once.
        let listed = state.content(sale: library.forSale(game: state.gameID))
        let shown = listed.map {
            CollectionList.shown($0, text: state.text, groupID: nil, rarity: nil, price: .any, playset: .any,
                                 playsetSize: model.game.playset, sort: state.sort)
        } ?? []
        let phase = ListPhase.of(listed, game: state.gameID, library: library)
        let join = RowsJoin.key(game: state.gameID, model: model)
        content(phase, shown: shown, listed: listed)
            .listScreen("for-sale", note: phase == .list ? listed?.note : nil)
            .navigationTitle("For Sale")
            .navigationSubtitle(phase == .list ? SaleList.totals(listed?.entries ?? []) : "")
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    SortMenu(sort: $state.sort, identifier: "for-sale-sort")
                }
            }
            .confirmationDialog(selling.map { "Sold \($0.count) of \($0.name)?" } ?? "",
                                isPresented: Binding(get: { selling != nil }, set: { if !$0 { selling = nil } }),
                                titleVisibility: .visible, presenting: selling) { sale in
                Button("Sold 1", role: .destructive) { sell(1, of: sale) }
                if sale.count > 1 {
                    Button("Sold all \(sale.count)", role: .destructive) { sell(sale.count, of: sale) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task(id: join) { await state.join.run(join, model: model) }
    }

    @ViewBuilder private func content(_ phase: ListPhase, shown: [CollectionEntry], listed: CollectionContent?) -> some View {
        switch phase {
        case .loading:
            LoadingGallery()
        case .unavailable:
            Color.clear
        case .empty:
            EmptyMessage(sentence: "Nothing for sale.") {
                Button("Open the collection") { model.screen = .collection }
                    .accessibilityIdentifier("for-sale-open-collection")
            }
        case .list:
            if shown.isEmpty {
                EmptyMessage(sentence: "No card matches \"\(state.text)\".")
            } else {
                let canChange = model.library.canChange(game: state.gameID)
                ScrollView {
                    GalleryGrid {
                        ForEach(shown) { entry in
                            cell(entry, link: listed?.link(for: entry) ?? .none, canChange: canChange)
                        }
                    }
                }
                .scrollPosition(id: $state.scrolledTo, anchor: .top)
                .accessibilityIdentifier("for-sale-gallery")
            }
        }
    }

    /// C6: the Collection's cell, 8 pt, then one line: the for-sale count (`+` off at the owned count) and "Sold". The
    /// controls are off while the game cannot change; "Sold" is off while a dialog is open.
    private func cell(_ entry: CollectionEntry, link: CollectionCellLink, canChange: Bool) -> some View {
        let suffix = "\(entry.row.productID)-\(entry.row.finish)"
        let owned = model.library.count(game: state.gameID, key: entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            PrintingCell(gameID: state.gameID, entry: entry, link: link)
                .accessibilityIdentifier("for-sale-cell-\(suffix)")
            HStack(spacing: 8) {
                CountControl(count: entry.row.count, label: "\(entry.name), \(entry.row.finish), for sale", maximum: owned,
                             prefix: "for-sale", key: suffix) { step(by: $0 - entry.row.count, entry: entry) }
                Spacer(minLength: 0)
                Button("Sold") { selling = Sale(key: entry.id, name: entry.name, count: entry.row.count) }
                    .buttonStyle(FieldButtonStyle())
                    .disabled(selling != nil)
                    .accessibilityLabel("Sold \(entry.name), \(entry.row.finish)")
                    .accessibilityIdentifier("for-sale-sold-\(suffix)")
            }
            .disabled(!canChange)
        }
    }

    /// As on the card page: the step goes onto the library's current count, so two clicks before the next render both
    /// count; the library keeps it within the owned count, and 0 takes the printing off the list.
    private func step(by delta: Int, entry: CollectionEntry) {
        let library = model.library, game = state.gameID
        library.setForSale(library.forSaleCount(game: game, key: entry.id) + delta, game: game, key: entry.id, name: entry.name)
    }

    /// C7: `count` copies leave the collection and the list, and one sold record is written, with the printing's own
    /// price for its finish at this moment (the price table's, as the cell shows it; none when it has none). A sale the
    /// library refuses (a second click, a count changed meanwhile: more than are for sale or owned) sells nothing.
    private func sell(_ count: Int, of sale: Sale) {
        selling = nil
        let game = state.gameID
        model.library.sell(count, game: game, key: sale.key, price: model.prices.shown(game: game, key: sale.key))
    }
}
