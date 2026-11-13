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

    init(gameID: String, search: String) {
        self.gameID = gameID
        text = search
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

/// The catalog of the selected game: search field, three filter menus, and a gallery of cards.
struct CatalogSearchView: View {
    private static let limit = 300
    /// Placeholder cells while the first search runs: about one window of the gallery.
    private static let placeholders = 12

    @Environment(AppModel.self) private var model
    @Bindable var state: CatalogScreenState
    @State private var sets: [SetRecord] = []
    @State private var confirmReset = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Theme.ground.ignoresSafeArea() }
            .navigationTitle(model.game.name)
            .navigationSubtitle(subtitle)
            .searchable(text: $state.text)
            .navigationDestination(for: CardSummary.self) { CardPageView(cardKey: $0.id, startProductID: nil) }
            .navigationDestination(for: CardTarget.self) { CardPageView(cardKey: $0.cardKey, startProductID: $0.startProductID) }
            .toolbar {
                ToolbarItemGroup {
                    FilterMenu(title: "Set", selection: $state.filter.groupID, choices: sets.map { ($0.groupID, $0.name) })
                    FilterMenu(title: "Rarity", selection: $state.filter.rarity, choices: (model.facets(game: model.gameID)?.rarities ?? []).map { ($0, $0) })
                    FilterMenu(title: "Type", selection: $state.filter.typeFacet, choices: (model.facets(game: model.gameID)?.types ?? []).map { ($0, $0) })
                }
            }
            .task(id: SearchKey(text: state.text, filter: state.filter, catalogVersion: model.catalogVersion)) { await search() }
            // The set list is cheap; the rarity and type lists come from `model.facets` (a file, P4).
            .task(id: model.filtersVersion) { await loadSets() }
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
                            NavigationLink(value: card) { CardCell(content: cellContent(card)) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("card-cell-\(card.id)")
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
        // On a return to All cards the same search runs again: unchanged results are not written, so nothing redraws.
        if state.cards != shown { state.cards = shown }
        state.hasMore = found.count > Self.limit
        state.catalogEmpty = empty
    }

    private func loadSets() async {
        sets = (try? await model.reader.sets(game: model.gameID)) ?? []
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
