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
    /// The copies owned of each printing of `printings` (product id → copies over its finishes), for the shown printing
    /// (A18, `DeckMaths.shownPrinting`).
    var ownedByPrinting: [Int: Int] = [:]
}

/// One line of a card page's "Decks" (`DeckPage.cardLines`): a deck that holds the card, one of its sections, the copies
/// there.
nonisolated struct DeckCardLine: Equatable, Sendable, Identifiable {
    let deckID: String
    let deckName: String
    let section: String
    /// The format's name of the section; its id for a section the format lacks.
    let sectionName: String
    let count: Int
    /// The line's chosen printing (A18), nil when none is stored.
    var productID: Int? = nil

    /// `<deckID>-<section>`, the suffix of the line's identifiers.
    var id: String { "\(deckID)-\(section)" }
}

/// A card that a deck's search or a card page adds to a deck: its key, the name a new deck card saves (the card's name, the
/// page title form, as Wanted saves it), its kind (`CardKinds.deckKind`; nil without a printing) and, from a card page only,
/// the printing on screen (A18: saved on a line that is new in its section; nil from a deck's search).
nonisolated struct DeckCardToAdd: Equatable, Sendable {
    let cardKey: String
    let name: String
    let kind: CardKind?
    var productID: Int? = nil
}

/// A card page's deck line button as rendered (`DeckPage.printingChoice`): its title, the line's stored printing it saw,
/// and the printing a click sets (nil: clear).
nonisolated struct PrintingChoice: Equatable, Sendable {
    let title: String
    let rendered: Int?
    let target: Int?
}

