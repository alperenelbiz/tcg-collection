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
            CardImage(product: shown, size: .page).frame(width: 280)
            details(shown: shown, game: game, printings: printings)
        }
        #else
        VStack(alignment: .leading, spacing: 20) {
            CardImage(product: shown, size: .page).frame(maxWidth: 280).frame(maxWidth: .infinity)
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
            // A new wanted entry saves the card's name (the title), not the printing's bracketed product name. What each
            // printing is names a pin on another printing.
            // The "Decks" block is card-level: the same on every printing's page (the kind from all the printings).
            OwnedFinishes(gameID: game.id, productID: shown.productID, name: shown.name, offered: finishes.map(\.finish),
                          prices: finishes, wanted: (cardKey: cardKey, name: shown.cardName, printings: pinPrintings(printings, game: game)),
                          deckCard: DeckCardToAdd(cardKey: cardKey, name: shown.cardName,
                                                  kind: model.deckKind(game: game, printings: printings)))
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

    /// Each printing of the card as the pin line names it: set, number, rarity, and its first finish line (the price
    /// table's first finish, `Normal` when it has none).
    private func pinPrintings(_ printings: [ProductRecord], game: GameDefinition) -> [Int: PinPrinting] {
        Dictionary(printings.map { printing in
            (printing.productID,
             PinPrinting(set: setNames[printing.groupID] ?? "", number: printing.number, rarity: printing.rarity,
                         firstFinish: model.prices.prices(game: game.id, productID: printing.productID).first?.finish ?? "Normal"))
        }, uniquingKeysWith: { first, _ in first })
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

/// What the user owns and has for sale of one product, and how to change it (B5): the line "In your collection: N"
/// (`card-owned`, N over every finish of the product), the column titles "Owned" and "For sale" once, then one line per
/// finish: its name, its price ("No price" in `muted` when it has none; no price column at all when `prices` is nil), a
/// `CountControl` labelled with the finish (owned) and one for sale (`sale-…-<finish>`; its `+` is off at the owned count).
/// The finishes are `offered` (the price table's, or `Normal` when there are none) and then every owned or for-sale finish
/// that `offered` does not list. Under the lines, for a card of the catalog, its Wanted line (`WantedLine`), whose pin is
/// this product and its first finish line.
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
    /// The card of the page, for its Wanted line: its key, the name a new entry saves, and each of its printings as the pin
    /// line names it (by product id). Nil: no Wanted line (a printing that left the catalog).
    var wanted: (cardKey: String, name: String, printings: [Int: PinPrinting])? = nil
    /// The card of the page, for its "Decks" block (`DeckLines`). Nil: no block (a printing that left the catalog).
    var deckCard: DeckCardToAdd? = nil

    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        // A refused file reads as no rows: its counts are not known, so none is shown (not a false 0).
        let locked = library.countsLocked(game: gameID)
        let rows = library.rows(game: gameID).filter { $0.productID == productID }
        let sale = library.forSale(game: gameID).filter { $0.productID == productID }
        let finishes = CollectionRules.finishes(priced: offered, owned: rows.map(\.finish) + sale.map(\.finish))
        VStack(alignment: .leading, spacing: 8) {
            Text("In your collection: \(locked == nil ? String(CollectionRules.copies(rows)) : "—")")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
                .accessibilityIdentifier("card-owned")
            // 10 pt between the columns: at the 900 pt window the details column is 306 pt wide, and the two count controls
            // take 152 pt of it, so "1st Edition" and a price fit on one line beside them (with 16 pt they did not).
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                // The column titles, once, above the first line: none over the finish and the price.
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    if prices != nil { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    Text("Owned")
                    Text("For sale")
                }
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                ForEach(finishes, id: \.self) { finish in
                    let key = PrintingKey(productID: productID, finish: finish)
                    let count = CollectionRules.count(rows, for: key)
                    let forSale = sale.first { $0.key == key }?.count ?? 0
                    GridRow {
                        // One line when the row fits the column, else two: a finish name is what tells two lines
                        // apart, and a name that may not wrap made the row wider than the column (the window grew).
                        ViewThatFits(in: .horizontal) {
                            finishName(finish).lineLimit(1).fixedSize()
                            finishName(finish).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        if let prices {
                            price(prices.first { $0.finish == finish }?.price.shown)
                                .lineLimit(1)
                                .fixedSize()
                                .gridColumnAlignment(.trailing)
                        }
                        CountControl(count: locked == nil ? count : nil, label: finish) { step(by: $0 - count, finish: finish) }
                        CountControl(count: locked == nil ? forSale : nil, label: "\(finish) for sale", maximum: count,
                                     prefix: "sale", key: finish) { stepForSale(by: $0 - forSale, finish: finish) }
                    }
                }
            }
            .font(Theme.bodyFont)
            .disabled(locked != nil)
            // The pin of "Want this printing": this product and its first finish line (the price table's first finish,
            // `Normal` when it has none). The page has no selected finish.
            if let wanted, let first = finishes.first {
                WantedLine(gameID: gameID, cardKey: wanted.cardKey, name: wanted.name,
                           pin: PrintingKey(productID: productID, finish: first), printings: wanted.printings)
                    .padding(.top, 6)
            }
            if let deckCard {
                DeckLines(gameID: gameID, card: deckCard)
                    .padding(.top, 6)
            }
            if let locked { CountsLockedLine(text: locked) }
        }
    }

    private func finishName(_ finish: String) -> some View {
        Text(finish)
            .foregroundStyle(Theme.text)
            .accessibilityIdentifier("card-finish-\(finish)")
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

    /// The same for the for-sale count; the library keeps it within the owned count.
    private func stepForSale(by delta: Int, finish: String) {
        let library = model.library, key = PrintingKey(productID: productID, finish: finish)
        library.setForSale(library.forSaleCount(game: gameID, key: key) + delta, game: gameID, key: key, name: name)
    }
}

/// Why the count controls of a page are off (`UserLibrary.countsLocked`): one muted line under them.
struct CountsLockedLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.lineFont)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("card-counts-locked")
    }
}

