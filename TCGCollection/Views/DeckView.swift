import SwiftUI

// The deck page (D8, D9): a gallery per section of the deck's format, with its count, its warning and its groups; a
// `CountControl` under every cell. And the pure decisions of the page and of the sidebar's Decks section (`DeckPage`).

/// What a join of deck cards with the catalog read (`DeckJoin`): for the deck page, the cards of one deck; for the sidebar,
/// the cards of every active deck of the game.
nonisolated struct DeckRead: Sendable, Equatable {
    /// Each card key's printings, newest set first; a key the catalog has no product of the game for is not in it.
    var printings: [String: [ProductRecord]]
    /// The card keys the join looked up.
    var keys: Set<String>
    /// The copies owned of each card of `printings` when the join ran (`WantedList.ownedByCard`).
    var ownedByCard: [String: Int]
    /// Each card's kind (D4), from its first printing with a card type (Yu-Gi-Oh!: the YGOPRODeck type first, A15).
    var kinds: [String: CardKind]
    /// The keys of the basic cards (`DeckMaths.isBasic`): never missing, no copy limit.
    var basics: Set<String>
}

/// What the deck page shows.
nonisolated enum DeckPhase: Equatable, Sendable {
    /// The folder is still read, or the first join of the deck runs.
    case loading
    /// Nothing can be shown or changed (the folder is missing, the game's file is refused): the problem line says why.
    case unavailable
    /// The deck has no cards.
    case empty
    case list
    /// The read folder has no deck of this id (removed here or on another device, Review Focus 4).
    case gone
}

/// What the deck page lists, given the state of the catalog (`DeckPage.content`), as `WantedContent` is for Wanted.
nonisolated struct DeckContent: Equatable {
    /// Every section of the format in its order (then any the format lacks), with its groups and lines.
    let sections: [DeckSectionView]
    /// True when the game's catalog is settled: only then is a card without a printing "not in the catalog" (D13).
    let settled: Bool
    /// One muted line above the sections that says what the catalog cannot give; nil when it gives everything.
    let note: String?
    /// Card keys the join that made `sections` did not look up (a card added since): pending until the next join.
    let uncovered: Set<String>
}