/// What a deck's navigation stack pushes for "Add cards": the catalog search with that deck as its target.
nonisolated struct DeckSearch: Hashable, Sendable {
    let deckID: String
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

/// The card page's sharing line (E7, `DeckPage.sharingLine`): pending ("Share" / "Buy more"), or the stored answer with
/// "Change".
nonisolated enum SharingLine: Equatable, Sendable {
    /// In conflict without an answer.
    case pending
    /// The answer "Share" (true).
    case shared
    /// The answer "Buy more" (false).
    case each

    var text: String {
        switch self {
        case .pending: "Decision pending"
        case .shared: "Shared between decks"
        case .each: "Bought for each deck"
        }
    }
}

/// What the deck page lists, given the state of the catalog (`DeckPage.content`), as `WantedContent` is for Wanted.
nonisolated struct DeckContent: Equatable {
    /// Every section of the format in its order (then any the format lacks), with its groups and lines.
    let sections: [DeckSectionView]
    /// One muted line above the sections that says what the catalog cannot give; nil when it gives everything.
    let note: String?
}

/// The deck page's and the sidebar's decisions. Pure.
nonisolated enum DeckPage {
    /// The read of a join: `printings` as the store gave them for `keys`, the kinds (`ygoType` gives the YGOPRODeck type of
    /// a card name; the caller gives one only for Yu-Gi-Oh!), the basic cards and the copies owned per card over `rows`.
    static func read(game: GameDefinition, printings: [String: [ProductRecord]], keys: Set<String>, rows: [CollectionRow],
                     ygoType: (String) -> String?) -> DeckRead {
        let kinds = printings.compactMapValues { CardKinds.deckKind(game: game, printings: $0, ygoType: ygoType) }
        let isBasic = DeckMaths.isBasic(game: game, printings: printings)
        let products = Set(printings.values.flatMap { $0.map(\.productID) })
        let ownedByPrinting = rows.filter { products.contains($0.productID) }
            .reduce(into: [Int: Int]()) { $0[$1.productID, default: 0] += $1.count }
        return DeckRead(printings: printings, keys: keys, ownedByCard: WantedList.ownedByCard(rows: rows, printings: printings),
                        kinds: kinds, basics: Set(printings.keys.filter(isBasic)), ownedByPrinting: ownedByPrinting)
    }

    /// The section a card is added to (D9, D10: `+` of a deck's search, "Add to deck" on a card page): its kind's default
    /// section in `format`; a card of unknown kind goes where an `Other` card goes.
    static func addSection(game: GameDefinition, format: DeckFormat, kind: CardKind?) -> String {
        game.defaultSection(format: format, kind: kind ?? CardKind(group: CardKind.other, flags: []))
    }

    /// One copy more of `card` in its default section of the deck's format (`addSection`); a card page's printing is saved
    /// on a line new in that section (A18, `DeckRules.addingOne`).
    static func addingOne(_ deck: Deck, _ card: DeckCardToAdd, game: GameDefinition) -> Deck {
        DeckRules.addingOne(deck, cardKey: card.cardKey, name: card.name,
                            section: addSection(game: game, format: game.format(deck.format), kind: card.kind),
                            productID: card.productID)
    }

    /// The cards of a deck made by a card page's "New Deck…": the card's one copy in its default section of `format`, on
    /// the page's printing (A18), so the deck and the card are one library change (`UserLibrary.addDeck(…cards:)`).
    static func newDeckCards(_ card: DeckCardToAdd, format: String, game: GameDefinition) -> [DeckCard] {
        [DeckCard(cardKey: card.cardKey, name: card.name,
                  section: addSection(game: game, format: game.format(format), kind: card.kind), count: 1,
                  productID: card.productID)]
    }

    /// One copy less of `card` over the deck: its default section first, then the format's order (`DeckRules.takingOne`).
    static func takingOne(_ deck: Deck, _ card: DeckCardToAdd, game: GameDefinition) -> Deck {
        let format = game.format(deck.format)
        return DeckRules.takingOne(deck, cardKey: card.cardKey, defaultSection: addSection(game: game, format: format, kind: card.kind),
                                   order: format.sections.map(\.id))
    }

    /// A deck search cell's count control: the deck's copies of the card over all sections, and the count at which `+` is
    /// off (`CountControl.maximum`): when the card's default section holds 999 or more, whatever the others hold.
    static func searchCount(_ deck: Deck, _ card: DeckCardToAdd, game: GameDefinition) -> (copies: Int, plusLimit: Int) {
        let section = addSection(game: game, format: game.format(deck.format), kind: card.kind)
        let copies = DeckRules.copies(deck, cardKey: card.cardKey)
        let inSection = deck.cards.first { $0.cardKey == card.cardKey && $0.section == section }?.count ?? 0
        return (copies, copies - inSection + DeckRules.maxCount)
    }

    /// A18: what a card page's deck line button says and does, decided at render: "Any printing" (clear) when the line's
    /// stored printing is the page's, else "Use this printing" (store the page's), with the stored value it saw.
    static func printingChoice(stored: Int?, page: Int) -> PrintingChoice {
        stored == page ? PrintingChoice(title: "Any printing", rendered: stored, target: nil)
            : PrintingChoice(title: "Use this printing", rendered: stored, target: page)
    }

    /// The printing a click of `choice` sets (`.some(nil)`: clear), or nil (nothing) when the line's stored printing is
    /// no longer what the button saw at render (fix round 2: a double click across a re-render does nothing the second
    /// time).
    static func printingToApply(_ choice: PrintingChoice, current: Int?) -> Int?? {
        current == choice.rendered ? .some(choice.target) : nil
    }

    /// The card page's "Decks" lines: one per (deck, section) that holds the card, in deck order, then in the order of the
    /// deck's format (a section the format lacks after them, by its id, in the deck's order).
    static func cardLines(decks: [Deck], cardKey: String, game: GameDefinition) -> [DeckCardLine] {
        decks.flatMap { deck -> [DeckCardLine] in
            let format = game.format(deck.format)
            let order = Dictionary(format.sections.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            let held = deck.cards.enumerated().filter { $0.element.cardKey == cardKey }
            let sorted = held.sorted { (order[$0.element.section] ?? Int.max, $0.offset) < (order[$1.element.section] ?? Int.max, $1.offset) }
            return sorted.map { _, card in
                DeckCardLine(deckID: deck.id, deckName: deck.name, section: card.section,
                             sectionName: format.section(card.section)?.name ?? card.section, count: card.count,
                             productID: card.productID)
            }
        }
    }

    /// The deck's sections on the last join (`read`), with the Collection's catalog states (`WantedList.content`):
    /// - `joinFailed`: the latest join threw; what `read` holds is kept (its missing cards pending), else the cards alone.
    /// - `catalogHasProducts`: without products the cards are listed alone (saved names, no picture, no price).
    /// - `catalogSettled`: only on a settled catalog is a card without a printing "not in the catalog" (D13); otherwise
    ///   it is pending, with the downloading line.
    /// A card without a printing has no picture, no price and no missing copies either way, and its count still works.
    /// `available`: the copies of each card the deck may count as owned (E4, `available(to:needs:read:)`); the lines of a
    /// card take them in section order. The shown printing (A18) still follows the real copies owned per printing.
    static func content(_ deck: Deck, game: GameDefinition, read: DeckRead?, available: [String: Int], joinFailed: Bool,
                        catalogHasProducts: Bool, catalogSettled: Bool,
                        price: ([ProductRecord]) -> ShownPrice?) -> DeckContent {
        let keys = Set(deck.cards.map(\.cardKey))
        // A card the join did not read (added since) has no printings in `read`: it shows as pending (no picture, no
        // "missing") until the next join reads it.
        func listed(_ read: DeckRead?, note: String?) -> DeckContent {
            let basics = read?.basics ?? [], kinds = read?.kinds ?? [:]
            let sections = DeckMaths.sections(deck, format: game.format(deck.format), game: game,
                                              printings: read?.printings ?? [:], ownedByCard: available,
                                              ownedByPrinting: read?.ownedByPrinting ?? [:], isBasic: { basics.contains($0) }, kindOf: { kinds[$0] }, price: price)
            return DeckContent(sections: sections, note: note)
        }
        if joinFailed {
            return read == nil ? listed(nil, note: CollectionList.catalogUnreadable)
                : listed(read, note: CollectionList.catalogUnreadableKept)
        }
        guard catalogHasProducts, let read else {
            return listed(nil, note: catalogSettled ? CollectionList.catalogEmpty : CollectionList.catalogDownloading)
        }
        let pending = !catalogSettled && deck.cards.contains { (read.printings[$0.cardKey] ?? []).isEmpty }
        return listed(read, note: pending ? CollectionList.catalogDownloading : nil)
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

    /// What VoiceOver and the UI tests read for a cell: name, the count text and the price of the shown printing.
    static func accessibilityText(_ line: DeckLine) -> String {
        [line.name, countText(line), line.shownPrice.map { CardFacts.priceText($0) } ?? "no price"].joined(separator: ", ")
    }

    /// A57, D13: a list row's price column: the shown printing's price, "No price" when it has none, nil (nothing shown)
    /// for a card without a printing; its label (`accessibilityText`) still says "no price", as the gallery's.
    static func rowPriceText(_ line: DeckLine) -> String? {
        guard line.shown != nil else { return nil }
        return line.shownPrice.map { CardFacts.priceText($0) } ?? "No price"
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

    /// The sidebar row's count (A14, D7): the deck's missing copies (`DeckMaths.missingCopies` on the copies `available`
    /// to it, E4) for an active deck that misses any; nil for a deck that is not active, misses nothing, or while the read
    /// is not there.
    static func sidebarCount(_ deck: Deck, read: DeckRead?, available: [String: Int]) -> String? {
        guard deck.active, let read else { return nil }
        let missing = DeckMaths.missingCopies(deck, printings: read.printings, ownedByCard: available,
                                              isBasic: { read.basics.contains($0) })
        return missing > 0 ? "\(missing)" : nil
    }

    /// E2–E4 over the game's decks (`DeckNeeds.needs`, only the active ones count), with the owned copies and the basic
    /// cards of `read`: a card the read does not cover counts 0 owned and is not basic (its page shows it pending).
    static func needs(decks: [Deck], sharing: [String: Bool], read: DeckRead?) -> [String: CardNeed] {
        let owned = read?.ownedByCard ?? [:], basics = read?.basics ?? []
        return DeckNeeds.needs(decks: decks, sharing: sharing, owned: { owned[$0] ?? 0 }, isBasic: { basics.contains($0) })
    }

    /// The copies `deck` may count as owned, per card it uses (`DeckNeeds.available`): an active deck is served in deck
    /// order unless the card is shared; a deck that is not active counts every owned copy.
    static func available(to deck: Deck, needs: [String: CardNeed], read: DeckRead?) -> [String: Int] {
        let owned = read?.ownedByCard ?? [:]
        return DeckNeeds.available(to: deck, needs: needs, owned: { owned[$0] ?? 0 })
    }

    /// E7: the card page's sharing line for the card's need over the active decks: none for a basic card or fewer than 2
    /// active users; `.pending` in conflict without an answer; else the stored answer (`.shared`, `.each`), also on a card
    /// that is not in conflict any more, so it can be changed. With 2 users, no conflict and no answer: none (there is
    /// nothing to decide).
    static func sharingLine(_ need: CardNeed?) -> SharingLine? {
        guard let need, !need.isBasic, need.users.count >= 2 else { return nil }
        if need.pending { return .pending }
        switch need.answer {
        case true?: return .shared
        case false?: return .each
        case nil: return nil
        }
    }

    /// E8: the pending cards (`CardNeed.pending`) among the cards `read` has printings of; nil without a read: the owned
    /// copies are not known, so no card is counted as pending. A card the read did not look up, or looked up without a
    /// printing (final fix A3: its owned copies cannot be known), is never counted. All in memory: the active decks and
    /// answers of the library, the owned counts of the sidebar's last join.
    static func pendingCount(decks: [Deck], sharing: [String: Bool], read: DeckRead?) -> Int? {
        guard let read else { return nil }
        return needs(decks: decks, sharing: sharing, read: read).values
            .filter { $0.pending && !(read.printings[$0.cardKey] ?? []).isEmpty }.count
    }

    /// E6: `onMove`'s destination (an offset in the list before the move) as the index after the removal
    /// (`UserLibrary.moveDeck(to:)`).
    static func moveIndex(from source: Int, to destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }

    /// E6, "Move Up" (`by: -1`) / "Move Down" (`by: 1`): the deck's index one step along the deck order; nil at the ends
    /// (the item is off) and for a deck that is not in `decks`.
    static func movedIndex(of id: String, in decks: [Deck], by step: Int) -> Int? {
        guard let index = decks.firstIndex(where: { $0.id == id }), decks.indices.contains(index + step) else { return nil }
        return index + step
    }

    /// The muted line under the sidebar's decks for decks of the game's file this build cannot read.
    static func unreadableText(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 deck cannot be read."
        default: "\(count) decks cannot be read."
        }
    }

    /// The muted line at the top of a deck page whose file holds cards of it this build cannot read (final fix B8).
    static func unreadableCardsText(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 card of this deck cannot be read."
        default: "\(count) cards of this deck cannot be read."
        }
    }
}

/// Deck cards joined with the catalog (`CatalogJoin`). The deck page joins its deck's cards; the sidebar joins the cards
/// of every active deck of the game, once for all its rows. The live deck is laid on the read on every render.
typealias DeckJoin = CatalogJoin<DeckRead>

extension CatalogJoin where Read == DeckRead {
    /// The key of a deck join (the deck page's, the sidebar's): the lists' key and the Yu-Gi-Oh! index's identity, so a new
    /// index (a first launch) reads the kinds again at once (final fix B7). Stored sections never change by themselves.
    static func deckKey(game: String, model: AppModel) -> CollectionJoin {
        var key = key(game: game, model: model)
        key.ygoIndexVersion = model.ygoIndexVersion
        return key
    }

    /// The last read when it was made for `game`; else nil (the sidebar keeps one join across game switches).
    func read(game: String) -> DeckRead? { joined?.game == game ? read : nil }

    /// What the deck page lists (`DeckPage.content`); nil until a join of this game has ended. The catalog counts as
    /// settled as it was for the join that made `read`. `decks` and `sharing`: the game's decks and sharing answers in
    /// memory, so the other active decks' use of this deck's cards needs no catalog read (E4).
    func content(_ deck: Deck, game: GameDefinition, decks: [Deck], sharing: [String: Bool],
                 price: ([ProductRecord]) -> ShownPrice?) -> DeckContent? {
        guard let joined, joined.game == game.id else { return nil }
        let available = DeckPage.available(to: deck, needs: DeckPage.needs(decks: decks, sharing: sharing, read: read),
                                           read: read)
        return DeckPage.content(deck, game: game, read: read, available: available, joinFailed: failed,
                                catalogHasProducts: catalogHasProducts, catalogSettled: joined.catalogSettled, price: price)
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
    /// "Add cards": the catalog search pushed on this deck's stack (search text, filters, results), kept with the deck.
    let search: CatalogScreenState
    /// "Rename…" is open.
    var renaming = false
    /// "Delete Deck…" asks.
    var confirmsDelete = false

    init(gameID: String, deckID: String) {
        self.gameID = gameID
        self.deckID = deckID
        search = CatalogScreenState(gameID: gameID, search: "")
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

    /// The game's decks are now `ids`: the state of a deck that is gone (deleted here or elsewhere) is dropped at once,
    /// so its search, pages and join do not outlive it (final fix B9).
    func keep(decks ids: Set<String>) {
        states = states.filter { ids.contains($0.key) }
    }
}

/// One deck of the selected game (D8): the totals as the window's subtitle, the "Deck" menu and one search field; then per
/// section its title, count and warning, and per group a small heading and `CardCell`s, each with a `CountControl` under
/// it. A click on a cell's picture or name opens the card page on the cell's shown printing (A18), in this deck's own
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
        let decks = model.decksInPlay(game: gameID), sharing = library.sharing(game: gameID)
        let listed = deck.flatMap {
            state.join.content($0, game: game, decks: decks, sharing: sharing) {
                prices.cheapest(game: gameID, productIDs: $0.map(\.productID))
            }
        }
        let phase = DeckPage.phase(deck: deck, listed: listed, canChange: library.canChange(game: gameID),
                                   problem: library.problem(game: gameID))
        let join = DeckJoin.deckKey(game: gameID, model: model)
        let keys = Set(deck?.cards.map(\.cardKey) ?? [])
        // Cards of the deck this build cannot read (kept in the file): one muted line under the totals (final fix B8).
        let unreadable = phase == .list || phase == .empty
            ? DeckPage.unreadableCardsText(library.unreadableCards(game: gameID, deck: state.deckID)) : nil
        content(phase, deck: deck, listed: listed, game: game)
            .safeAreaInset(edge: .top, spacing: 0) { CatalogNote(text: unreadable, identifier: "deck-unreadable-cards") }
            .listScreen("deck", note: phase == .list ? listed?.note : nil)
            .navigationTitle(deck?.name ?? "Deck")
            #if os(macOS)
            .navigationSubtitle(subtitle(phase, listed: listed))
            #else
            // R3: no subtitle on the iPhone; the totals are a line above the sections.
            .listTotals(subtitle(phase, listed: listed), identifier: "deck-totals")
            #endif
            .searchable(text: $state.text)
            #if os(iOS)
            // A54: a pushed page's actions in one "…" menu: Add cards, Paste…, then the Mac's "Deck" menu.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MoreMenu(identifier: "deck-more") {
                        // A58: the view, gallery or list; it works also while the deck cannot change.
                        viewPicker
                        Divider()
                        Group {
                            Button("Add cards", systemImage: "plus") { openSearch() }
                                .accessibilityIdentifier("deck-add-cards")
                            Button("Paste…", systemImage: "doc.on.clipboard") { model.pasteDeck(into: state.deckID) }
                                .accessibilityIdentifier("deck-paste")
                            Divider()
                            deckMenuItems(deck, game: game, kinds: state.join.read?.kinds ?? [:])
                        }
                        .disabled(deck == nil || !library.canChange(game: gameID))
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItemGroup {
                    viewPicker
                    Button("Add cards") { openSearch() }
                        .help("Add cards")
                        .disabled(deck == nil || !library.canChange(game: gameID))
                        .accessibilityIdentifier("deck-add-cards")
                    Button("Paste…") { model.pasteDeck(into: state.deckID) }
                        .help("Paste a deck as text")
                        .disabled(deck == nil || !library.canChange(game: gameID))
                        .accessibilityIdentifier("deck-paste")
                    deckMenu(deck, game: game, kinds: state.join.read?.kinds ?? [:])
                }
            }
            #endif
            .navigationDestination(for: DeckSearch.self) { _ in
                CatalogSearchView(state: state.search, deckID: state.deckID)
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
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
                    // B2: nothing while the game is not followed or its player role is off.
                    guard model.decksWritable(game: gameID) else { return }
                    #if os(iOS)
                    // The iPhone's Decks tab: back to its deck list (no root mark: the list has no kept path).
                    model.showDeckList()
                    #else
                    model.showRoot(of: .collection)
                    #endif
                    library.removeDeck(game: gameID, id: state.deckID)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its cards stay in your collection.")
            }
            // Review Focus 3 (phase 4B): the deck screen left by code (the player role turned off, here or by a reload)
            // under its Rename sheet or Delete dialog: they close without writing and do not come back with the screen.
            .onDisappear {
                guard model.screen != .deck(state.deckID) else { return }
                state.renaming = false
                state.confirmsDelete = false
            }
    }

    /// "Add cards": the deck's search, pushed through the stack's kept path (`kept(on:in:)`), so it also works while the
    /// deck shows its root after a switch made by code (New Deck's Create).
    private func openSearch() {
        let path = $state.path.kept(on: .deck(state.deckID), in: model)
        path.wrappedValue.append(DeckSearch(deckID: state.deckID))
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
            EmptyMessage(sentence: "This deck has no cards yet.") {
                Button("Add cards") { openSearch() }
                    .accessibilityIdentifier("deck-empty-add-cards")
                Button("Paste…") { model.pasteDeck(into: state.deckID) }
                    .accessibilityIdentifier("deck-empty-paste")
            }
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
        let canChange = model.library.canChange(game: state.gameID), mode = model.deckViewMode
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { RuleLine() }
                    DeckSectionBlock(section: section, warning: DeckPage.warning(section, deckHasCards: !deck.cards.isEmpty),
                                     mode: mode) { line in
                        cell(line, format: format, canChange: canChange)
                    } row: { line in
                        DeckListRow(gameID: state.gameID, line: line, format: format, canChange: canChange) {
                            step(by: $0, card: line.card)
                        }
                        .contextMenu { moveMenu(line.card, format: format, canChange: canChange) }
                    }
                }
            }
            .padding(Theme.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("deck-gallery")
    }

    /// A58: the deck page's view, gallery or list, for every deck on this device (`AppModel.deckViewMode`). A switch keeps
    /// the search text, the kept path and the deck's join; only the scroll position may reset.
    private var viewMode: Binding<DeckViewMode> {
        Binding(get: { model.deckViewMode }, set: { model.deckViewMode = $0 })
    }

    #if os(macOS)
    /// The Mac: a segmented control left of "Add cards", two symbols, tinted `faint` (not the accent).
    private var viewPicker: some View {
        Picker("View", selection: viewMode) {
            Label("Gallery", systemImage: "square.grid.2x2")
                .labelStyle(.iconOnly)
                .help("Gallery")
                .accessibilityIdentifier("deck-view-gallery")
                .tag(DeckViewMode.gallery)
            Label("List", systemImage: "list.bullet")
                .labelStyle(.iconOnly)
                .help("List")
                .accessibilityIdentifier("deck-view-list")
                .tag(DeckViewMode.list)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(Theme.faint)
        .fixedSize()
        .help("Gallery or list")
        .accessibilityIdentifier("deck-view")
    }
    #else
    /// The iPhone: "View" at the top of the deck's "…" menu (`deck-more`): "Gallery" and "List", the chosen one ticked, as
    /// an inline picker shows them. Two toggles, not a `Picker` and not in a `Section("View")`: on iOS 27 a menu's
    /// picker options, and toggles inside a section, lose their accessibility identifiers (seen: buttons "Gallery" and
    /// "List" with none), and the tests need `deck-view-gallery`, `deck-view-list`. So the menu has no "View" heading.
    @ViewBuilder
    private var viewPicker: some View {
        viewToggle("Gallery", mode: .gallery)
        viewToggle("List", mode: .list)
    }

    private func viewToggle(_ title: String, mode: DeckViewMode) -> some View {
        Toggle(title, isOn: Binding(get: { model.deckViewMode == mode }, set: { on in
            if on { model.deckViewMode = mode }
        }))
        .accessibilityIdentifier("deck-view-\(mode.rawValue)")
    }
    #endif

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
        .contextMenu { moveMenu(card, format: format, canChange: canChange) }
    }

    /// D9: a cell's or a row's context menu: "Move to" ▸ every other section of the format.
    private func moveMenu(_ card: DeckCard, format: DeckFormat, canChange: Bool) -> some View {
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

    /// As on Wanted: the step goes onto the deck's current count of the card in that section, so two clicks before the
    /// next render both count; 0 takes the card out of the section.
    private func step(by delta: Int, card: DeckCard) {
        model.library.changeDeck(game: state.gameID, id: state.deckID) { deck in
            let now = deck.cards.first { $0.id == card.id }?.count ?? 0
            return DeckRules.setting(deck, count: now + delta, cardKey: card.cardKey, name: card.name, section: card.section)
        }
    }

    /// Moves the deck one step along the deck order, from the order at the click (not at the render).
    private func move(by step: Int) {
        let library = model.library
        guard let index = DeckPage.movedIndex(of: state.deckID, in: library.decks(game: state.gameID), by: step) else { return }
        library.moveDeck(game: state.gameID, id: state.deckID, to: index)
    }

    /// "Deck": Rename…, Format ▸ (a game with more than one format), Active (a toggle), Move Up, Move Down (off at the ends),
    /// Delete Deck…. Off while the deck is gone or the game cannot change.
    private func deckMenu(_ deck: Deck?, game: GameDefinition, kinds: [String: CardKind]) -> some View {
        let library = model.library, gameID = state.gameID
        return Menu {
            deckMenuItems(deck, game: game, kinds: kinds)
        } label: {
            Text("Deck")
        }
        .disabled(deck == nil || !library.canChange(game: gameID))
        .accessibilityIdentifier("deck-menu")
    }

    /// The "Deck" menu's items (the Mac's "Deck" menu, the iPhone's "…" menu after Add cards and Paste…).
    @ViewBuilder
    private func deckMenuItems(_ deck: Deck?, game: GameDefinition, kinds: [String: CardKind]) -> some View {
        let library = model.library, gameID = state.gameID, deckID = state.deckID
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
        // E6: one step along the deck order (the sidebar's order, which serves the active decks, E4).
        let decks = library.decks(game: gameID)
        Button("Move Up") { move(by: -1) }
            .disabled(DeckPage.movedIndex(of: deckID, in: decks, by: -1) == nil)
            .accessibilityIdentifier("deck-move-up")
        Button("Move Down") { move(by: 1) }
            .disabled(DeckPage.movedIndex(of: deckID, in: decks, by: 1) == nil)
            .accessibilityIdentifier("deck-move-down")
        Divider()
        Button("Delete Deck…") { state.confirmsDelete = true }
            .accessibilityIdentifier("deck-delete")
    }
}

/// One section of the deck page: its name (15 pt semibold) and `· <count>` in `muted`, its warning right of it in `muted`
/// (a warning is not a risk), then per group a 12 pt `muted` heading and the group's cells or rows (A58); "No cards" for an
/// empty one.
private struct DeckSectionBlock<Cell: View, Row: View>: View {
    let section: DeckSectionView
    let warning: String?
    /// A58: a group's cards as gallery cells (`cell`) or as list rows (`row`, A57).
    let mode: DeckViewMode
    @ViewBuilder let cell: (DeckLine) -> Cell
    @ViewBuilder let row: (DeckLine) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(Text(section.section.name).foregroundStyle(Theme.text))\(Text(" · \(section.count)").foregroundStyle(Theme.muted))")
                    .font(Theme.deckSectionFont)
                    .monospacedDigit()
                    // A long warning wraps; it never squeezes the title.
                    .fixedSize()
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
                    switch mode {
                    case .gallery:
                        GalleryGrid(padded: false) {
                            ForEach(group.lines) { line in cell(line) }
                        }
                    case .list:
                        // A57: one row per card, a 1 pt rule between two rows; no zebra, no box.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(group.lines.enumerated()), id: \.element.id) { index, line in
                                if index > 0 {
                                    Theme.rule
                                        .frame(height: 1)
                                        .accessibilityHidden(true)
                                }
                                row(line)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

/// A deck cell (`CardCell`): the card's name, `×n` or `×n · 2 missing` and the shown printing's own price, on the shown
/// printing's picture (A18: the chosen printing, else the one owned, else the cheapest). A card with a printing opens its
/// card page on that printing; a card without one (pending, or not in
/// the catalog, D13) opens nothing and takes no hover. The caller gives it its identifier.
private struct DeckCell: View {
    let gameID: String
    let line: DeckLine

    var body: some View {
        let cell = CardCell(content: CellContent(product: line.shown, name: line.name, left: DeckPage.countText(line),
                                                 price: line.shownPrice))
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

/// A57: one card of the deck page's list. The Mac: one line, 44 pt tall: the shown printing's small picture (A18's rule, as
/// the cell), 12 pt, the card's name (one line, cut at the end, the free width), `×n` in `muted` with ` · k missing` in
/// `risk` (never for a basic card), the price right-aligned in a fixed column ("No price" when none), then the count
/// control. The picture, name, count and price are the link to the card page, `deck-cell-<cardKey>-<section>` with the
/// gallery cell's label; a card without a printing (pending, or not in the catalog, D13) has a flat block, its saved name,
/// no price and no "missing", no link and no hover, and its control works. Hover puts `surface` behind the row. The caller
/// gives the context menu. `step` gets one step of the control (+1 or −1), which the caller puts onto the deck's current
/// count (so two fast clicks both count).
struct DeckListRow: View {
    let gameID: String
    let line: DeckLine
    let format: DeckFormat
    let canChange: Bool
    let step: (Int) -> Void

    @State private var hovering = false

    /// The hover background reaches this far past the row's ends.
    private static let hoverPadding: CGFloat = 6

    private var suffix: String { "\(line.card.cardKey)-\(line.card.section)" }

    var body: some View {
        #if os(iOS)
        phoneRow
        #else
        macRow
        #endif
    }

    #if os(macOS)
    /// The Mac: one line, 44 pt: the link (picture, name, count, price), then the control; hover puts `surface` behind it.
    private var macRow: some View {
        HStack(spacing: Theme.deckRowGap) {
            link(macTexts)
            control
        }
        .frame(height: Theme.deckRowHeight)
        .padding(.horizontal, Self.hoverPadding)
        .background {
            if hovering, line.shown != nil { RoundedRectangle(cornerRadius: Theme.pictureRadius).fill(Theme.surface) }
        }
        .onHover { hovering = $0 }
        .padding(.horizontal, -Self.hoverPadding)
    }

    private var macTexts: some View {
        HStack(spacing: Theme.deckRowGap) {
            picture
            name
            count
            (price ?? Text(""))
                .lineLimit(1)
                .frame(width: Theme.tableNumberWidth, alignment: .trailing)
        }
        // The whole row's height: the link, its click area and its accessibility frame are the row's, not the picture's.
        .frame(maxHeight: .infinity)
        .contentShape([.interaction, .accessibility], Rectangle())
    }
    #else
    /// The iPhone (402 pt): two lines. The picture (40 pt tall) spans both; line 1 the name (one line, cut at the end) and
    /// the price at the right; line 2 the count at the left and the control (44 pt) at the right. The link covers the
    /// row; the control lies on top of it, so a tap on `−` or `+` never opens the card page.
    private var phoneRow: some View {
        ZStack(alignment: .bottomTrailing) {
            link(phoneTexts)
            control
        }
        .padding(.vertical, 6)
    }

    private var phoneTexts: some View {
        HStack(spacing: Theme.deckRowGap) {
            picture
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.deckRowGap) {
                    name
                    if let price { price.lineLimit(1).fixedSize() }
                }
                count
                    .frame(height: CountControl.height, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape([.interaction, .accessibility], Rectangle())
    }
    #endif

    /// `+` is off at 999 or more (the clamp never lowers a count; `−` always works).
    private var control: some View {
        let card = line.card
        return CountControl(count: card.count, label: "\(line.name), \(format.section(card.section)?.name ?? card.section)",
                            maximum: DeckRules.maxCount, prefix: "deck-cell", key: suffix) { step($0 - card.count) }
            .disabled(!canChange)
    }

    /// The link to the card page with the gallery cell's identifier and label; a card without a printing has no link (no
    /// hit testing), only the identifier and the label.
    @ViewBuilder
    private func link(_ texts: some View) -> some View {
        if let shown = line.shown {
            NavigationLink(value: CardTarget(gameID: gameID, cardKey: line.card.cardKey, startProductID: shown.productID)) {
                texts
            }
            .buttonStyle(.plain)
            .accessibilityLabel(DeckPage.accessibilityText(line))
            .accessibilityIdentifier("deck-cell-\(suffix)")
        } else {
            texts
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DeckPage.accessibilityText(line))
                .accessibilityIdentifier("deck-cell-\(suffix)")
        }
    }

    private var picture: some View {
        CardImage(product: line.shown, size: .row)
            .frame(width: Theme.deckRowPictureHeight * PictureSize.row.aspectRatio, height: Theme.deckRowPictureHeight)
    }

    private var name: some View {
        Text(line.name)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `×n` in `muted`, then ` · k missing` in `risk` (`DeckPage.countText`'s rule: never for a basic card).
    private var count: some View {
        let copies = Text("×\(line.card.count)").foregroundStyle(Theme.muted)
        let text = line.missing > 0 && !line.isBasic
            ? Text("\(copies)\(Text(" · \(line.missing) missing").foregroundStyle(Theme.risk))") : copies
        return text
            .font(Theme.bodyFont)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    /// The shown printing's price, or "No price" (`lineFont`) when it has none; nil for a card without a printing (D13: it
    /// shows nothing in the price column; its accessibility label still says "no price", as the gallery's).
    private var price: Text? {
        DeckPage.rowPriceText(line).map { text in
            Text(text)
                .font(line.shownPrice == nil ? Theme.lineFont : Theme.bodyFont)
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
        }
    }
}

extension AppModel {
    /// A card's kind for decks (`CardKinds.deckKind`: its first printing with a card type; for Yu-Gi-Oh! the YGOPRODeck
    /// type of this model's index first).
    func deckKind(game: GameDefinition, printings: [ProductRecord]) -> CardKind? {
        CardKinds.deckKind(game: game, printings: printings) { self.ygoType(cardName: $0) }
    }
}
