import Foundation
import Observation
import os

/// One paste of a deck as text (D11, A16), from the text to the deck written: parse (`DeckText`), look the names up
/// (through `reader`, off the main thread), show every line with its match (`DeckPaste.lines`), take the user's fixes
/// (pick a nearest name, drop a line), and apply. `PasteDeckSheet` shows it; nothing is written before `apply()`.
/// - "Read" is off while the game's catalog is not settled: every name would be unknown. A settled catalog without products
///   of the game ends the read with a sentence.
/// - A game that cannot change (the folder is missing, its file refused) says why (`problem`); nothing can be applied.
/// - Adding to a deck: the lines take the deck's format as it is now; when the deck changed since the read (a reload), the
///   sheet says so (`notice`) and the paste adds to the deck as it is then (a paste adds; it replaces nothing).
@Observable
final class PasteDeckModel: Identifiable {
    enum Step: Equatable {
        /// The text field.
        case text
        /// The names are looked up.
        case reading
        /// The table of lines.
        case table
        /// The read could not be made: one sentence, and Back.
        case failed(String)
    }

    /// A card a written name stands for, with its kind (D4), which picks its default section.
    private struct Found {
        let cardKey: String
        let name: String
        let kind: CardKind
    }

    nonisolated static let catalogUpdating = "The catalog is being updated. Paste when the update is done."
    nonisolated static let catalogEmpty = "The catalog has no cards of this game yet. Paste when it has downloaded."
    nonisolated static let deckChanged = "This deck changed while the sheet was open."
    nonisolated static let deckGone = "This deck was removed."
    nonisolated static func unreadable(_ reason: String) -> String { "The catalog could not be read (\(reason))." }

    let gameID: String
    /// The deck the paste adds to; nil: the paste creates a deck (`name`, `format`).
    let deckID: String?
    /// A new deck's name; a blank one becomes a unique "Deck" (`UserLibrary.addDeck`).
    var name: String
    /// A new deck's format id.
    var format: String
    var text: String
    private(set) var step: Step = .text
    /// Lines whose name was not known, fixed by a pick: the written name's search key to the card picked. One pick fixes
    /// every line of that name.
    private(set) var picks: [String: Suggestion] = [:]
    /// The line numbers the user dropped.
    private(set) var drops: Set<Int> = []

    private var parsed: [DeckTextLine] = []
    /// The last read: each written name's card, by the name's search key (`DeckPaste.keys`: the whole name, then its base).
    private var found: [String: Found] = [:]
    /// The nearest names of each unknown written name, by the name's search key.
    private var suggestions: [String: [Suggestion]] = [:]
    /// The cards of every suggestion, by card key (a pick needs the card's kind).
    private var suggested: [String: Found] = [:]
    /// The target deck when the read ended.
    private var deckAtRead: Deck?

    @ObservationIgnored private let library: UserLibrary
    @ObservationIgnored private let reader: CatalogStore
    @ObservationIgnored private let catalogSettled: @MainActor (String) -> Bool
    /// The YGOPRODeck type of a card name (A15); the caller gives one only for Yu-Gi-Oh!.
    @ObservationIgnored private let ygoType: @MainActor (String) -> String?
    /// Each read takes the next number; only the latest one stores what it found.
    @ObservationIgnored private var reading = 0
    @ObservationIgnored private let log = Logger(subsystem: "TCGCollection2", category: "paste")

    init(gameID: String, deckID: String?, name: String = "", format: String = "", text: String = "", library: UserLibrary,
         reader: CatalogStore, catalogSettled: @escaping @MainActor (String) -> Bool,
         ygoType: @escaping @MainActor (String) -> String? = { _ in nil }) {
        self.gameID = gameID
        self.deckID = deckID
        self.name = name
        self.format = format.isEmpty ? Games.game(gameID)?.formats.first?.id ?? "" : format
        self.text = text
        self.library = library
        self.reader = reader
        self.catalogSettled = catalogSettled
        self.ygoType = ygoType
    }

    private var game: GameDefinition? { Games.game(gameID) }

    /// The target deck as it is now; nil for a new deck or a deck that is gone.
    var deck: Deck? { deckID.flatMap { library.deck(game: gameID, id: $0) } }

    /// The format the lines are sorted into: the target deck's, or the new deck's.
    var currentFormat: DeckFormat? {
        guard let game, !game.formats.isEmpty else { return nil }
        return game.format(deckID == nil ? format : deck?.format ?? format)
    }

    // MARK: What the sheet shows

    /// Why nothing can be saved: the game's problem, or "Reading your collection…" before the folder is read.
    var problem: String? {
        library.canChange(game: gameID) ? nil : library.problem(game: gameID) ?? "Reading your collection…"
    }

    /// Why "Read" is off although there is text: the game's catalog step is still to come or running.
    var catalogBlock: String? { catalogSettled(gameID) ? nil : Self.catalogUpdating }

