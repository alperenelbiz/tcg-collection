import SwiftUI

/// The catalog of the selected game: search field, three filter menus, and a gallery of cards.
struct CatalogSearchView: View {
    private static let limit = 300
    /// The content ground: flat and dark (spec 6).
    private static let ground = Color(white: 0.075)

    @Environment(AppModel.self) private var model
    @State private var text: String
    @State private var filter = CardFilter()
    /// Nil until the first search has ended.
    @State private var cards: [CardSummary]?
    @State private var hasMore = false
    @State private var catalogEmpty = false
    @State private var sets: [SetRecord] = []
    @State private var rarities: [String] = []
    @State private var types: [String] = []
    @State private var confirmReset = false

    init(search: String) {
        _text = State(initialValue: search)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Self.ground.ignoresSafeArea() }
            .navigationTitle(model.game.name)
            .navigationSubtitle(subtitle)
            .searchable(text: $text)
            .navigationDestination(for: CardSummary.self) { CardPageView(cardKey: $0.id, startProductID: nil) }
            .navigationDestination(for: CardTarget.self) { CardPageView(cardKey: $0.cardKey, startProductID: $0.startProductID) }
            .toolbar {
                ToolbarItemGroup {
                    FilterMenu(title: "Set", selection: $filter.groupID, choices: sets.map { ($0.groupID, $0.name) })
                    FilterMenu(title: "Rarity", selection: $filter.rarity, choices: rarities.map { ($0, $0) })
                    FilterMenu(title: "Type", selection: $filter.typeFacet, choices: types.map { ($0, $0) })
                }
            }
            .task(id: SearchKey(text: text, filter: filter, catalogVersion: model.catalogVersion)) { await search() }
            // The rarity and type lists read every product of the game: once per game, and again after a sync step.
            .task(id: model.filtersVersion) { await loadFilterChoices() }
    }

    @ViewBuilder private var content: some View {
        if let cards, cards.isEmpty {
            Group {
                if catalogEmpty {
                    emptyCatalog
                } else {
                    ContentUnavailableView {
                        Text(text.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "No card matches these filters."
                             : "No card matches \"\(text)\".")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("empty-state")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(cards ?? []) { CardCell(summary: $0) }
                }
                .padding(20)
            }
            .accessibilityIdentifier("gallery")
        }
    }

    /// The game has no card at all. "Downloading" only while a sync runs; otherwise the reason, and a way to try again.
    /// With no store file open (P8), the reason and a reset that the next launch does.
    @ViewBuilder private var emptyCatalog: some View {
        if let failure = model.storeFailure {
            ContentUnavailableView {
                Text("The catalog cannot be opened.")
            } description: {
                Text(failure)
            } actions: {
                if model.catalogResetRequested {
                    Text("Quit and open the app again to reset the catalog.")
                } else {
                    Button("Reset the catalog…") { confirmReset = true }
                        .accessibilityIdentifier("reset-catalog")
                }
            }
            .confirmationDialog("The catalog on this Mac is set aside and downloaded again. About 1,100 requests and 190 MB.",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset the catalog") { model.requestCatalogReset() }
            }
        } else if model.status.isSyncing {
            ContentUnavailableView {
                Text("Downloading the catalog…")
            } description: {
                Text(model.status.text)
            }
        } else if model.options.offline {
            ContentUnavailableView {
                Text("Offline. The catalog is empty.")
            }
        } else {
            ContentUnavailableView {
                Text("The catalog could not be downloaded.")
            } description: {
                Text(model.status.text)
            } actions: {
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

    private func loadFilterChoices() async {
        let game = model.gameID, store = model.reader
        sets = (try? await store.sets(game: game)) ?? []
        rarities = (try? await store.rarities(game: game)) ?? []
        types = (try? await store.typeFacets(game: game)) ?? []
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
