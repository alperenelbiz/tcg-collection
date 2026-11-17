import SwiftUI

extension WantedList {
    /// C12, the price of a wanted card from the price table, for `WantedList.cards`: its pin's price for the pinned finish
    /// (`PriceTable.shown`), and when that finish has none the pinned printing's cheapest finish (B4: the price is that
    /// printing's; the pin stays as it is); without a pin the cheapest over the printings it is given
    /// (`PriceTable.cheapest`).
    @MainActor static func price(_ prices: PriceTable, game: String) -> (WantedEntry, [ProductRecord]) -> ShownPrice? {
        { entry, printings in
            if let pin = entry.pin {
                return prices.shown(game: game, key: pin) ?? prices.cheapest(game: game, productIDs: [pin.productID])
            }
            return prices.cheapest(game: game, productIDs: printings.map(\.productID))
        }
    }
}

/// The Wanted list joined with the catalog (`CatalogJoin`): the printings of every wanted card and the set names. The
/// live list is laid on it on every render (`content`), so a count or a pin shows at once.
typealias WantedJoin = CatalogJoin<WantedRead>

extension CatalogJoin where Read == WantedRead {
    /// What Wanted lists (`WantedList.content`): the hand-added entries and the cards the active `decks` miss (E5); nil
    /// until a join of this game has ended. The catalog counts as settled as it was for the join that made `read`, as for
    /// the Collection.
    func content(wanted: [WantedEntry], decks: [Deck], sharing: [String: Bool],
                 price: (WantedEntry, [ProductRecord]) -> ShownPrice?) -> WantedContent? {
        guard let joined else { return nil }
        return WantedList.content(wanted, decks: decks, sharing: sharing, read: read, joinFailed: failed,
                                  catalogHasProducts: catalogHasProducts, catalogSettled: joined.catalogSettled, price: price)
    }