    var canRead: Bool {
        step == .text && problem == nil && catalogBlock == nil && currentFormat != nil
            && (deckID == nil || deck != nil) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every card line and unreadable line, with the user's picks and drops; empty until a read has ended.
    var lines: [PastedLine] {
        guard step == .table, let game, let format = currentFormat else { return [] }
        var shown = DeckPaste.lines(parsed, format: format, known: card(named:),
                                    suggest: { self.suggestions[CardName.searchKey($0)] ?? [] }, game: game)
        for i in shown.indices where drops.contains(shown[i].number) { shown[i].match = .dropped }
        return shown
    }

    /// The nearest names of a line whose written name the catalog does not know (also once a pick fixed it); nil for a
    /// line whose name it knows, and for an unreadable line (it has no section).
    func suggestions(for line: PastedLine) -> [Suggestion]? {
        let key = CardName.searchKey(line.text)
        return line.section.isEmpty || found[key] != nil ? nil : suggestions[key]
    }

    /// True when the user dropped the line (it can be kept again).
    func isDroppedByHand(_ line: PastedLine) -> Bool { drops.contains(line.number) }

    var cards: [DeckCard] { DeckPaste.cards(lines) }

    var summary: String { DeckPaste.summary(lines) }

    var unknownCount: Int { DeckPaste.unknownCount(lines) }

    /// "This deck changed while the sheet was open." or "This deck was removed.", for a paste into a deck after the read.
    var notice: String? {
        guard deckID != nil, step == .table else { return nil }
        guard let deck else { return Self.deckGone }
        return deck == deckAtRead ? nil : Self.deckChanged
    }

    /// "Create deck" / "Add to <deck>" is on: the table is shown, the game can change, the deck is there (when adding), no
    /// line is still unknown, and at least one line is saved.
    var canApply: Bool {
        guard step == .table, problem == nil, deckID == nil || deck != nil else { return false }
        let lines = lines
        return DeckPaste.unknownCount(lines) == 0 && !DeckPaste.cards(lines).isEmpty
    }

    // MARK: Reading

    /// Parses the text, looks every written name up by its exact keys (one store call), the unknown names' nearest names
    /// (one call each) and the cards of those (one call), then shows the table. A read that a later one overtook, or that
    /// was cancelled, stores nothing.
    func read() async {
        guard canRead, let game else { return }
        reading += 1
        let number = reading
        step = .reading
        let parsed = DeckText.parse(text)
        var names: [String: String] = [:], counted: Set<String> = []
        for line in parsed {
            guard case .card(let count, let name) = line.kind else { continue }
            let key = CardName.searchKey(name)
            if names[key] == nil { names[key] = name }
            if count > 0 { counted.insert(key) }
        }
        do {
            guard try await reader.hasProducts(game: gameID) else {
                if number == reading { step = .failed(Self.catalogEmpty) }
                return
            }
            let keys = names.mapValues { DeckPaste.keys(for: $0, game: game) }
            let cards = try await reader.cards(game: gameID, keys: Array(Set(keys.values.flatMap { $0 })))
            var found: [String: Found] = [:], whole = 0, base = 0
            for (key, tries) in keys {
                if let card = tries.first.flatMap({ cards[$0] }) {
                    found[key] = make(card, game: game)
                    whole += 1
                } else if tries.count > 1, let card = cards[tries[1]] {
                    found[key] = make(card, game: game)
                    base += 1
                }
            }
            var suggestions: [String: [Suggestion]] = [:]
            for (key, name) in names where found[key] == nil && counted.contains(key) {
                try Task.checkCancellation()
                suggestions[key] = try await reader.nearestNames(game: gameID, to: name, limit: 5)
            }
            let offered = try await reader.cards(game: gameID, keys: Array(Set(suggestions.values.flatMap { $0.map(\.cardKey) })))
            guard number == reading, !Task.isCancelled else { return }
            self.parsed = parsed
            self.found = found
            self.suggestions = suggestions
            suggested = offered.mapValues { make($0, game: game) }
            picks = [:]
            drops = []
            deckAtRead = deck
            step = .table
            log.debug("paste read: \(names.count) names, \(whole) by the whole name, \(base) by the base name, \(names.count - whole - base) unknown")
        } catch {
            guard number == reading, !(error is CancellationError), !Task.isCancelled else { return }
            step = .failed(Self.unreadable(error.localizedDescription))
        }
    }

    private func make(_ card: CatalogCard, game: GameDefinition) -> Found {
        // The one kind rule of every deck place (`CardKinds.deckKind`); `CatalogStore.cards` chose the deciding printing.
        Found(cardKey: card.cardKey, name: card.name,
              kind: CardKinds.deckKind(game: game, cardType: card.cardType, cardName: card.name, ygoType: { self.ygoType($0) }))
    }

    /// The card of a written name: the read's match, else the user's pick for that name.
    private func card(named name: String) -> (cardKey: String, name: String, kind: CardKind)? {
        let key = CardName.searchKey(name)
        guard let card = found[key] ?? picks[key].flatMap({ suggested[$0.cardKey] }) else { return nil }
        return (card.cardKey, card.name, card.kind)
    }

    /// Back to the text: the table is read again from it.
    func back() {
        reading += 1
        step = .text
    }

    // MARK: Fixing

    /// Every line of this line's written name takes the card `suggestion`; a line the user dropped is kept again.
    func pick(_ suggestion: Suggestion, for line: PastedLine) {
        picks[CardName.searchKey(line.text)] = suggestion
        drops.remove(line.number)
    }

    func drop(_ line: PastedLine) { drops.insert(line.number) }

    /// A line the user dropped is shown as it was read again.
    func keep(_ line: PastedLine) { drops.remove(line.number) }

    // MARK: Applying

    /// Writes the paste: for a new deck `addDeck` (not active, A14) then one `changeDeck`; for a deck, one `changeDeck` on
    /// the deck as it is then. Each card is summed into the deck's card of its (card, section) (`DeckRules.adding`: no
    /// count is lowered). Returns the deck's id; nil when nothing is written (`canApply` is false, or the library refused).
    @discardableResult
    func apply() -> String? {
        guard canApply else { return nil }
        let cards = cards
        let id: String
        if let deckID {
            id = deckID
        } else {
            guard let added = library.addDeck(game: gameID, name: name, format: format) else { return nil }
            id = added
        }
        library.changeDeck(game: gameID, id: id) { DeckRules.adding($0, cards) }
        return id
    }
}
