import SwiftUI

/// The catalog of the selected game: search field, three filter menus, and a gallery of cards.
struct CatalogSearchView: View {
    private static let limit = 300
    /// Placeholder cells while the first search runs: about one window of the gallery.
    private static let placeholders = 12

    @Environment(AppModel.self) private var model
    @State private var text: String
    @State private var filter = CardFilter()
    /// Nil until the first search has ended.
    @State private var cards: [CardSummary]?
    @State private var hasMore = false
    @State private var catalogEmpty = false
    @State private var sets: [SetRecord] = []
    @State private var confirmReset = false

    init(search: String) {
        _text = State(initialValue: search)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Theme.ground.ignoresSafeArea() }
            .navigationTitle(model.game.name)
            .navigationSubtitle(subtitle)
            .searchable(text: $text)
            .navigationDestination(for: CardSummary.self) { CardPageView(cardKey: $0.id, startProductID: nil) }
            .navigationDestination(for: CardTarget.self) { CardPageView(cardKey: $0.cardKey, startProductID: $0.startProductID) }
            .toolbar {
                ToolbarItemGroup {
                    FilterMenu(title: "Set", selection: $filter.groupID, choices: sets.map { ($0.groupID, $0.name) })
                    FilterMenu(title: "Rarity", selection: $filter.rarity, choices: (model.facets(game: model.gameID)?.rarities ?? []).map { ($0, $0) })
                    FilterMenu(title: "Type", selection: $filter.typeFacet, choices: (model.facets(game: model.gameID)?.types ?? []).map { ($0, $0) })
                }
            }
            .task(id: SearchKey(text: text, filter: filter, catalogVersion: model.catalogVersion)) { await search() }
            // The set list is cheap; the rarity and type lists come from `model.facets` (a file, P4).
            .task(id: model.filtersVersion) { await loadSets() }
    }

    @ViewBuilder private var content: some View {
        if let cards, cards.isEmpty {
            Group {
                if catalogEmpty {
                    emptyCatalog
                } else {
                    EmptyMessage(sentence: text.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "No card matches these filters."
                                 : "No card matches \"\(text)\".")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("empty-state")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cellMinWidth), spacing: Theme.columnGap)],
                          spacing: Theme.rowGap) {
                    if let cards {
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
                .padding(Theme.margin)
            }
            .accessibilityIdentifier("gallery")
        }
    }

    /// A catalog cell: the card's cover printing, how many printings passed the filter, and the cheapest of their prices.
    private func cellContent(_ card: CardSummary) -> CellContent {
        CellContent(product: card.cover, name: card.name, left: card.printings > 1 ? "\(card.printings) printings" : "",
                    price: model.prices.cheapest(game: card.cover.gameID, productIDs: card.productIDs), selected: false)
    }

    /// The game has no card at all. "Downloading" only while a sync runs; otherwise the reason, and a way to try again.
    /// With no store file open (P8), the reason and a reset that the next launch does (not for a lack of disk space).
    /// One sentence and at most one action each; the status line below the sidebar keeps the details (progress, reason).
    @ViewBuilder private var emptyCatalog: some View {
        if let failure = model.storeFailure {
            Group {
                if model.catalogResetRequested {
                    EmptyMessage(sentence: "Quit and open the app again to reset the catalog.")
                } else {
                    // The failure text says what happened and what to do.
                    EmptyMessage(sentence: failure) {
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
        guard let cards else { return "" }
        if hasMore { return "\(Self.limit)+ cards" }
        return cards.count == 1 ? "1 card" : "\(cards.count) cards"
    }

    private func search() async {
        // Debounce: a new key cancels this task while it sleeps.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let game = model.gameID
        // One card more than shown tells whether there are more.
        let found = (try? await model.reader.search(game: game, text: text, filter: filter, limit: Self.limit + 1)) ?? []
        let empty = found.isEmpty ? (try? await model.reader.progress(game: game))?.fetched == 0 : false
        guard !Task.isCancelled else { return }
        cards = Array(found.prefix(Self.limit))
        hasMore = found.count > Self.limit
        catalogEmpty = empty
    }

    private func loadSets() async {
        sets = (try? await model.reader.sets(game: model.gameID)) ?? []
    }
}

/// A gallery cell before its card is known: the picture's `surface` block and the two text lines' height, blank.
private struct PlaceholderCell: View {
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
