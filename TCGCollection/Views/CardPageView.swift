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
                    .padding(.horizontal, Self.sideMargin)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("card-page")
        } else {
            // A view with no content gets no lifecycle events, and the lookup starts from `task`.
            Color.clear
        }
    }

    /// The page's sides: 28 pt on the Mac; the iPhone's margin (16 pt), so the column is the screen's width less it.
    #if os(iOS)
    private static let sideMargin = Theme.margin
    #else
    private static let sideMargin: CGFloat = 28
    #endif

    @ViewBuilder private func layout(shown: ProductRecord, game: GameDefinition, printings: [ProductRecord]) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 28) {
            CardImage(product: shown, size: .page).frame(width: 280)
            details(shown: shown, game: game, printings: printings)
        }
        #else
        VStack(alignment: .leading, spacing: 20) {
            // "The look on the iPhone": one column, the picture full width.
            CardImage(product: shown, size: .page).frame(maxWidth: .infinity)
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
            // The "Decks" block is card-level: the same on every printing's page (the kind from all the printings); only its
            // printing buttons and "Add to deck" use the printing on screen (A18).
            OwnedFinishes(gameID: game.id, productID: shown.productID, name: shown.name, offered: finishes.map(\.finish),
                          prices: finishes, wanted: (cardKey: cardKey, name: shown.cardName, printings: pinPrintings(printings, game: game),
                                                     owned: ownedCopies(printings, game: game),
                                                     isBasic: DeckMaths.isBasic(game: game, printings: [cardKey: printings])(cardKey)),
                          deckCard: DeckCardToAdd(cardKey: cardKey, name: shown.cardName,
                                                  kind: model.deckKind(game: game, printings: printings),
                                                  productID: shown.productID))
            // A39: the price history after the Decks block, before the rules text. One state per printing (`id`): the
            // finish picked on one printing is not carried to another.
            RuleLine()
            historyBlock(shown: shown, game: game, offered: finishes.map(\.finish))
                .id("\(game.id)|\(shown.productID)")
            if !shown.rulesText.isEmpty {
                RuleLine()
                // Selection is set on single texts only: on a container it takes the taps of the printing rows.
                Text(shown.rulesText)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-rules-text")
            }
            if printings.count > 1 {
                RuleLine()
                otherPrintings(printings, game: game)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The price history of the shown printing over the page's finish lines (the same lines as `OwnedFinishes`: the price
    /// table's finishes, then every owned or for-sale finish it does not list), with the copies owned per finish.
    private func historyBlock(shown: ProductRecord, game: GameDefinition, offered: [String]) -> some View {
        let library = model.library
        let rows = library.rows(game: game.id).filter { $0.productID == shown.productID }
        let sale = library.forSale(game: game.id).filter { $0.productID == shown.productID }
        let lines = CollectionRules.finishes(priced: offered, owned: rows.map(\.finish) + sale.map(\.finish))
        let owned = Dictionary(rows.map { ($0.finish, $0.count) }, uniquingKeysWith: +)
        return PriceHistoryView(gameID: game.id, productID: shown.productID, finishes: lines, owned: owned)
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

    /// The copies owned of the card over all its printings and finishes, for the decks' part of its Wanted line.
    private func ownedCopies(_ printings: [ProductRecord], game: GameDefinition) -> Int {
        let ids = Set(printings.map(\.productID))
        return CollectionRules.copies(model.library.rows(game: game.id).filter { ids.contains($0.productID) })
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
    /// The card of the page, for its Wanted line: its key, the name a new entry saves, each of its printings as the pin
    /// line names it (by product id), the copies owned over all its printings and whether it is a basic card (for the
    /// decks' part). Nil: no Wanted line (a printing that left the catalog).
    var wanted: (cardKey: String, name: String, printings: [Int: PinPrinting], owned: Int, isBasic: Bool)? = nil
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
            #if os(iOS)
            phoneFinishes(finishes, rows: rows, sale: sale, locked: locked != nil)
                .font(Theme.bodyFont)
                .disabled(locked != nil)
            #else
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
            #endif
            // The pin of "Want this printing": this product and its first finish line (the price table's first finish,
            // `Normal` when it has none). The page has no selected finish.
            if let wanted, let first = finishes.first {
                WantedLine(gameID: gameID, cardKey: wanted.cardKey, name: wanted.name,
                           pin: PrintingKey(productID: productID, finish: first), printings: wanted.printings,
                           owned: wanted.owned, isBasic: wanted.isBasic)
                    .padding(.top, 6)
            }
            // G7: the "Decks" block (its lines, the sharing line, "Add to deck") only with the player role.
            if let deckCard, GameSections.showsDecks(model.profile(of: gameID)) {
                DeckLines(gameID: gameID, card: deckCard, owned: wanted?.owned ?? 0, isBasic: wanted?.isBasic ?? false)
                    .padding(.top, 6)
            }
            if let locked { CountsLockedLine(text: locked) }
        }
    }

    #if os(iOS)
    /// The iPhone's finish lines ("The look on the iPhone"): each finish as two rows, its name and its price, then its
    /// Owned and For sale controls side by side. The column titles "Owned" and "For sale" stand once, above the first
    /// line's controls' columns. The name may wrap (two lines at most); the price keeps its width.
    private func phoneFinishes(_ finishes: [String], rows: [CollectionRow], sale: [SaleEntry], locked: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.columnGap, verticalSpacing: 6) {
            GridRow {
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
                    HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
                        finishName(finish)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let prices {
                            price(prices.first { $0.finish == finish }?.price.shown)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.top, 6)
                    // The two control columns decide the width; the name wraps inside it.
                    .gridCellUnsizedAxes(.horizontal)
                    .gridCellColumns(2)
                }
                GridRow {
                    CountControl(count: locked ? nil : count, label: finish) { step(by: $0 - count, finish: finish) }
                    CountControl(count: locked ? nil : forSale, label: "\(finish) for sale", maximum: count,
                                 prefix: "sale", key: finish) { stepForSale(by: $0 - forSale, finish: finish) }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    #endif

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
/// says why. The control is the hand-added count only (A24); right of it, when the active decks miss the card, "+ <n> for
/// decks" (`wanted-for-decks`, 12 pt `muted`; `WantedList.forDecks` from the library's decks and sharing answers and the
/// page's `owned` and `isBasic`), never on the page of a card without a printing (`hasPrinting` false, final fix A3).
struct WantedLine: View {
    let gameID: String
    let cardKey: String
    let name: String
    let pin: PrintingKey?
    /// Each printing of the card as the pin line names it, by product id.
    var printings: [Int: PinPrinting] = [:]
    /// The copies owned of the card over all its printings, and whether it is a basic card: for the decks' part.
    var owned: Int = 0
    var isBasic: Bool = false
    /// False on the page of a card without a printing (`UnknownCardPage`): no decks' part there (final fix A3).
    var hasPrinting: Bool = true

    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let locked = library.countsLocked(game: gameID) != nil
        let entry = library.wanted(game: gameID).first { $0.cardKey == cardKey }
        let count = entry?.count ?? 0
        // The pin choices need a count (an entry) and a game that can change.
        let pinned = locked || count == 0 ? nil : entry?.pin
        let offersPin = !locked && count > 0
        let forDecks = locked ? nil : Self.decksText(cardKey, decks: model.decksInPlay(game: gameID),
                                                     sharing: library.sharing(game: gameID), owned: owned, isBasic: isBasic,
                                                     hasPrinting: hasPrinting)
        let pinChoice: (title: String, key: PrintingKey?)? = if offersPin, let pin, pinned == nil || pinned == pin {
            (pinned == pin ? "Any printing" : "Want this printing", pinned == pin ? nil : pin)
        } else { nil }
        VStack(alignment: .leading, spacing: 6) {
            // One row when it fits the column; else (the decks' part takes the room) the pin button goes under it, whole.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    countRow(count: count, locked: locked, forDecks: forDecks)
                    if let pinChoice { pinButton(pinChoice.title, to: pinChoice.key, identifier: "wanted-pin").fixedSize() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) { countRow(count: count, locked: locked, forDecks: forDecks) }
                    if let pinChoice { pinButton(pinChoice.title, to: pinChoice.key, identifier: "wanted-pin").fixedSize() }
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

    /// "Wanted", the hand-added count's control and, when the decks miss the card, "+ <n> for decks".
    @ViewBuilder private func countRow(count: Int, locked: Bool, forDecks: String?) -> some View {
        Text("Wanted")
            .foregroundStyle(Theme.text)
        CountControl(count: locked ? nil : count, label: "wanted", prefix: "wanted", key: "",
                     spoken: (remove: "Want one fewer", add: "Want one more")) { step(by: $0 - count) }
        if let decks = forDecks {
            Text(decks)
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("wanted-for-decks")
        }
    }

    /// "+ 2 for decks" beside the control; nil when the decks miss none.
    static func forDecksText(_ forDecks: Int) -> String? {
        forDecks > 0 ? "+ \(forDecks) for decks" : nil
    }

    /// The decks' part beside the control (`forDecksText` of `WantedList.forDecks`). Final fix A3: a card without a printing
    /// (`UnknownCardPage`) has none, whatever the decks use: its owned copies cannot be known.
    static func decksText(_ cardKey: String, decks: [Deck], sharing: [String: Bool], owned: Int, isBasic: Bool,
                          hasPrinting: Bool) -> String? {
        guard hasPrinting else { return nil }
        return forDecksText(WantedList.forDecks(cardKey, decks: decks, sharing: sharing, owned: owned, isBasic: isBasic))
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
/// card is added to the new deck). With no deck in the game, the heading and the menu. Card-level: the same on every printing's page,
/// except for the printing (A18): "Add to deck" and the new deck save the page's printing on a line new in its section, and
/// right of each line's count control one button (`deck-line-printing-<deckID>-<section>`) says "Use this printing" (stores
/// the page's printing on the line) or, when the line's stored printing is the page's, "Any printing" (clears it). Each
/// line is two rows (fix round 1): the deck's name and the section's name, then the count control and the button.
/// Under the lines, above "Add to deck", the sharing line (E7, `DeckPage.sharingLine`) when 2 or more active decks use the
/// card: pending, "Decision pending" (`card-sharing`, `muted`) with "Share" (`card-sharing-share`, writes true) and "Buy
/// more" (`card-sharing-buy`, false); answered, "Shared between decks" / "Bought for each deck" with "Change"
/// (`card-sharing-change`, the other answer).
/// While the game cannot change: no numbers (`—`), everything off; the page's locked line says why.
struct DeckLines: View {
    let gameID: String
    let card: DeckCardToAdd
    /// The copies owned of the card over all its printings, and whether it is a basic card: for the sharing line.
    var owned: Int = 0
    var isBasic: Bool = false

    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let locked = library.countsLocked(game: gameID) != nil
        let game = Games.game(gameID) ?? Games.all[0]
        let decks = model.decksInPlay(game: gameID)
        let lines = DeckPage.cardLines(decks: decks, cardKey: card.cardKey, game: game)
        VStack(alignment: .leading, spacing: 6) {
            Text("Decks")
                .foregroundStyle(Theme.text)
            if !lines.isEmpty {
                // Fix round 1: two rows per line, so the deck's name has the whole column: the name and the section's
                // name, then (`Theme.lineGap` under them) the count control and the printing button.
                VStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: Theme.lineGap) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(line.deckName)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .accessibilityIdentifier("deck-line-name-\(line.id)")
                                Text(line.sectionName)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            HStack(spacing: 10) {
                                CountControl(count: locked ? nil : line.count, label: "\(line.deckName), \(line.sectionName)",
                                             maximum: DeckRules.maxCount, prefix: "deck-line", key: line.id) {
                                    step(by: $0 - line.count, line: line)
                                }
                                if let page = card.productID {
                                    printingButton(line, page: page)
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("deck-line-\(line.id)")
                    }
                }
            }
            let need = WantedList.need(card.cardKey, decks: decks, sharing: library.sharing(game: gameID), owned: owned,
                                       isBasic: isBasic)
            if let sharing = DeckPage.sharingLine(need) {
                sharingLine(sharing)
            }
            addMenu(decks, game: game)
        }
        .font(Theme.bodyFont)
        .disabled(locked)
    }

    /// One row when it fits the column, else the buttons under the text.
    private func sharingLine(_ line: SharingLine) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sharingText(line)
                sharingButtons(line)
            }
            VStack(alignment: .leading, spacing: 6) {
                sharingText(line)
                HStack(spacing: 8) { sharingButtons(line) }
            }
        }
    }

    private func sharingText(_ line: SharingLine) -> some View {
        Text(line.text)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("card-sharing")
    }

    /// The answer a click writes is the one the button said at render ("Change": the other one of the answer shown).
    @ViewBuilder private func sharingButtons(_ line: SharingLine) -> some View {
        switch line {
        case .pending:
            sharingButton("Share", shared: true, identifier: "card-sharing-share")
            sharingButton("Buy more", shared: false, identifier: "card-sharing-buy")
        case .shared, .each:
            sharingButton("Change", shared: line == .each, identifier: "card-sharing-change")
        }
    }

    private func sharingButton(_ title: String, shared: Bool, identifier: String) -> some View {
        Button(title) { model.library.setShared([card.cardKey: shared], game: gameID) }
            .buttonStyle(FieldButtonStyle())
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }

    private func addMenu(_ decks: [Deck], game: GameDefinition) -> some View {
        Menu("Add to deck") {
            // A78: each deck is a submenu of its format's sections; a click adds one copy to that section.
            ForEach(decks) { deck in
                Menu(deck.name) {
                    ForEach(game.format(deck.format).sections) { section in
                        Button(section.name) {
                            model.library.changeDeck(game: gameID, id: deck.id) {
                                DeckRules.addingOne($0, cardKey: card.cardKey, name: card.name, section: section.id,
                                                    productID: card.productID)
                            }
                        }
                        .accessibilityIdentifier("card-add-to-deck-\(deck.id)-\(section.id)")
                    }
                }
                .accessibilityIdentifier("card-add-to-deck-\(deck.id)")
            }
            if !decks.isEmpty { Divider() }
            Button("New Deck…") { model.openNewDeck(game: gameID, card: card) }
            .accessibilityIdentifier("card-add-to-deck-new")
        }
        .fixedSize()
        .accessibilityIdentifier("card-add-to-deck")
    }

    /// A18: "Any printing" when the line is stored on the page's printing (clears it, also a value this build cannot read),
    /// else "Use this printing" (stores it). It keeps its width.
    private func printingButton(_ line: DeckCardLine, page: Int) -> some View {
        let choice = DeckPage.printingChoice(stored: line.productID, page: page)
        let key = DeckCardKey(cardKey: card.cardKey, section: line.section)
        return Button(choice.title) {
            // What the button said at render, and only while the line still holds what it saw then (fix round 2).
            let library = model.library
            let current = library.deck(game: gameID, id: line.deckID)?.cards.first { $0.key == key }?.productID
            guard let target = DeckPage.printingToApply(choice, current: current) else { return }
            library.setDeckPrinting(target, game: gameID, deck: line.deckID, key: key)
        }
        .buttonStyle(FieldButtonStyle())
        .fixedSize()
        .accessibilityIdentifier("deck-line-printing-\(line.id)")
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
