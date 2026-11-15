import SwiftUI

/// What All cards shows for one game: the search, the filters, the last results, the gallery's scroll position and the
/// open card pages. The window keeps it (`CatalogMemory`), so a visit to the Collection loses none of it.
@Observable
final class CatalogScreenState {
    let gameID: String
    var text: String
    var filter = CardFilter()
    var path = NavigationPath()
    /// Nil until the first search has ended.
    var cards: [CardSummary]?
    var hasMore = false
    var catalogEmpty = false
    /// The card at the top of the gallery.
    var scrolledTo: String?
    /// A deck's search only: every printing of each card in `cards`, in the catalog's order (newest set first), read in
    /// one batched call per search; a cell's kind comes from them (`CardKinds.deckKind`), not from its cover alone, which
    /// a filter chose. A card without an entry has no kind yet: its count control is off.
    var deckPrintings: [String: [ProductRecord]] = [:]

    init(gameID: String, search: String) {
        self.gameID = gameID
        text = search
    }

    /// How many of the three menus (Set, Rarity, Type) have a choice. The search text is not a filter.
    var filtersOn: Int { [filter.groupID != nil, filter.rarity != nil, filter.typeFacet != nil].filter { $0 }.count }

    /// Sets the three menus back to "All"; the search text stays.
    func clearFilters() {
        filter = CardFilter()
    }
}

/// The window's All cards state: the current game's only; another game starts afresh with the `-search` text, as before.
/// Not observed: it hands out the same `CatalogScreenState` for as long as the game stays.
final class CatalogMemory {
    private var current: CatalogScreenState?

    func state(game: String, search: String?) -> CatalogScreenState {
        if let current, current.gameID == game { return current }
        let fresh = CatalogScreenState(gameID: game, search: search ?? "")
        current = fresh
        return fresh
    }

    /// As `ScreenMemory.keep(game:)`: a state of another game than the window's is dropped.
    func keep(game: String) {
        if let current, current.gameID != game { self.current = nil }
    }
}

/// The catalog of the selected game: search field, three filter menus, and a gallery of cards. All cards shows it as its
/// root; a deck's "Add cards" pushes it on the deck's stack with the deck as its target (`deckID`, D10): the title "Add to
/// <deck name>", and under every cell a `CountControl` with the deck's copies of the card over all its sections.
struct CatalogSearchView: View {
    private static let limit = 300
    /// Placeholder cells while the first search runs: about one window of the gallery.
    private static let placeholders = 12

    @Environment(AppModel.self) private var model
    @Bindable var state: CatalogScreenState
    /// The deck "Add cards" adds to; nil for All cards.
    var deckID: String? = nil
    @State private var sets: [SetRecord] = []
    @State private var confirmReset = false