/// A card's Wanted line (C2, C6), under the finish lines of its page: "Wanted" and one `CountControl` for the card
/// (`wanted-minus`, `wanted-value`, `wanted-plus`, read "Want one fewer" / "Want one more"; `−` at 1 takes the card and its
/// pin off the list), and from a count of 1 the pin, so it can be seen and cleared from any page of the card:
/// - no pin: "Want this printing" (`wanted-pin`) pins `pin`, the printing on screen with its first finish line;
/// - pinned to `pin`: "Any printing" (`wanted-pin`) takes the pin away;
/// - pinned to another printing or finish: one muted line (`wanted-pinned`, `pinnedText`) that names the pinned printing,
///   then "Want this printing" (`wanted-pin`, moves the pin here) and "Any printing" (`wanted-unpin`, clears it).
/// `pin` nil (a card not in the catalog): nothing to pin; a pin the entry still has is named and can be cleared. A new
/// entry saves `name`. While the game cannot change: no number (`—`), no pin, the control off; the page's locked line
/// says why.
struct WantedLine: View {
    let gameID: String
    let cardKey: String
    let name: String
    let pin: PrintingKey?
    /// Each printing of the card as the pin line names it, by product id.
    var printings: [Int: PinPrinting] = [:]

    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let locked = library.countsLocked(game: gameID) != nil
        let entry = library.wanted(game: gameID).first { $0.cardKey == cardKey }
        let count = entry?.count ?? 0
        // The pin choices need a count (an entry) and a game that can change.
        let pinned = locked || count == 0 ? nil : entry?.pin
        let offersPin = !locked && count > 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text("Wanted")
                    .foregroundStyle(Theme.text)
                CountControl(count: locked ? nil : count, label: "wanted", prefix: "wanted", key: "",
                             spoken: (remove: "Want one fewer", add: "Want one more")) { step(by: $0 - count) }
                if offersPin, let pin, pinned == nil || pinned == pin {
                    pinButton(pinned == pin ? "Any printing" : "Want this printing", to: pinned == pin ? nil : pin,
                              identifier: "wanted-pin")
                }
            }
            if let pinned, pinned != pin {
                // It names set, number and rarity: it wraps rather than cut (306 pt at the 900 pt window).
                Text(Self.pinnedText(pinned, shown: pin, printings: printings))
                    .font(Theme.lineFont)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wanted-pinned")
                HStack(spacing: 8) {
                    if let pin { pinButton("Want this printing", to: pin, identifier: "wanted-pin") }
                    pinButton("Any printing", to: nil, identifier: "wanted-unpin")
                }
            }
        }
        .font(Theme.bodyFont)
        .disabled(locked)
    }

    /// What the pin line says of `pinned`, seen from the printing `shown` (nil: the page of a card that left the catalog):
    /// - another finish of the product shown: "Pinned to <finish> of this printing";
    /// - another printing: "Pinned to <set> · <number> · <rarity>" (a part the product lacks is left out), then
    ///   " · <finish>" when the pinned finish is not that printing's first finish line; "Pinned to another printing" when
    ///   it has none of them;
    /// - a product that is not a printing of the card any more: "Pinned to a printing that left the catalog".
    static func pinnedText(_ pinned: PrintingKey, shown: PrintingKey?, printings: [Int: PinPrinting]) -> String {
        if let shown, pinned.productID == shown.productID { return "Pinned to \(pinned.finish) of this printing" }
        guard let printing = printings[pinned.productID] else { return "Pinned to a printing that left the catalog" }
        var parts = [printing.set, printing.number, printing.rarity].filter { !$0.isEmpty }
        if parts.isEmpty { return "Pinned to another printing" }
        if pinned.finish != printing.firstFinish { parts.append(pinned.finish) }
        return "Pinned to " + parts.joined(separator: " · ")
    }

    private func pinButton(_ title: String, to key: PrintingKey?, identifier: String) -> some View {
        Button(title) { model.library.setPin(key, game: gameID, cardKey: cardKey) }
            .buttonStyle(FieldButtonStyle())
            .accessibilityIdentifier(identifier)
    }

    /// As the owned count: the step goes onto the library's current count, so two clicks before the next render both
    /// count.
    private func step(by delta: Int) {
        let library = model.library
        library.setWanted(library.wantedCount(game: gameID, cardKey: cardKey) + delta, game: gameID, cardKey: cardKey,
                          name: name)
    }
}