/// The deck page's and the sidebar's decisions. Pure.
nonisolated enum DeckPage {
    /// The read of a join: `printings` as the store gave them for `keys`, the kinds (`ygoType` gives the YGOPRODeck type of
    /// a card name; the caller gives one only for Yu-Gi-Oh!), the basic cards and the copies owned per card over `rows`.
    static func read(game: GameDefinition, printings: [String: [ProductRecord]], keys: Set<String>, rows: [CollectionRow],
                     ygoType: (String) -> String?) -> DeckRead {
        let kinds = printings.compactMapValues { list -> CardKind? in
            guard let first = list.first(where: { !$0.cardType.isEmpty }) ?? list.first else { return nil }
            return game.kind(cardType: first.cardType, ygoType: ygoType(first.cardName))
        }
        let isBasic = DeckMaths.isBasic(game: game, printings: printings)
        return DeckRead(printings: printings, keys: keys, ownedByCard: WantedList.ownedByCard(rows: rows, printings: printings),
                        kinds: kinds, basics: Set(printings.keys.filter(isBasic)))
    }

    /// The deck's sections on the last join (`read`), with the Collection's catalog states (`WantedList.content`):
    /// - `joinFailed`: the latest join threw; what `read` holds is kept (its missing cards pending), else the cards alone.
    /// - `catalogHasProducts`: without products the cards are listed alone (saved names, no picture, no price).
    /// - `catalogSettled`: only on a settled catalog is a card without a printing "not in the catalog" (D13); otherwise
    ///   it is pending, with the downloading line.
    /// A card without a printing has no picture, no price and no missing copies either way, and its count still works.
    static func content(_ deck: Deck, game: GameDefinition, read: DeckRead?, joinFailed: Bool, catalogHasProducts: Bool,
                        catalogSettled: Bool, price: ([ProductRecord]) -> ShownPrice?) -> DeckContent {
        let keys = Set(deck.cards.map(\.cardKey))
        func listed(_ read: DeckRead?, settled: Bool, note: String?) -> DeckContent {
            let basics = read?.basics ?? [], kinds = read?.kinds ?? [:]
            let sections = DeckMaths.sections(deck, format: game.format(deck.format), game: game,
                                              printings: read?.printings ?? [:], ownedByCard: read?.ownedByCard ?? [:],
                                              isBasic: { basics.contains($0) }, kindOf: { kinds[$0] }, price: price)
            return DeckContent(sections: sections, settled: settled, note: note, uncovered: keys.subtracting(read?.keys ?? []))
        }
        if joinFailed {
            return read == nil ? listed(nil, settled: false, note: CollectionList.catalogUnreadable)
                : listed(read, settled: false, note: CollectionList.catalogUnreadableKept)
        }
        guard catalogHasProducts, let read else {
            return listed(nil, settled: false, note: catalogSettled ? CollectionList.catalogEmpty : CollectionList.catalogDownloading)
        }
        let pending = !catalogSettled && deck.cards.contains { (read.printings[$0.cardKey] ?? []).isEmpty }
        return listed(read, settled: catalogSettled, note: pending ? CollectionList.catalogDownloading : nil)
    }

    /// `deck`: the game's deck of the page's id (nil when the read folder has none). `canChange`: `UserLibrary.canChange`,
    /// false before the folder is read; `problem`: the game's problem, which makes that false for good.
    static func phase(deck: Deck?, listed: DeckContent?, canChange: Bool, problem: String?) -> DeckPhase {
        guard canChange else { return problem == nil ? .loading : .unavailable }
        guard let deck else { return .gone }
        if deck.cards.isEmpty { return .empty }
        return listed == nil ? .loading : .list
    }

    /// D8: `×3`, or `×3 · 2 missing`; a basic card never says "missing".
    static func countText(_ line: DeckLine) -> String {
        line.missing > 0 && !line.isBasic ? "×\(line.card.count) · \(line.missing) missing" : "×\(line.card.count)"
    }

    /// What VoiceOver and the UI tests read for a cell: name, the count text and the price.
    static func accessibilityText(_ line: DeckLine) -> String {
        [line.name, countText(line), line.price.map { CardFacts.priceText($0) } ?? "no price"].joined(separator: ", ")
    }

    /// A section's warning, only on a deck with at least one card: an empty deck shows its empty message, not every bound
    /// it does not meet yet.
    static func warning(_ section: DeckSectionView, deckHasCards: Bool) -> String? {
        deckHasCards ? section.warning : nil
    }

    /// The lines whose card key (the folded card name), or for a card without a printing whose folded saved name, holds
    /// every folded word of `text` (the catalog search's rule); groups and sections without such a line are left out. All
    /// of `sections` for a text without a word.
    static func filtered(_ sections: [DeckSectionView], text: String) -> [DeckSectionView] {
        let words = CardName.searchKey(text).split(separator: " ")
        guard !words.isEmpty else { return sections }
        return sections.compactMap { section in
            let groups = section.groups.compactMap { group -> DeckGroup? in
                let lines = group.lines.filter { line in
                    let key = line.shown?.searchKey ?? CardName.searchKey(line.name)
                    return words.allSatisfy { key.contains($0) }
                }
                return lines.isEmpty ? nil : DeckGroup(name: group.name, lines: lines)
            }
            return groups.isEmpty ? nil : DeckSectionView(section: section.section, count: section.count, groups: groups,
                                                         warning: section.warning)
        }
    }

    /// D12: the deck in `format`; a card whose section the format lacks goes to its kind's default section there, a card
    /// of unknown kind to the format's first counted section that is not by hand only. No card is lost.
    static func changingFormat(_ deck: Deck, to format: DeckFormat, game: GameDefinition, kinds: [String: CardKind]) -> Deck {
        DeckRules.changingFormat(deck, to: format) { card in
            game.defaultSection(format: format, kind: kinds[card.cardKey] ?? CardKind(group: CardKind.other, flags: []))
        }
    }

    /// The sidebar row's count (A14, D7): the deck's missing copies (`DeckMaths.missingCopies`) for an active deck that
    /// misses any; nil for a deck that is not active, misses nothing, or while the read is not there.
    static func sidebarCount(_ deck: Deck, read: DeckRead?) -> String? {
        guard deck.active, let read else { return nil }
        let missing = DeckMaths.missingCopies(deck, printings: read.printings, ownedByCard: read.ownedByCard,
                                              isBasic: { read.basics.contains($0) })
        return missing > 0 ? "\(missing)" : nil
    }

    /// The muted line under the sidebar's decks for decks of the game's file this build cannot read.
    static func unreadableText(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 deck cannot be read."
        default: "\(count) decks cannot be read."
        }
    }
}