    var body: some View {
        framed(content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Theme.ground.ignoresSafeArea() })
            .navigationSubtitle(subtitle)
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    FilterMenu(title: "Set", selection: $state.filter.groupID, choices: sets.map { ($0.groupID, $0.name) })
                    FilterMenu(title: "Rarity", selection: $state.filter.rarity, choices: (model.facets(game: model.gameID)?.rarities ?? []).map { ($0, $0) })
                    FilterMenu(title: "Type", selection: $state.filter.typeFacet, choices: (model.facets(game: model.gameID)?.types ?? []).map { ($0, $0) })
                    if state.filtersOn > 0 {
                        ClearFiltersButton(identifier: "catalog-clear-filters") { state.clearFilters() }
                    }
                }
            }
            .task(id: SearchKey(text: state.text, filter: state.filter, catalogVersion: model.catalogVersion)) { await search() }
            // The set list is cheap; the rarity and type lists come from `model.facets` (a file, P4).
            .task(id: model.filtersVersion) { await loadSets() }
    }

    /// All cards: the game's name as the title, and the pages its cells open. A deck's search: "Add to <deck name>" and the
    /// identifier `deck-add-screen`; its cells open card pages through the deck's stack, which has their destination
    /// (`listScreen`).
    @ViewBuilder private func framed(_ view: some View) -> some View {
        if let deckID {
            view
                .navigationTitle("Add to \(model.library.deck(game: state.gameID, id: deckID)?.name ?? "deck")")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("deck-add-screen")
        } else {
            view
                .navigationTitle(model.game.name)
                .navigationDestination(for: CardSummary.self) { CardPageView(cardKey: $0.id, startProductID: nil) }
                .navigationDestination(for: CardTarget.self) { CardPageView(cardKey: $0.cardKey, startProductID: $0.startProductID) }
        }
    }

    @ViewBuilder private var content: some View {
        if let cards = state.cards, cards.isEmpty {
            Group {
                if state.catalogEmpty {
                    emptyCatalog
                } else {
                    EmptyMessage(sentence: state.text.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "No card matches these filters."
                                 : "No card matches \"\(state.text)\".")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("empty-state")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cellMinWidth), spacing: Theme.columnGap)],
                          spacing: Theme.rowGap) {
                    if let cards = state.cards {
                        ForEach(cards) { card in
                            if let deckID {
                                DeckAddCell(gameID: state.gameID, deckID: deckID, card: card, printings: state.deckPrintings[card.id],
                                            content: cellContent(card))
                            } else {
                                NavigationLink(value: card) { CardCell(content: cellContent(card)) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("card-cell-\(card.id)")
                            }
                        }
                    } else {
                        // Loading: until the first search has ended, the final layout with flat `surface` blocks where
                        // the pictures will be. No shimmer.
                        ForEach(0..<Self.placeholders, id: \.self) { _ in PlaceholderCell() }
                    }
                }
                .scrollTargetLayout()
                .padding(Theme.margin)
            }
            .scrollPosition(id: $state.scrolledTo, anchor: .top)
            .accessibilityIdentifier("gallery")
        }
    }

    /// A catalog cell: the card's cover printing, how many printings passed the filter, and the cheapest of their prices.
    private func cellContent(_ card: CardSummary) -> CellContent {
        CellContent(product: card.cover, name: card.name, left: card.printings > 1 ? "\(card.printings) printings" : "",
                    price: model.prices.cheapest(game: card.cover.gameID, productIDs: card.productIDs))
    }

    /// The game has no card at all. "Downloading" only while a sync runs; otherwise the reason, and a way to try again.
    /// With no store file open (P8), the reason and a reset that the next launch does (not for a lack of disk space).
    /// One sentence and at most one action each; the status line below the sidebar keeps the details (progress, reason).
    @ViewBuilder private var emptyCatalog: some View {
        if model.storeFailure != nil {
            Group {
                if model.catalogResetRequested {
                    EmptyMessage(sentence: "Quit and open the app again to reset the catalog.")
                } else {
                    // One clean sentence here; the technical reason (`failure`) is the status line's.
                    EmptyMessage(sentence: "The catalog cannot be opened.") {
                        if model.canResetCatalog {
                            Button("Reset the catalog…") { confirmReset = true }
                                .accessibilityIdentifier("reset-catalog")
                        }
                    }
                }
            }
            .confirmationDialog("The catalog on this Mac is set aside and downloaded again. About 1,100 requests and 205 MB. If its sets were already fetched today, the download starts tomorrow.",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset the catalog") { model.requestCatalogReset() }
            }
        } else if model.catalogWaits {
            // The sets were fetched today into a store that is gone: no Try again before the next UTC day. Before the
            // "Downloading" branch: a held sync still runs the price step, but downloads no catalog.
            EmptyMessage(sentence: StatusText.resetWaits)
        } else if model.status.isSyncing {
            EmptyMessage(sentence: "Downloading the catalog…")
        } else if model.options.offline {
            EmptyMessage(sentence: "Offline. The catalog is empty.")
        } else {
            EmptyMessage(sentence: "The catalog could not be downloaded.") {
                Button("Try again") { Task { await model.refresh(rebuild: false) } }
            }
        }
    }

    private var subtitle: String {
        guard let cards = state.cards else { return "" }
        if state.hasMore { return "\(Self.limit)+ cards" }
        return cards.count == 1 ? "1 card" : "\(cards.count) cards"
    }

    private func search() async {
        // Debounce: a new key cancels this task while it sleeps.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let game = model.gameID
        // One card more than shown tells whether there are more.
        let found = (try? await model.reader.search(game: game, text: state.text, filter: state.filter, limit: Self.limit + 1)) ?? []
        let empty = found.isEmpty ? (try? await model.reader.progress(game: game))?.fetched == 0 : false
        guard !Task.isCancelled else { return }
        let shown = Array(found.prefix(Self.limit))
        // A deck's search: the printings of the cards shown, in one call for the whole result, off the main thread
        // (`reader`), before the cells show, so a cell's kind is the card page's.
        if deckID != nil {
            let printings = (try? await model.reader.printings(game: game, cardKeys: shown.map(\.id))) ?? [:]
            guard !Task.isCancelled else { return }
            if state.deckPrintings != printings { state.deckPrintings = printings }
        }
        // On a return to All cards the same search runs again: unchanged results are not written, so nothing redraws.
        if state.cards != shown { state.cards = shown }
        state.hasMore = found.count > Self.limit
        state.catalogEmpty = empty
    }

    private func loadSets() async {
        sets = (try? await model.reader.sets(game: model.gameID)) ?? []
    }
}

