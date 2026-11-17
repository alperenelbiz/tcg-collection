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
    /// The Sold dialog (C7, A1): the one on show, and the generation its choices and reopens are checked against.
    @State private var sold = SoldDialogState()

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
        let dialog = sold.dialog
        let live = dialog.map { library.forSaleCount(game: state.gameID, key: $0.key) }
        content(phase, shown: shown, listed: listed)
            .listScreen("for-sale", note: phase == .list ? listed?.note : nil)
            .navigationTitle("For Sale")
            #if os(macOS)
            .navigationSubtitle(phase != .list ? "" : state.searching ? SaleList.totals(shown, of: all) : SaleList.totals(all))
            #else
            // R3: no subtitle on the iPhone (the bar has no room for it); the totals are a line above the gallery.
            .listTotals(phase != .list ? "" : state.searching ? SaleList.totals(shown, of: all) : SaleList.totals(all),
                        identifier: "for-sale-totals")
            #endif
            .searchable(text: $state.text)
            #if os(iOS)
            // A54: the toolbar's items in one "…" menu.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MoreMenu(identifier: "for-sale-more") {
                        PDFButton(export: state.export, identifier: "for-sale-pdf", enabled: pdfReady) { pdfJob(all) }
                        SortMenu(sort: $state.sort, identifier: "for-sale-sort")
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItemGroup {
                    PDFButton(export: state.export, identifier: "for-sale-pdf", enabled: pdfReady) { pdfJob(all) }
                    SortMenu(sort: $state.sort, identifier: "for-sale-sort")
                }
            }
            #endif
            .launchPDF(state.export, screen: .forSale, ready: launchReady, model: model) { pdfJob(all) }
            // Plain buttons: selling is what the dialog is for, not a mistake to warn about (the system's destructive red
            // on its dark fill reads badly).
            .confirmationDialog(dialog?.title ?? "", isPresented: Binding(get: { sold.isOpen }, set: { if !$0 { sold.dismissed() } }),
                                titleVisibility: .visible, presenting: dialog) { dialog in
                ForEach(dialog.choices, id: \.self) { choice in
                    Button(choice.label) { sell(choice) }
                }
                Button("Cancel", role: .cancel) { sold.cancel() }
            } message: { dialog in
                // E9: the decks the sale leaves short; made at each opening (the dialog does not redraw while open).
                if let message = dialog.message { Text(message) }
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
            #if os(iOS)
            // The iPhone (phase 6A task 8): the 44 pt count control and "Sold" do not fit one line of a 179 pt cell, and
            // "Sold" wrapped inside its button ("Sol / d"): it keeps one line, under the control when the row is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    saleControl(entry, owned: owned, suffix: suffix)
                    Spacer(minLength: 0)
                    soldButton(entry, suffix: suffix)
                }
                VStack(alignment: .leading, spacing: 8) {
                    saleControl(entry, owned: owned, suffix: suffix)
                    soldButton(entry, suffix: suffix)
                }
            }
            .disabled(!canChange)
            #else
            HStack(spacing: 8) {
                CountControl(count: entry.row.count, label: "\(entry.name), \(entry.row.finish), for sale", maximum: owned,
                             prefix: "for-sale", key: suffix) { step(by: $0 - entry.row.count, entry: entry) }
                Spacer(minLength: 0)
                Button("Sold") {
                    sold.ask(key: entry.id, name: entry.name, forSale: entry.row.count,
                             message: soldMessage(entry, forSale: entry.row.count))
                }
                    .buttonStyle(FieldButtonStyle())
                    .disabled(sold.isOpen)
                    .accessibilityLabel("Sold \(entry.name), \(entry.row.finish)")
                    .accessibilityIdentifier("for-sale-sold-\(suffix)")
            }
            .disabled(!canChange)
            #endif
        }
    }

    #if os(iOS)
    /// The cell's for-sale count control (the Mac builds the same one inline).
    private func saleControl(_ entry: CollectionEntry, owned: Int, suffix: String) -> some View {
        CountControl(count: entry.row.count, label: "\(entry.name), \(entry.row.finish), for sale", maximum: owned,
                     prefix: "for-sale", key: suffix) { step(by: $0 - entry.row.count, entry: entry) }
    }

    /// "Sold" on one line (its width is its word's).
    private func soldButton(_ entry: CollectionEntry, suffix: String) -> some View {
        Button("Sold") {
            sold.ask(key: entry.id, name: entry.name, forSale: entry.row.count,
                     message: soldMessage(entry, forSale: entry.row.count))
        }
            .buttonStyle(FieldButtonStyle())
            .lineLimit(1)
            .fixedSize()
            .disabled(sold.isOpen)
            .accessibilityLabel("Sold \(entry.name), \(entry.row.finish)")
            .accessibilityIdentifier("for-sale-sold-\(suffix)")
    }
    #endif

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
    /// short on some Mac, the old numbers stay; a choice clicked there sells what it shows, or is refused and said.
    private static let reopenPause = Duration.milliseconds(400)

    /// The open dialog's printing has a new for-sale count (`live`): the dialog closes, and opens again with the count of
    /// that moment after `reopenPause`; at 0 it only closes. A cancel, a choice or another dialog during the pause, or a
    /// sheet open at its end, means no reopen (`SoldDialogState.reopen`).
    private func follow(_ live: Int?) {
        guard let live, let token = sold.follow(live: live) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.reopenPause)
            let sheetOpen = model.showsSheet || state.export.made != nil
            let entries = state.content(sale: model.library.forSale(game: state.gameID))?.entries ?? []
            _ = sold.reopen(token, sheetOpen: sheetOpen, live: { model.library.forSaleCount(game: state.gameID, key: $0) },
                            message: { key, count in
                                entries.first { $0.id == key }.flatMap { soldMessage($0, forSale: count) }
                            })
        }
    }

    /// E9: the Sold dialog's message for `entry` with `count` copies for sale: the active decks of the game that the sale
    /// leaves short (`SaleList.soldMessage`, with the library's decks and sharing answers), nil for none.
    private func soldMessage(_ entry: CollectionEntry, forSale count: Int) -> String? {
        guard let game = Games.game(state.gameID) else { return nil }
        let library = model.library
        // G7: no deck message without the player role (no deck in play).
        return SaleList.soldMessage(for: entry, forSale: count, game: game, decks: model.decksInPlay(game: state.gameID),
                                    sharing: library.sharing(game: state.gameID))
    }

    /// C7, a choice of the dialog: its copies of its printing leave the collection and the list, and one sold record is
    /// written at the price of this moment (`AppModel.sell`, which says why when the library refuses). One value carries
    /// both (A1); a second activation of the same dialog (a double click) sells nothing.
    private func sell(_ choice: SoldChoice) {
        guard let sale = sold.choose(choice) else { return }
        model.sell(sale.count, game: state.gameID, key: sale.key)
    }
}