/// Deck cards joined with the catalog (`CatalogJoin`). The deck page joins its deck's cards; the sidebar joins the cards
/// of every active deck of the game, once for all its rows. The live deck is laid on the read on every render.
typealias DeckJoin = CatalogJoin<DeckRead>

extension CatalogJoin where Read == DeckRead {
    /// The last read when it was made for `game`; else nil (the sidebar keeps one join across game switches).
    func read(game: String) -> DeckRead? { joined?.game == game ? read : nil }

    /// What the deck page lists (`DeckPage.content`); nil until a join of this game has ended. The catalog counts as
    /// settled as it was for the join that made `read`.
    func content(_ deck: Deck, game: GameDefinition, price: ([ProductRecord]) -> ShownPrice?) -> DeckContent? {
        guard let joined, joined.game == game.id else { return nil }
        return DeckPage.content(deck, game: game, read: read, joinFailed: failed, catalogHasProducts: catalogHasProducts,
                                catalogSettled: joined.catalogSettled, price: price)
    }

    /// Reads the printings of `cardKeys` (one store call), counts the copies owned of each card, and works out each card's
    /// kind once per join (`run`; the key changes with every change of the collection and of the decks).
    func run(_ key: CollectionJoin, cardKeys: Set<String>, model: AppModel) async {
        guard let game = Games.game(key.game) else { return }
        let rows = model.library.rows(game: key.game)
        await run(key, loaded: model.library.isLoaded, reader: model.reader) { reader, gameID in
            let printings = try await reader.printings(game: gameID, cardKeys: Array(cardKeys))
            // Task 2: only Yu-Gi-Oh! has YGOPRODeck types; the lookup is the model's, made here on the main actor.
            var types: [String: String] = [:]
            if game.pictures == .ygoprodeck {
                for name in Set(printings.values.flatMap { $0.map(\.cardName) }) { types[name] = model.ygoType(cardName: name) }
            }
            let found = types
            return DeckPage.read(game: game, printings: printings, keys: cardKeys, rows: rows, ygoType: { found[$0] })
        }
    }
}

/// What a deck page shows for one deck: the search text, the open pages, the last join with the catalog, and its sheets.
/// The window keeps it (`DeckMemory`), so a visit to another screen loses none of it.
@Observable
final class DeckScreenState {
    let gameID: String
    let deckID: String
    var text = ""
    var path = NavigationPath()
    let join = DeckJoin()
    /// "Rename…" is open.
    var renaming = false
    /// "Delete Deck…" asks.
    var confirmsDelete = false

    init(gameID: String, deckID: String) {
        self.gameID = gameID
        self.deckID = deckID
    }
}

/// The window's deck pages: one state per deck of the window's game. A game switch drops them all (`keep(game:)`), as
/// `ScreenMemory` does for the lists. Not observed.
final class DeckMemory {
    private var gameID: String?
    private var states: [String: DeckScreenState] = [:]

    func state(game: String, deck: String) -> DeckScreenState {
        keep(game: game)
        gameID = game
        if let state = states[deck] { return state }
        let fresh = DeckScreenState(gameID: game, deckID: deck)
        states[deck] = fresh
        return fresh
    }

    /// The window's game is now `game`: the states of another game are dropped.
    func keep(game: String) {
        if gameID != nil, gameID != game {
            states = [:]
            gameID = nil
        }
    }
}