/// A result cell of a deck's search (D10): the catalog's cell (a link to the card page on its cover printing, through the
/// deck's stack), 8 pt, then a `CountControl` with the deck's copies of the card over all its sections. `+` adds one copy to
/// the card's default section (`DeckPage.addingOne`) and is off at 999 or more there (`DeckPage.searchCount`); `−` takes one
/// off that section first, then off the others in the format's order (`DeckPage.takingOne`). The card's kind comes from all
/// its printings (`printings`, the search's batched read; `AppModel.deckKind`), as on its card page. Both are off while the
/// printings are not read, the game cannot change, or the deck is gone.
private struct DeckAddCell: View {
    let gameID: String
    let deckID: String
    let card: CardSummary
    /// Every printing of the card, newest set first; nil until the search has read them.
    let printings: [ProductRecord]?
    let content: CellContent
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let game = Games.game(gameID) ?? Games.all[0]
        let deck = library.deck(game: gameID, id: deckID)
        let adding = printings.map { DeckCardToAdd(cardKey: card.id, name: card.name, kind: model.deckKind(game: game, printings: $0)) }
        let count = deck.flatMap { deck in adding.map { DeckPage.searchCount(deck, $0, game: game) } }
        let usable = count != nil && library.canChange(game: gameID)
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: CardTarget(gameID: gameID, cardKey: card.id, startProductID: card.cover.productID)) {
                CardCell(content: content)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("card-cell-\(card.id)")
            HStack(spacing: 8) {
                CountControl(count: usable ? count?.copies : nil, label: card.name, maximum: count?.plusLimit,
                             prefix: "deck-add", key: card.id) { new in
                    guard let adding, let count else { return }
                    library.changeDeck(game: gameID, id: deckID) { deck in
                        new > count.copies ? DeckPage.addingOne(deck, adding, game: game) : DeckPage.takingOne(deck, adding, game: game)
                    }
                }
                Spacer(minLength: 0)
            }
            .disabled(!usable)
        }
    }
}

/// A gallery cell before its card is known: the picture's `surface` block and the two text lines' height, blank. All
/// cards and the Collection use it.
struct PlaceholderCell: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.surface
                .aspectRatio(59.0 / 86.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.pictureRadius))
            Text(" ").font(Theme.bodyFont).padding(.top, 7)
            Text(" ").font(Theme.lineFont).padding(.top, 1)
        }
        .accessibilityHidden(true)
    }
}

private nonisolated struct SearchKey: Equatable {
    let text: String
    let filter: CardFilter
    let catalogVersion: Int
}

/// "Clear" in a toolbar, right of the filter menus, only while a filter is on (the caller leaves it out otherwise, not
/// disabled): a plain text button as the system draws it, no icon, no accent.
struct ClearFiltersButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button("Clear", action: action)
            .help("Clear filters")
            .accessibilityIdentifier(identifier)
    }
}

/// A toolbar menu that holds a picker with "All" and the choices. Its label is the title, or the choice made.
private struct FilterMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value?
    let choices: [(value: Value, name: String)]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                Text("All").tag(Value?.none)
                ForEach(choices, id: \.value) { choice in
                    Text(choice.name).tag(Value?.some(choice.value))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(choices.first { $0.value == selection }?.name ?? title)
        }
        .accessibilityIdentifier("filter-\(title.lowercased())")
    }
}
