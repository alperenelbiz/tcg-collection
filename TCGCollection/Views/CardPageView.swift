import SwiftUI

/// Where a card page opens: the game, the card, and optionally the printing shown first.
nonisolated struct CardTarget: Hashable, Sendable {
    let gameID: String
    let cardKey: String
    let startProductID: Int?
}

/// The page of one card: large picture, facts, prices of the shown printing, rules text, and every printing.
struct CardPageView: View {
    let cardKey: String
    let startProductID: Int?

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// Nil until the lookup has ended.
    @State private var printings: [ProductRecord]?
    @State private var setNames: [Int: String] = [:]
    @State private var shownID: Int?

    init(cardKey: String, startProductID: Int?) {
        self.cardKey = cardKey
        self.startProductID = startProductID
        _shownID = State(initialValue: startProductID)
    }

    private static let ground = Color(white: 0.075)

    private var shown: ProductRecord? {
        printings?.first { $0.productID == shownID } ?? printings?.first
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Self.ground.ignoresSafeArea() }
            .navigationTitle(shown?.cardName ?? "")
            .toolbar {
                ToolbarItem {
                    Button("Open on TCGplayer") {
                        if let url = shown.flatMap({ URL(string: $0.url) }) { openURL(url) }
                    }
                    .disabled(shown.flatMap { URL(string: $0.url) } == nil)
                    .accessibilityIdentifier("open-tcgplayer")
                }
            }
            .task(id: cardKey) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let printings, printings.isEmpty {
            ContentUnavailableView { Text("This card is not in the catalog.") }
        } else if let shown, let game = Games.game(shown.gameID), let printings {
            ScrollView {
                layout(shown: shown, game: game, printings: printings)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("card-page")
        } else {
            // A view with no content gets no lifecycle events, and the lookup starts from `task`.
            Color.clear
        }
    }

    @ViewBuilder private func layout(shown: ProductRecord, game: GameDefinition, printings: [ProductRecord]) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 32) {
            CardImage(product: shown, size: .large).frame(width: 280)
            details(shown: shown, game: game, printings: printings)
        }
        #else
        VStack(alignment: .leading, spacing: 20) {
            CardImage(product: shown, size: .large).frame(maxWidth: 280).frame(maxWidth: .infinity)
            details(shown: shown, game: game, printings: printings)
        }
        #endif
    }

    private func details(shown: ProductRecord, game: GameDefinition, printings: [ProductRecord]) -> some View {
        let stats = CardFacts.stats(shown, game: game)
        let finishes = model.prices.prices(game: game.id, productID: shown.productID)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shown.cardName).font(.title.bold()).textSelection(.enabled)
                    .accessibilityIdentifier("card-title")
                Text(CardFacts.line(setName: setNames[shown.groupID] ?? "", product: shown))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-facts-line")
                if !shown.cardType.isEmpty { Text(shown.cardType).textSelection(.enabled) }
            }
            if !stats.isEmpty {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(stats, id: \.label) { LabeledValue(label: $0.label, value: $0.value) }
                }
            }
            Divider()
            if finishes.isEmpty {
                Text("No price").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(finishes, id: \.finish) { LabeledValue(label: $0.finish, value: CardFacts.priceText($0.price.shown)) }
                }
            }
            if !shown.rulesText.isEmpty {
                Divider()
                // Selection is set on single texts only: on a container it takes the taps of the printing rows.
                Text(shown.rulesText).textSelection(.enabled)
            }
            if printings.count > 1 {
                Divider()
                otherPrintings(printings, game: game)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func otherPrintings(_ printings: [ProductRecord], game: GameDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other printings").font(.headline)
            ForEach(printings, id: \.productID) { printing in
                Button { shownID = printing.productID } label: {
                    HStack(spacing: 12) {
                        Text(setNames[printing.groupID] ?? "").lineLimit(1)
                        Text(printing.number).foregroundStyle(.secondary)
                        Text(printing.rarity).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(CardFacts.priceText(model.prices.cheapest(game: game.id, productIDs: [printing.productID])))
                            .monospacedDigit()
                    }
                    .fontWeight(printing.productID == shown?.productID ? .semibold : .regular)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("printing-row-\(printing.productID)")
            }
        }
    }

    private func load() async {
        let store = model.reader, game = model.gameID, key = cardKey
        let found = (try? await store.printings(game: game, cardKey: key)) ?? []
        let sets = (try? await store.sets(game: game)) ?? []
        setNames = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
        if shownID == nil || !found.contains(where: { $0.productID == shownID }) { shownID = found.first?.productID }
        printings = found
    }
}

/// A small label over a value, for stats and prices.
private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