/// One deck of the selected game (D8): the totals as the window's subtitle, the "Deck" menu and one search field; then per
/// section its title, count and warning, and per group a small heading and `CardCell`s, each with a `CountControl` under
/// it. A click on a cell's picture or name opens the card page on the card's cheapest printing, in this deck's own
/// navigation stack. A cell's context menu moves the card to another section of the format (D9). Warnings never block a
/// change (spec 5.3).
struct DeckView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DeckScreenState

    var body: some View {
        let library = model.library, gameID = state.gameID
        let game = Games.game(gameID) ?? Games.all[0]
        let deck = library.deck(game: gameID, id: state.deckID)
        let prices = model.prices
        let listed = deck.flatMap { state.join.content($0, game: game) { prices.cheapest(game: gameID, productIDs: $0.map(\.productID)) } }
        let phase = DeckPage.phase(deck: deck, listed: listed, canChange: library.canChange(game: gameID),
                                   problem: library.problem(game: gameID))
        let join = DeckJoin.key(game: gameID, model: model)
        let keys = Set(deck?.cards.map(\.cardKey) ?? [])
        content(phase, deck: deck, listed: listed, game: game)
            .listScreen("deck", note: phase == .list ? listed?.note : nil)
            .navigationTitle(deck?.name ?? "Deck")
            .navigationSubtitle(subtitle(phase, listed: listed))
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItem { deckMenu(deck, game: game, kinds: state.join.read?.kinds ?? [:]) }
            }
            .task(id: join) {
                if deck != nil { await state.join.run(join, cardKeys: keys, model: model) }
            }
            .sheet(isPresented: $state.renaming) {
                RenameDeckSheet(gameID: gameID, deckID: state.deckID, name: deck?.name ?? "")
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("Delete \(deck?.name ?? "this deck")?", isPresented: $state.confirmsDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    // The Collection first, so the page of the removed deck is never on show.
                    model.showRoot(of: .collection)
                    library.removeDeck(game: gameID, id: state.deckID)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its cards stay in your collection.")
            }
    }

    private func subtitle(_ phase: DeckPhase, listed: DeckContent?) -> String {
        switch phase {
        case .list: listed.map { DeckMaths.totals($0.sections) } ?? ""
        case .empty: "0 cards"
        default: ""
        }
    }

    @ViewBuilder
    private func content(_ phase: DeckPhase, deck: Deck?, listed: DeckContent?, game: GameDefinition) -> some View {
        switch phase {
        case .loading:
            LoadingGallery()
        case .unavailable:
            Color.clear
        case .gone:
            EmptyMessage(sentence: "This deck was removed.", identifier: "deck-gone") {
                Button("Open the collection") { model.showRoot(of: .collection) }
                    .accessibilityIdentifier("deck-open-collection")
            }
        case .empty:
            EmptyMessage(sentence: "This deck has no cards yet.")
        case .list:
            if let deck, let listed {
                let shown = DeckPage.filtered(listed.sections, text: state.text)
                if shown.isEmpty {
                    EmptyMessage(sentence: "No card matches \"\(state.text)\".")
                } else {
                    sections(shown, deck: deck, format: game.format(deck.format))
                }
            }
        }
    }

    private func sections(_ sections: [DeckSectionView], deck: Deck, format: DeckFormat) -> some View {
        let canChange = model.library.canChange(game: state.gameID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { RuleLine() }
                    DeckSectionBlock(section: section, warning: DeckPage.warning(section, deckHasCards: !deck.cards.isEmpty)) { line in
                        cell(line, format: format, canChange: canChange)
                    }
                }
            }
            .padding(Theme.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("deck-gallery")
    }

    /// D8: the cell, 8 pt, then one line with the card's count in its section (`−` at 1 takes the card out of the
    /// section). The control is off while the game cannot change. The context menu moves the card (D9).
    private func cell(_ line: DeckLine, format: DeckFormat, canChange: Bool) -> some View {
        let card = line.card, suffix = "\(card.cardKey)-\(card.section)"
        return VStack(alignment: .leading, spacing: 8) {
            DeckCell(gameID: state.gameID, line: line)
                .accessibilityIdentifier("deck-cell-\(suffix)")
            HStack(spacing: 8) {
                // `+` is off at 999 or more (the clamp never lowers a count; `−` always works).
                CountControl(count: card.count, label: "\(line.name), \(format.section(card.section)?.name ?? card.section)",
                             maximum: DeckRules.maxCount, prefix: "deck-cell", key: suffix) { step(by: $0 - card.count, card: card) }
                Spacer(minLength: 0)
            }
            .disabled(!canChange)
        }
        .contextMenu {
            Menu("Move to") {
                ForEach(format.sections.filter { $0.id != card.section }) { section in
                    Button(section.name) {
                        model.library.changeDeck(game: state.gameID, id: state.deckID) {
                            DeckRules.moving($0, cardKey: card.cardKey, from: card.section, to: section.id)
                        }
                    }
                }
            }
            .disabled(!canChange)
        }
    }

    /// As on Wanted: the step goes onto the deck's current count of the card in that section, so two clicks before the
    /// next render both count; 0 takes the card out of the section.
    private func step(by delta: Int, card: DeckCard) {
        model.library.changeDeck(game: state.gameID, id: state.deckID) { deck in
            let now = deck.cards.first { $0.id == card.id }?.count ?? 0
            return DeckRules.setting(deck, count: now + delta, cardKey: card.cardKey, name: card.name, section: card.section)
        }
    }

    /// "Deck": Rename…, Format ▸ (a game with more than one format), Active (a toggle), Delete Deck…. Off while the deck is
    /// gone or the game cannot change.
    private func deckMenu(_ deck: Deck?, game: GameDefinition, kinds: [String: CardKind]) -> some View {
        let library = model.library, gameID = state.gameID, deckID = state.deckID
        return Menu {
            Button("Rename…") { state.renaming = true }
                .accessibilityIdentifier("deck-rename")
            if game.formats.count > 1 {
                Menu("Format") {
                    ForEach(game.formats) { format in
                        Toggle(format.name, isOn: Binding(get: { deck?.format == format.id }, set: { on in
                            guard on else { return }
                            library.changeDeck(game: gameID, id: deckID) {
                                DeckPage.changingFormat($0, to: format, game: game, kinds: kinds)
                            }
                        }))
                        .accessibilityIdentifier("deck-format-\(format.id)")
                    }
                }
                .accessibilityIdentifier("deck-format")
            }
            Toggle("Active", isOn: Binding(get: { deck?.active ?? false }, set: { on in
                library.changeDeck(game: gameID, id: deckID) { deck in
                    var deck = deck
                    deck.active = on
                    return deck
                }
            }))
            .accessibilityIdentifier("deck-active")
            Divider()
            Button("Delete Deck…") { state.confirmsDelete = true }
                .accessibilityIdentifier("deck-delete")
        } label: {
            Text("Deck")
        }
        .disabled(deck == nil || !library.canChange(game: gameID))
        .accessibilityIdentifier("deck-menu")
    }
}