    /// Reads the printings of the game's wanted cards and of every card of its active decks (one store call) and its set
    /// names, and counts the copies owned of each of those cards and finds the basic ones (`run`; the join's key changes
    /// with every change of the collection, the decks and the sharing answers).
    func run(_ key: CollectionJoin, model: AppModel) async {
        guard let definition = Games.game(key.game) else { return }
        let library = model.library
        let keys = WantedList.joinKeys(wanted: library.wanted(game: key.game), decks: model.decksInPlay(game: key.game))
        let rows = library.rows(game: key.game)
        await run(key, loaded: library.isLoaded, reader: model.reader) { reader, game in
            let printings = try await reader.printings(game: game, cardKeys: Array(keys))
            let sets = try await reader.sets(game: game)
            let names = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
            return WantedList.read(game: definition, printings: printings, keys: keys, rows: rows, setNames: names)
        }
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
    /// "Make PDF…" (C10, C11): kept with the screen, so a card page opened on its stack does not stop it; the stack going
    /// away cancels it (`pdfSaving`).
    let export = PDFExport()
    /// The pending cards when "Decisions (n)…" was clicked: the rows of the sheet it opens (`SharingSheet`).
    var sharingNeeds: [CardNeed] = []

    init(gameID: String) {
        self.gameID = gameID
    }

    /// True when the search text has a word to match.
    var searching: Bool { !CardName.searchKey(text).isEmpty }

    /// Final fix A1: the sheet "Sharing decisions" closed (its `onDismiss`), or Wanted went away under it (its
    /// `onDisappear`: a game switch, another screen): the model's flag and the sheet's rows go with it, so `showsSheet`
    /// never stays true for a sheet that is not there.
    func endSharing(model: AppModel) {
        model.showsSharing = false
        sharingNeeds = []
    }
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

    var body: some View {
        let library = model.library, game = state.gameID
        // Nil until a join of this game has ended. The wanted counts and pins are read here, so a change shows at once.
        // G7: the decks in play (none without the player role: the hand-added list, nothing pending, no "Decisions…").
        let listed = state.join.content(wanted: library.wanted(game: game), decks: model.decksInPlay(game: game),
                                        sharing: library.sharing(game: game), price: WantedList.price(model.prices, game: game))
        let all = listed?.cards ?? []
        let shown = WantedList.sorted(WantedList.filtered(all, text: state.text), by: state.sort)
        let phase = ListPhase.of(listing: listed.map { !$0.cards.isEmpty }, game: game, library: library)
        // The list is read (also an empty one): its PDF can be made.
        let pdfReady = phase == .list || phase == .empty
        let launchReady = PDFExport.launchReady(listRead: pdfReady, joined: state.join.joined, offline: model.options.offline)
        let join = WantedJoin.key(game: game, model: model)
        let pending = phase == .list ? all.filter(\.pending).count : 0
        content(phase, shown: shown, listed: listed)
            .listScreen("wanted", note: phase == .list ? listed?.note : nil)
            .navigationDestination(for: UnknownCard.self) { card in
                UnknownCardPage(card: card)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
            .navigationTitle("Wanted")
            .navigationSubtitle(phase != .list ? "" : state.searching ? WantedList.totals(shown, of: all) : WantedList.totals(all))
            .searchable(text: $state.text)
            #if os(iOS)
            // A54: the toolbar's items in one "…" menu.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MoreMenu(identifier: "wanted-more") {
                        // E7: only while a card is pending; the sheet's rows are the pending cards of this moment.
                        if pending > 0 {
                            Button("Decisions (\(pending))…") { openSharing(Set(all.filter(\.pending).map(\.id))) }
                                .disabled(!library.canChange(game: game))
                                .accessibilityIdentifier("wanted-decisions")
                        }
                        PDFButton(export: state.export, identifier: "wanted-pdf", enabled: pdfReady) { pdfJob(all) }
                        SortMenu(sort: $state.sort, identifier: "wanted-sort")
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItemGroup {
                    // E7: only while a card is pending; the sheet's rows are the pending cards of this moment.
                    if pending > 0 {
                        Button("Decisions (\(pending))…") { openSharing(Set(all.filter(\.pending).map(\.id))) }
                            .disabled(!library.canChange(game: game))
                            .accessibilityIdentifier("wanted-decisions")
                    }
                    PDFButton(export: state.export, identifier: "wanted-pdf", enabled: pdfReady) { pdfJob(all) }
                    SortMenu(sort: $state.sort, identifier: "wanted-sort")
                }
            }
            #endif
            .launchPDF(state.export, screen: .wanted, ready: launchReady, model: model) { pdfJob(all) }
            .task(id: join) { await state.join.run(join, model: model) }
            .sheet(isPresented: Bindable(model).showsSharing, onDismiss: { state.endSharing(model: model) }) {
                SharingSheet(gameID: game, needs: state.sharingNeeds)
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
            .onDisappear { state.endSharing(model: model) }
    }

    /// "Decisions (n)…": the sheet on the cards the cells show as pending (`pending`, their keys), with their needs made as
    /// the list makes them (the library's decks and answers, the last join's read).
    private func openSharing(_ pending: Set<String>) {
        let library = model.library, game = state.gameID
        state.sharingNeeds = WantedList.needs(decks: model.decksInPlay(game: game), sharing: library.sharing(game: game),
                                              read: state.join.read).values.filter { pending.contains($0.cardKey) }
        model.showsSharing = true
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
                Button("Search a card") { model.showRoot(of: .allCards) }
                    .accessibilityIdentifier("wanted-search-catalog")
            }
        case .list:
            // `.list` comes only with a listing (`listed`).
            if let listed, !shown.isEmpty {
                let canChange = model.library.canChange(game: state.gameID)
                ScrollView {
                    // Only a pending cell has the extra row: cells of one grid row align at the top.
                    GalleryGrid(alignment: .top) {
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

    /// C6, A24: the cell (its count line the total, `×3 · 2 for decks`), 8 pt, then one line with the hand-added count
    /// (`−` at 1 takes the hand entry and its pin off the list; a card the decks miss stays with their part; `−` is off at
    /// 0). A pending card (E3, E7) has one more row 8 pt under it: "Decision pending" (12 pt `muted`), "Share" and "Buy
    /// more" (`PendingRow`). The controls are off while the game cannot change.
    private func cell(_ card: WantedCard, listed: WantedContent, canChange: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WantedCell(gameID: state.gameID, card: card, left: listed.countText(for: card),
                       label: listed.accessibilityText(for: card), link: listed.link(for: card))
                .accessibilityIdentifier("wanted-cell-\(card.id)")
            HStack(spacing: 8) {
                CountControl(count: card.entry.count, label: "\(card.name), wanted", prefix: "wanted-cell", key: card.id,
                             spoken: (remove: "Want one fewer \(card.name)", add: "Want one more \(card.name)")) {
                    Self.step(by: $0 - card.entry.count, card: card, game: state.gameID, library: model.library)
                }
                Spacer(minLength: 0)
            }
            .disabled(!canChange)
            if card.pending {
                PendingRow(gameID: state.gameID, cardKey: card.id)
                    .disabled(!canChange)
            }
        }
    }

    /// As on the card page: the step goes onto the library's current hand-added count, so two clicks before the next render
    /// both count; 0 takes the hand entry off the list. A new entry (`+` on a card only from decks) saves the shown
    /// printing's card name (the card page's title form) when there is a printing, else the deck card's saved name
    /// (`card.entry.name`; final fix A5: never the card key that `CardNeed.name` falls back to when a real name exists).
    static func step(by delta: Int, card: WantedCard, game: String, library: UserLibrary) {
        library.setWanted(library.wantedCount(game: game, cardKey: card.id) + delta, game: game, cardKey: card.id,
                          name: card.shown?.cardName ?? card.entry.name)
    }
}

/// A pending Wanted cell's row (E7): "Decision pending" (12 pt `muted`), then "Share" (writes the answer true) and "Buy
/// more" (false), each `FieldButtonStyle`; one row when the cell is wide enough, else the buttons under the text. A click
/// writes the answer even when the card stopped being pending since the render: an answer on a card that is not in
/// conflict changes no number (Review Focus 1).
private struct PendingRow: View {
    @Environment(AppModel.self) private var model
    let gameID: String
    let cardKey: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                HStack(spacing: 8) { buttons }
            }
        }
    }

    private var label: some View {
        Text("Decision pending")
            .font(Theme.lineFont)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("wanted-pending-\(cardKey)")
    }

    @ViewBuilder private var buttons: some View {
        answer("Share", shared: true, identifier: "wanted-share-\(cardKey)")
        answer("Buy more", shared: false, identifier: "wanted-buy-\(cardKey)")
    }

    private func answer(_ title: String, shared: Bool, identifier: String) -> some View {
        Button(title) { model.library.setShared([cardKey: shared], game: gameID) }
            .buttonStyle(FieldButtonStyle())
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }
}

/// A Wanted cell (`CardCell`): the card's name, `left` (`×n`, `×n · 2 for decks`, `… · <set>` when pinned) and its price. A card with a
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
                    WantedLine(gameID: card.gameID, cardKey: card.cardKey, name: card.name, pin: nil, hasPrinting: false)
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
