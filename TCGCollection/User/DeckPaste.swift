import Foundation

/// A card the catalog offers for a name it does not know (`CatalogStore.nearestNames`).
nonisolated struct Suggestion: Sendable, Hashable {
    let cardKey: String
    let name: String
}

/// One card line (or unreadable line) of a pasted deck, as the paste sheet shows it before anything is saved.
nonisolated struct PastedLine: Sendable, Identifiable, Equatable {
    /// The line's number in the text (from 1).
    let number: Int
    /// The name as written on a card line; the whole line on an unreadable one.
    let text: String
    /// The count as written (0 and over 999 too); 0 on an unreadable line.
    let count: Int
    var match: Match
    /// The section id the card goes to; "" on an unreadable line.
    let section: String
    /// What the sheet says about the line: "0 copies", "saved as 999", "no section Sideboard in Commander", "no count".
    let note: String?

    var id: Int { number }

    nonisolated enum Match: Sendable, Equatable {
        /// The catalog's card of the name, and the card's name.
        case card(cardKey: String, name: String)
        /// No card of that name: the nearest names, nearest first (at most 5).
        case unknown(suggestions: [Suggestion])
        /// Not saved: a count of 0, a line without a count, or dropped by the user.
        case dropped
    }
}

/// A pasted deck's text matched with the catalog (D11): each card line's card, section and note; the cards a paste saves
/// and its summary; the nearest names of an unknown one. Pure.
nonisolated enum DeckPaste {
    /// The section of `format` that a section line names: its name or id, ignoring case, spaces and punctuation, or a name
    /// the old app's files use ("Main", "Side", "Sideboard", "Runes", …). Nil when the format has no such section.
    static func sectionID(named name: String, in format: DeckFormat) -> String? {
        let wanted = folded(name)
        guard !wanted.isEmpty else { return nil }
        if let section = format.sections.first(where: { folded($0.name) == wanted || folded($0.id) == wanted }) {
            return section.id
        }
        guard let ids = aliases[wanted] else { return nil }
        return ids.first { format.section($0) != nil }
    }

    /// The old app's section names: each to the section ids it may be, in order (the first the format has wins).
    private static let aliases: [String: [String]] = {
        var table: [String: [String]] = [:]
        for (names, ids) in [(["main", "maindeck", "deck"], ["main", "deck"]), (["extra", "extradeck"], ["extra"]),
                             (["side", "sidedeck", "sideboard"], ["side", "sideboard"]),
                             (["commander", "commanders"], ["commander"]), (["legend", "legends"], ["legend", "legends"]),
                             (["champion"], ["champion"]), (["rune", "runes"], ["runes"]),
                             (["battlefield", "battlefields"], ["battlefields"])] {
            for name in names { table[name] = ids }
        }
        return table
    }()

    /// Lowercase letters and digits only.
    private static func folded(_ text: String) -> String {
        CardName.searchKey(text).replacingOccurrences(of: " ", with: "")
    }

    /// The card keys to look a written name up by, in order: the key of the whole name, then the key of its base name (a
    /// bracket or a set code removed, `CardName.base`), when that differs. None for a name without a letter or digit.
    static func keys(for name: String, game: GameDefinition) -> [String] {
        let whole = CardName.searchKey(name)
        guard !whole.isEmpty else { return [] }
        let base = CardName.searchKey(CardName.base(name, game: game, cardType: ""))
        return base.isEmpty || base == whole ? [whole] : [whole, base]
    }

    /// Every card line and unreadable line of `parsed`, in order, with its match and section:
    /// - `known` gives the card of a written name (nil: unknown, and `suggest` gives its nearest names).
    /// - A card goes to the section its section line names (`sectionID`; a by-hand-only one too: the text is the hand).
    ///   Without a section line, or under one the format lacks, it goes to its kind's default section; under one the
    ///   format lacks the line says so. An unknown card goes where a card of unknown kind goes.
    /// - A count of 0 is dropped ("0 copies"); a count over 999 is kept as written and saved as 999 ("saved as 999").
    /// - A line without a count is shown, dropped ("no count").
    static func lines(_ parsed: [DeckTextLine], format: DeckFormat,
                      known: (String) -> (cardKey: String, name: String, kind: CardKind)?,
                      suggest: (String) -> [Suggestion], game: GameDefinition) -> [PastedLine] {
        var named: (text: String, id: String?)?
        var result: [PastedLine] = []
        for line in parsed {
            switch line.kind {
            case .note:
                continue
            case .section(let name):
                named = (name, sectionID(named: name, in: format))
            case .unreadable(let text):
                result.append(PastedLine(number: line.number, text: text, count: 0, match: .dropped, section: "", note: "no count"))
            case .card(let count, let name):
                let card = known(name)
                let kind = card?.kind ?? CardKind(group: CardKind.other, flags: [])
                var notes: [String] = []
                if count == 0 { notes.append("0 copies") }
                if count > DeckRules.maxCount { notes.append("saved as \(DeckRules.maxCount)") }
                let section: String
                if let id = named?.id {
                    section = id
                } else {
                    section = game.defaultSection(format: format, kind: kind)
                    if let text = named?.text { notes.append("no section \(text) in \(format.name)") }
                }
                let match: PastedLine.Match = count == 0 ? .dropped
                    : card.map { .card(cardKey: $0.cardKey, name: $0.name) } ?? .unknown(suggestions: suggest(name))
                result.append(PastedLine(number: line.number, text: name, count: count, match: match, section: section,
                                         note: notes.isEmpty ? nil : notes.joined(separator: " · ")))
            }
        }
        return result
    }

    /// The cards a paste saves: the matched lines with a count of 1 or more, each at most 999, summed by (card, section) in
    /// the order of their first line, each sum at most 999.
    static func cards(_ lines: [PastedLine]) -> [DeckCard] {
        var cards: [DeckCard] = []
        var index: [String: Int] = [:]
        for line in lines where line.count >= 1 {
            guard case .card(let cardKey, let name) = line.match else { continue }
            let card = DeckCard(cardKey: cardKey, name: name, section: line.section, count: min(line.count, DeckRules.maxCount))
            if let i = index[card.id] {
                cards[i].count = min(cards[i].count + card.count, DeckRules.maxCount)
            } else {
                index[card.id] = cards.count
                cards.append(card)
            }
        }
        return cards
    }

    /// The lines still unknown (not dropped): the paste cannot be saved while there is one.
    static func unknownCount(_ lines: [PastedLine]) -> Int {
        lines.filter { if case .unknown = $0.match { true } else { false } }.count
    }

    /// "58 cards on 31 lines, 2 lines not recognised, 1 line dropped": the copies `cards` saves, the lines they come from,
    /// then the unknown and the dropped lines when there are any.
    static func summary(_ lines: [PastedLine]) -> String {
        let saved = lines.filter { line in
            if case .card = line.match { line.count >= 1 } else { false }
        }
        let copies = cards(lines).reduce(0) { $0 + $1.count }
        let dropped = lines.filter { $0.match == .dropped }.count
        var parts = ["\(plural(copies, "card")) on \(plural(saved.count, "line"))"]
        let unknown = unknownCount(lines)
        if unknown > 0 { parts.append("\(plural(unknown, "line")) not recognised") }
        if dropped > 0 { parts.append("\(plural(dropped, "line")) dropped") }
        return parts.joined(separator: ", ")
    }

    private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    // MARK: Nearest names

    /// At most `limit` of `candidates`, one per card key, nearest to `text` first. Both are compared folded
    /// (`CardName.searchKey`): first by the edit distance from the text to the candidate's first words (as many words as
    /// the text has: "Ash Blosom" is 1 from "Ash Blossom & Joyous Spring"), then by the distance to the whole candidate,
    /// then by name. None for a text without a letter or digit.
    static func nearest(_ text: String, among candidates: [Suggestion], limit: Int) -> [Suggestion] {
        let key = Array(CardName.searchKey(text))
        guard !key.isEmpty, limit > 0 else { return [] }
        let words = key.split(separator: " ").count
        var seen = Set<String>()
        let scored = candidates.compactMap { candidate -> (Suggestion, Int, Int)? in
            guard seen.insert(candidate.cardKey).inserted else { return nil }
            let folded = CardName.searchKey(candidate.name)
            let start = folded.split(separator: " ").prefix(words).joined(separator: " ")
            return (candidate, distance(key, Array(start)), distance(key, Array(folded)))
        }
        return scored.sorted { ($0.1, $0.2, $0.0.name) < ($1.1, $1.2, $1.0.name) }.prefix(limit).map(\.0)
    }

    /// The Levenshtein distance: insertions, deletions and substitutions of one character each.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