/// One section of the deck page: its name (15 pt semibold) and `· <count>` in `muted`, its warning right of it in `muted`
/// (a warning is not a risk), then per group a 12 pt `muted` heading and the group's cells; "No cards" for an empty one.
private struct DeckSectionBlock<Cell: View>: View {
    let section: DeckSectionView
    let warning: String?
    @ViewBuilder let cell: (DeckLine) -> Cell

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(Text(section.section.name).foregroundStyle(Theme.text))\(Text(" · \(section.count)").foregroundStyle(Theme.muted))")
                    .font(Theme.deckSectionFont)
                    .monospacedDigit()
                    .accessibilityIdentifier("deck-section-\(section.id)")
                if let warning {
                    Text(warning)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("deck-warning-\(section.id)")
                }
            }
            if section.groups.isEmpty {
                Text("No cards")
                    .font(Theme.lineFont)
                    .foregroundStyle(Theme.muted)
            }
            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(Theme.lineFont)
                        .foregroundStyle(Theme.muted)
                    GalleryGrid(padded: false) {
                        ForEach(group.lines) { line in cell(line) }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

/// A deck cell (`CardCell`): the card's name, `×n` or `×n · 2 missing` and the card's cheapest price, on its cheapest
/// printing's picture. A card with a printing opens its card page on that printing; a card without one (pending, or not in
/// the catalog, D13) opens nothing and takes no hover. The caller gives it its identifier.
private struct DeckCell: View {
    let gameID: String
    let line: DeckLine

    var body: some View {
        let cell = CardCell(content: CellContent(product: line.shown, name: line.name, left: DeckPage.countText(line),
                                                 price: line.price))
        if let shown = line.shown {
            NavigationLink(value: CardTarget(gameID: gameID, cardKey: line.card.cardKey, startProductID: shown.productID)) { cell }
                .buttonStyle(.plain)
                .accessibilityLabel(DeckPage.accessibilityText(line))
        } else {
            cell
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DeckPage.accessibilityText(line))
        }
    }
}