/// A card's "Decks" block (D10), under its Wanted line: "Decks", then one line per (deck, section) that holds the card
/// (`DeckPage.cardLines`: deck order, then the format's section order): the deck's name, the section's name in `muted`, a
/// `CountControl` (`deck-line-…-<deckID>-<section>`; `−` at 1 takes the card out of that section, `+` is off at 999 or
/// more); then the menu "Add to deck" (`card-add-to-deck`): every deck of the game (one copy to the card's default
/// section, also for a deck that holds it already) and, after a divider, "New Deck…" (the New Deck sheet; after Create the
/// card is added to the new deck). With no deck in the game, only the menu. Card-level: the same on every printing's page.
/// While the game cannot change: no numbers (`—`), everything off; the page's locked line says why.
struct DeckLines: View {
    let gameID: String
    let card: DeckCardToAdd

    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let locked = library.countsLocked(game: gameID) != nil
        let game = Games.game(gameID) ?? Games.all[0]
        let decks = library.decks(game: gameID)
        let lines = DeckPage.cardLines(decks: decks, cardKey: card.cardKey, game: game)
        VStack(alignment: .leading, spacing: 6) {
            if !decks.isEmpty {
                Text("Decks")
                    .foregroundStyle(Theme.text)
            }
            if !lines.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(lines) { line in
                        GridRow {
                            Text(line.deckName)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(line.sectionName)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .fixedSize()
                            CountControl(count: locked ? nil : line.count, label: "\(line.deckName), \(line.sectionName)",
                                         maximum: DeckRules.maxCount, prefix: "deck-line", key: line.id) {
                                step(by: $0 - line.count, line: line)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("deck-line-\(line.id)")
                    }
                }
            }
            addMenu(decks, game: game)
        }
        .font(Theme.bodyFont)
        .disabled(locked)
    }

    private func addMenu(_ decks: [Deck], game: GameDefinition) -> some View {
        Menu("Add to deck") {
            ForEach(decks) { deck in
                Button(deck.name) {
                    model.library.changeDeck(game: gameID, id: deck.id) { DeckPage.addingOne($0, card, game: game) }
                }
                .accessibilityIdentifier("card-add-to-deck-\(deck.id)")
            }
            if !decks.isEmpty { Divider() }
            Button("New Deck…") {
                model.newDeckCard = card
                model.showsNewDeck = true
            }
            .accessibilityIdentifier("card-add-to-deck-new")
        }
        .fixedSize()
        .accessibilityIdentifier("card-add-to-deck")
    }

    /// As on the deck page: the step goes onto the deck's current count of the card in that section, so two clicks before
    /// the next render both count; 0 takes the card out of the section.
    private func step(by delta: Int, line: DeckCardLine) {
        model.library.changeDeck(game: gameID, id: line.deckID) { deck in
            guard let now = deck.cards.first(where: { $0.cardKey == card.cardKey && $0.section == line.section }) else { return deck }
            return DeckRules.setting(deck, count: now.count + delta, cardKey: card.cardKey, name: now.name, section: line.section)
        }
    }
}

/// One printing of a card as the pin line names it (`WantedLine.pinnedText`).
nonisolated struct PinPrinting: Equatable, Sendable {
    let set: String
    let number: String
    let rarity: String
    /// The printing's first finish line on its page: the price table's first finish, `Normal` when it has none.
    let firstFinish: String
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
