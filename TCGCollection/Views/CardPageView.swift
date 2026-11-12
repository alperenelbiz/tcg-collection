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

    private var shown: ProductRecord? {
        printings?.first { $0.productID == shownID } ?? printings?.first
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Theme.ground.ignoresSafeArea() }
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
            EmptyMessage(sentence: "This card is not in the catalog.")
        } else if let shown, let game = Games.game(shown.gameID), let printings {
            ScrollView {
                layout(shown: shown, game: game, printings: printings)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
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
        HStack(alignment: .top, spacing: 28) {
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

    /// Groups are separated by 1 px rules, never boxed: the title block (with the stats), what the user owns of the shown
    /// printing with its prices and count controls, the rules text, the other printings.
    private func details(shown: ProductRecord, game: GameDefinition, printings: [ProductRecord]) -> some View {
        let stats = CardFacts.stats(shown, game: game)
        let finishes = model.prices.prices(game: game.id, productID: shown.productID)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shown.cardName)
                    .font(Theme.pageTitleFont)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-title")
                Text(CardFacts.line(setName: setNames[shown.groupID] ?? "", product: shown))
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-facts-line")
                if !shown.cardType.isEmpty {
                    Text(shown.cardType)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                }
            }
            if !stats.isEmpty {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(stats, id: \.label) { LabeledValue(label: $0.label, value: $0.value) }
                }
                .padding(.top, 18)
            }
            RuleLine()
            OwnedFinishes(gameID: game.id, productID: shown.productID, name: shown.name,
                          offered: finishes.map(\.finish), prices: finishes)
            if !shown.rulesText.isEmpty {
                RuleLine()
                // Selection is set on single texts only: on a container it takes the taps of the printing rows.
                Text(shown.rulesText)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
            if printings.count > 1 {
                RuleLine()
                otherPrintings(printings, game: game)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func otherPrintings(_ printings: [ProductRecord], game: GameDefinition) -> some View {
        // Copies owned per product, over its finishes.
        let owned = Dictionary(model.library.rows(game: game.id).map { ($0.productID, $0.count) }, uniquingKeysWith: +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Other printings")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.muted)
            ForEach(printings, id: \.productID) { printing in
                Button { shownID = printing.productID } label: {
                    HStack(spacing: 12) {
                        // One line per row: the set name gives way (truncates); number, rarity and price keep their width.
                        Text(setNames[printing.groupID] ?? "")
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(printing.number)
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                        Text(printing.rarity)
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                        Spacer(minLength: 8)
                        if let count = owned[printing.productID] {
                            Text("×\(count)")
                                .foregroundStyle(Theme.muted)
                                .monospacedDigit()
                                .fixedSize()
                        }
                        Text(CardFacts.priceText(model.prices.cheapest(game: game.id, productIDs: [printing.productID])))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(Theme.bodyFont)
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

/// What the user owns of one product and how to change it (B5): the line "In your collection: N" (`card-owned`, N over
/// every finish of the product), then one line per finish: its name, its price ("No price" in `muted` when it has none;
/// no price column at all when `prices` is nil) and a `CountControl` labelled with the finish. The finishes are `offered`
/// (the price table's, or `Normal` when there are none) and then every owned finish that `offered` does not list.
/// While the library refuses changes of the game, no number is shown (`—`), the controls are off, and one muted line
/// under them says why (`card-counts-locked`): the game's own problem, or "Reading your collection…".
struct OwnedFinishes: View {
    let gameID: String
    let productID: Int
    /// Saved in a new row: what a reader of the file sees, and what the Collection shows if the product leaves the catalog.
    let name: String
    let offered: [String]
    /// The price table's prices of the product; nil for a page without a price column (a product not in the catalog).
    let prices: [FinishPrice]?

    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        // A refused file reads as no rows: its counts are not known, so none is shown (not a false 0).
        let locked = library.countsLocked(game: gameID)
        let rows = library.rows(game: gameID).filter { $0.productID == productID }
        let finishes = CollectionRules.finishes(priced: offered, owned: rows.map(\.finish))
        VStack(alignment: .leading, spacing: 8) {
            Text("In your collection: \(locked == nil ? String(CollectionRules.copies(rows)) : "—")")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
                .accessibilityIdentifier("card-owned")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(finishes, id: \.self) { finish in
                    let count = CollectionRules.count(rows, for: PrintingKey(productID: productID, finish: finish))
                    GridRow {
                        Text(finish)
                            .foregroundStyle(Theme.text)
                        if let prices {
                            price(prices.first { $0.finish == finish }?.price.shown)
                                .gridColumnAlignment(.trailing)
                        }
                        CountControl(count: locked == nil ? count : nil, label: finish) { step(by: $0 - count, finish: finish) }
                    }
                }
            }
            .font(Theme.bodyFont)
            .disabled(locked != nil)
            if let locked {
                Text(locked)
                    .font(Theme.lineFont)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("card-counts-locked")
            }
        }
    }

    @ViewBuilder private func price(_ shown: ShownPrice?) -> some View {
        if let shown {
            Text(CardFacts.priceText(shown))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
        } else {
            Text("No price")
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
        }
    }

    /// The control sends the count it shows ± 1. Two clicks before the next render would both send the same number, so
    /// the step goes onto the library's current count: every click counts, and a count never goes below 0 (a row that
    /// reaches 0 is removed).
    private func step(by delta: Int, finish: String) {
        let library = model.library, key = PrintingKey(productID: productID, finish: finish)
        library.setCount(library.count(game: gameID, key: key) + delta, game: gameID, key: key, name: name)
    }
}

/// A label (11 pt, `muted`) over a value, for stats.
private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.text)
                .monospacedDigit()
        }
    }
}
