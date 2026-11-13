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
    /// "Make PDF…" (C10, C11): kept with the screen, so a card page opened on its stack does not stop it; the stack going
    /// away cancels it (`pdfSaving`).
    let export = PDFExport()

    init(gameID: String) {
        self.gameID = gameID
    }

    /// True when the search text has a word to match.
    var searching: Bool { !CardName.searchKey(text).isEmpty }

    /// What For Sale lists: the for-sale printings on the last join (`SaleList.entries`), with the Collection's catalog
    /// states (`RowsJoin.content`: a printing the catalog lacks is pending while the game's catalog downloads); without a
    /// join's entries, the for-sale printings alone, by their saved names. A printing the last join did not read is
    /// pending until the next one (`uncovered`). Nil until a join of this game has ended.
    func content(sale: [SaleEntry]) -> CollectionContent? {
        guard var content = join.content(rows: SaleList.entries(sale: sale, collection: []).map(\.row), listing: {
            SaleList.entries(sale: sale, collection: $0)
        }) else { return nil }
        content.uncovered = Set(sale.map(\.key)).subtracting((join.entries ?? []).map(\.id))
        return content
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

    /// What "Sold" asks about: the printing, its name, and the for-sale count the open dialog was made for.
    private struct Sale: Equatable {
        let key: PrintingKey
        let name: String
        let count: Int
    }

    var body: some View {
        let library = model.library
        // Nil until a join of this game has ended. The for-sale counts are read here, so a change shows at once.
        let listed = state.content(sale: library.forSale(game: state.gameID))
        let all = listed?.entries ?? []
        let shown = listed.map {
            CollectionList.shown($0, text: state.text, groupID: nil, rarity: nil, price: .any, playset: .any,
                                 playsetSize: model.game.playset, sort: state.sort)
        } ?? []
        let phase = ListPhase.of(listed, game: state.gameID, library: library)
        // The list is read (also an empty one): its PDF can be made.
        let pdfReady = phase == .list || phase == .empty
        let launchReady = PDFExport.launchReady(listRead: pdfReady, joined: state.join.joined, offline: model.options.offline)
        let join = RowsJoin.key(game: state.gameID, model: model)
        // The dialog follows the live for-sale count of its printing (a reload, another window): it opens again with the
        // new numbers, and closes when nothing is for sale any more (`follow`).
        let dialog = selling.flatMap { SaleList.soldDialog(name: $0.name, forSale: $0.count) }
        let live = selling.map { library.forSaleCount(game: state.gameID, key: $0.key) }
        content(phase, shown: shown, listed: listed)
            .listScreen("for-sale", note: phase == .list ? listed?.note : nil)
            .navigationTitle("For Sale")
            .navigationSubtitle(phase != .list ? "" : state.searching ? SaleList.totals(shown, of: all) : SaleList.totals(all))
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    PDFButton(export: state.export, identifier: "for-sale-pdf", enabled: pdfReady) { pdfJob(all) }
                    SortMenu(sort: $state.sort, identifier: "for-sale-sort")
                }
            }
            .launchPDF(state.export, screen: .forSale, ready: launchReady, model: model) { pdfJob(all) }
            // Plain buttons: selling is what the dialog is for, not a mistake to warn about (the system's destructive red
            // on its dark fill reads badly).
            .confirmationDialog(dialog?.title ?? "", isPresented: Binding(get: { dialog != nil }, set: { if !$0 { selling = nil } }),
                                titleVisibility: .visible, presenting: dialog) { dialog in
                ForEach(dialog.choices, id: \.self) { choice in
                    Button(choice.label) { sell(choice.count) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: live) { _, live in follow(live) }
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
                Button("Open the collection") { model.showRoot(of: .collection) }
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

    /// The PDF of the whole list, whatever the search text and the sort (it orders by price itself, C10).
    private func pdfJob(_ all: [CollectionEntry]) -> PDFJob? {
        guard let game = Games.game(state.gameID) else { return nil }
        return PDFJob(list: .forSale, game: game, items: PDFSource.forSale(all, game: game, ygo: model.ygoIndex),
                      date: Date(), timeZone: .current)
    }

    /// As on the card page: the step goes onto the library's current count, so two clicks before the next render both
    /// count; the library keeps it within the owned count, and 0 takes the printing off the list.
    private func step(by delta: Int, entry: CollectionEntry) {
        let library = model.library, game = state.gameID
        library.setForSale(library.forSaleCount(game: game, key: entry.id) + delta, game: game, key: entry.id, name: entry.name)
    }

    /// How long a closed dialog is given to go before it opens again. Measured on macOS 27: a dialog closed and opened
    /// again at once stays open with its first numbers (SwiftUI keeps it presented); after this pause it opens anew. Too
    /// short on some Mac, the old numbers stay, and a choice the count no longer allows is refused and said.
    private static let reopenPause = Duration.milliseconds(400)

    /// The open dialog's printing has a new for-sale count (`live`): the dialog closes, and opens again with the new numbers
    /// after `reopenPause`; at 0 it only closes (`SaleList.follow`).
    private func follow(_ live: Int?) {
        guard let sale = selling, let live else { return }
        switch SaleList.follow(shown: sale.count, live: live) {
        case .keep:
            return
        case .close:
            selling = nil
        case .reopen(let count):
            selling = nil
            Task { @MainActor in
                try? await Task.sleep(for: Self.reopenPause)
                // Not when another dialog was opened during the pause.
                guard selling == nil else { return }
                selling = Sale(key: sale.key, name: sale.name, count: count)
            }
        }
    }

    /// C7, a choice of the dialog: `count` copies leave the collection and the list, and one sold record is written at the
    /// price of this moment (`AppModel.sell`, which says so when the library refuses). The dialog's printing is taken
    /// first: a second activation before the dialog has closed (a double click) finds none and sells nothing.
    private func sell(_ count: Int) {
        guard let sale = selling else { return }
        selling = nil
        model.sell(count, game: state.gameID, key: sale.key)
    }
}
