import SwiftUI

extension WantedList {
    /// C12, the price of a wanted card from the price table, for `WantedList.cards`: its pin's price for the pinned finish
    /// (`PriceTable.shown`), else the cheapest over the printings it is given (`PriceTable.cheapest`).
    @MainActor static func price(_ prices: PriceTable, game: String) -> (WantedEntry, [ProductRecord]) -> ShownPrice? {
        { entry, printings in
            if let pin = entry.pin { return prices.shown(game: game, key: pin) }
            return prices.cheapest(game: game, productIDs: printings.map(\.productID))
        }
    }
}

/// The Wanted list joined with the catalog: the printings of every wanted card, the set names, and what the catalog
/// said. `RowsJoin` joins collection rows, which are printings; Wanted speaks in cards and needs each card's printings, so
/// it has this join of its own, run as `RowsJoin.run` runs: once per `CollectionJoin` (`RowsJoin.key`), off the main
/// thread through `reader`, again only when the key changed or the last one failed (`CollectionList.joinIsDue`); a failed
/// read keeps what the last one read. The live list is laid on it on every render (`content`), so a count or a pin shows
/// at once.
@Observable
final class WantedJoin {
    /// The last join that succeeded on a catalog with this game's products. Nil until one did.
    var read: WantedRead?
    /// The latest join threw (the catalog could not be read): `read` stays as it was, and the next appearance of the screen
    /// tries again.
    var failed = false
    /// The catalog has products of this game. Without, the cards are listed alone.
    var catalogHasProducts = false
    /// What the latest join that ended read.
    var joined: CollectionJoin?

    /// What Wanted lists (`WantedList.content`); nil until a join of this game has ended. The catalog counts as settled as
    /// it was for the join that made `read`, as for the Collection.
    func content(wanted: [WantedEntry], rows: [CollectionRow],
                 price: (WantedEntry, [ProductRecord]) -> ShownPrice?) -> WantedContent? {
        guard let joined else { return nil }
        return WantedList.content(wanted, rows: rows, read: read, joinFailed: failed, catalogHasProducts: catalogHasProducts,
                                  catalogSettled: joined.catalogSettled, price: price)
    }

    /// Reads the printings of the game's wanted cards, its set names and whether it has products, when `key` differs from
    /// the last join or the last one failed.
    func run(_ key: CollectionJoin, model: AppModel) async {
        let library = model.library
        // Before the folder is read the list is empty: no join, the screen shows its loading layout.
        guard library.isLoaded, CollectionList.joinIsDue(key, last: joined, lastFailed: failed) else { return }
        let game = key.game, keys = Set(library.wanted(game: game).map(\.cardKey))
        let printings: [String: [ProductRecord]], sets: [SetRecord], hasProducts: Bool
        do {
            printings = try await model.reader.printings(game: game, cardKeys: Array(keys))
            sets = try await model.reader.sets(game: game)
            hasProducts = try await model.reader.hasProducts(game: game)
        } catch {
            // A read error never turns the cards into unknown ones: the last good read stays (`content`).
            guard !Task.isCancelled else { return }
            failed = true
            joined = key
            return
        }
        guard !Task.isCancelled else { return }
        failed = false
        catalogHasProducts = hasProducts
        joined = key
        // No product of this game yet: every card would be missing; the cards are listed alone.
        guard hasProducts else {
            read = nil
            return
        }
        let names = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let fresh = WantedRead(printings: printings, keys: keys, setNames: names)
        // On a return to the screen with the same list nothing is written, so nothing redraws.
        if read != fresh { read = fresh }
    }
}

/// What Wanted shows for one game: the search text, the sort, the gallery's scroll position, the open pages, and the last
/// join with the catalog. The window keeps it (`WantedMemory`), so a visit to another screen loses none of it.
@Observable
final class WantedScreenState: GameScreenState {
    let gameID: String
    var text = ""
    var sort: CollectionSort = .name
    var path = NavigationPath()
    /// The card at the top of the gallery.
    var scrolledTo: String?
    let join = WantedJoin()

    init(gameID: String) {
        self.gameID = gameID
    }

    /// True when the search text has a word to match.
    var searching: Bool { !CardName.searchKey(text).isEmpty }
}

/// The window's Wanted state.
typealias WantedMemory = ScreenMemory<WantedScreenState>

/// Where the cell of a wanted card that is not in the catalog any more opens (Review Focus 4).
nonisolated struct UnknownCard: Hashable, Sendable {
    let gameID: String
    let cardKey: String
    let name: String
}

/// The cards the user wants in the selected game (C2, C5: added by hand only): the totals as the window's subtitle, one
/// search field and the Sort menu, and a gallery of `CardCell`s, each with its wanted count under it (C6). A cell shows
/// the card's cheapest printing and price, or the pinned printing with its set and price (C12). A click on a cell's
/// picture or name opens the card page on that printing, in this screen's own navigation stack. The cells follow the
/// catalog as the Collection's do: a card without a printing is pending while the game's catalog downloads (it opens
/// nothing; its control still works), and opens the page of a card that left the catalog once the catalog is settled.
struct WantedView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: WantedScreenState
    /// "Make PDF…" (C10, C11): its pictures, progress and the made PDF; it ends with this screen.
    @State private var export = PDFExport()

    var body: some View {
        let library = model.library, game = state.gameID
        // Nil until a join of this game has ended. The wanted counts and pins are read here, so a change shows at once.
        let listed = state.join.content(wanted: library.wanted(game: game), rows: library.rows(game: game),
                                        price: WantedList.price(model.prices, game: game))
        let all = listed?.cards ?? []
        let shown = WantedList.sorted(WantedList.filtered(all, text: state.text), by: state.sort)
        let phase = ListPhase.of(listing: listed.map { !$0.cards.isEmpty }, game: game, library: library)
        // The list is read (also an empty one): its PDF can be made.
        let pdfReady = phase == .list || phase == .empty
        let join = RowsJoin.key(game: game, model: model)
        content(phase, shown: shown, listed: listed)
            .listScreen("wanted", note: phase == .list ? listed?.note : nil)
            .navigationDestination(for: UnknownCard.self) { card in
                UnknownCardPage(card: card)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
            .navigationTitle("Wanted")
            .navigationSubtitle(phase != .list ? "" : state.searching ? WantedList.totals(shown, of: all) : WantedList.totals(all))
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    PDFButton(export: export, identifier: "wanted-pdf", enabled: pdfReady) { pdfJob(all) }
                    SortMenu(sort: $state.sort, identifier: "wanted-sort")
                }
            }
            .listPDF(export, screen: .wanted, ready: pdfReady, model: model) { pdfJob(all) }
            .task(id: join) { await state.join.run(join, model: model) }
    }

    /// The PDF of the whole list, whatever the search text and the sort (it orders by price itself, C10).
    private func pdfJob(_ all: [WantedCard]) -> PDFJob? {
        guard let game = Games.game(state.gameID) else { return nil }
        return PDFJob(list: .wanted, game: game, items: PDFSource.wanted(all, game: game, ygo: model.ygoIndex),
                      date: Date(), timeZone: .current)
    }

    @ViewBuilder private func content(_ phase: ListPhase, shown: [WantedCard], listed: WantedContent?) -> some View {
        switch phase {
        case .loading:
            LoadingGallery()
        case .unavailable:
            Color.clear
        case .empty:
            EmptyMessage(sentence: "Nothing on your wanted list.") {
                Button("Search a card") { model.screen = .allCards }
                    .accessibilityIdentifier("wanted-search-catalog")
            }
        case .list:
            // `.list` comes only with a listing (`listed`).
            if let listed, !shown.isEmpty {
                let canChange = model.library.canChange(game: state.gameID)
                ScrollView {
                    GalleryGrid {
                        ForEach(shown) { card in cell(card, listed: listed, canChange: canChange) }
                    }
                }
                .scrollPosition(id: $state.scrolledTo, anchor: .top)
                .accessibilityIdentifier("wanted-gallery")
            } else {
                EmptyMessage(sentence: "No card matches \"\(state.text)\".")
            }
        }
    }

    /// C6: the cell, 8 pt, then one line with the wanted count (`−` at 1 takes the card and its pin off the list). The
    /// control is off while the game cannot change.
    private func cell(_ card: WantedCard, listed: WantedContent, canChange: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WantedCell(gameID: state.gameID, card: card, left: listed.countText(for: card),
                       label: listed.accessibilityText(for: card), link: listed.link(for: card))
                .accessibilityIdentifier("wanted-cell-\(card.id)")
            HStack(spacing: 8) {
                CountControl(count: card.entry.count, label: "\(card.name), wanted", prefix: "wanted-cell", key: card.id) {
                    step(by: $0 - card.entry.count, card: card)
                }
                Spacer(minLength: 0)
            }
            .disabled(!canChange)
        }
    }

    /// As on the card page: the step goes onto the library's current count, so two clicks before the next render both
    /// count; 0 takes the card off the list.
    private func step(by delta: Int, card: WantedCard) {
        let library = model.library, game = state.gameID
        library.setWanted(library.wantedCount(game: game, cardKey: card.id) + delta, game: game, cardKey: card.id,
                          name: card.entry.name)
    }
}

/// A Wanted cell (`CardCell`): the card's name, `left` (`×n`, or `×n · <set>` when pinned) and its price. A card with a
/// printing opens its card page on the shown printing; one that left a settled catalog opens its small page; a pending one
/// opens nothing and takes no hover. The caller gives it its identifier.
struct WantedCell: View {
    let gameID: String
    let card: WantedCard
    let left: String
    let label: String
    let link: WantedCellLink

    var body: some View {
        let cell = CardCell(content: CellContent(product: card.shown, name: card.name, left: left, price: card.price))
        switch (link, card.shown) {
        case (.card, let shown?):
            NavigationLink(value: CardTarget(gameID: gameID, cardKey: card.id, startProductID: shown.productID)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
        case (.unknownCard, _):
            NavigationLink(value: UnknownCard(gameID: gameID, cardKey: card.id, name: card.name)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
        default:
            cell
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }
}

/// The page of a wanted card that is not in the catalog any more (Review Focus 4): its saved name, one sentence, and its
/// wanted count, so the entry can be changed or removed by hand. No pin: there is no printing to pin.
struct UnknownCardPage: View {
    let card: UnknownCard
    @Environment(AppModel.self) private var model

    var body: some View {
        let locked = model.library.countsLocked(game: card.gameID)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(card.name)
                    .font(Theme.pageTitleFont)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-title")
                Text("This card is not in the catalog any more.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                RuleLine()
                VStack(alignment: .leading, spacing: 8) {
                    WantedLine(gameID: card.gameID, cardKey: card.cardKey, name: card.name, pin: nil)
                    if let locked { CountsLockedLine(text: locked) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { Theme.ground.ignoresSafeArea() }
        .navigationTitle(card.name)
    }
}
