import Foundation

/// A card the catalog offers for a name it does not know (`DeckPaste.NameIndex.nearest`).
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
                             (["champion", "chosenchampion"], ["champion"]), (["rune", "runes"], ["runes"]),
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
    /// bracket or a set code removed, `CardName.base`), when that differs. Then, for a name that starts with a lone `x`
    /// (`4 x Ash Blossom…`, `DeckText`), the same two keys of the name without it: the `x` is the count's separator only
    /// when the name with it matches no card (`3 X Dragon` is "X Dragon" when the catalog has it; final fix B3). None for
    /// a name without a letter or digit.
    static func keys(for name: String, game: GameDefinition) -> [String] {
        func keys(_ name: String) -> [String] {
            let whole = CardName.searchKey(name)
            guard !whole.isEmpty else { return [] }
            let base = CardName.searchKey(CardName.base(name, game: game, cardType: ""))
            return base.isEmpty || base == whole ? [whole] : [whole, base]
        }
        var result = keys(name)
        for key in withoutLoneX(name).map(keys) ?? [] where !result.contains(key) { result.append(key) }
        return result
    }

    /// The name without a leading lone `x` or `X` and the white space after it (`x Ash Blossom` → `Ash Blossom`); nil when
    /// the name does not start so, or nothing is left.
    static func withoutLoneX(_ name: String) -> String? {
        let trimmed = name.drop { $0.isWhitespace }
        guard let x = trimmed.first, x == "x" || x == "X", trimmed.dropFirst().first?.isWhitespace == true else { return nil }
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Every card line and unreadable line of `parsed`, in order, with its match and section:
    /// - `known` gives the card of a written name (nil: unknown, and `suggest` gives its nearest names).
    /// - A card goes to the section its section line names (`sectionID`; a by-hand-only one too: the text is the hand).
    ///   Without a section line, or under one the format lacks, it goes to its kind's default section; under one the
    ///   format lacks the line says so. An unknown card goes where a card of unknown kind goes.
    /// - A count of 0 is dropped ("0 copies"); a count over 999 is kept as written and saved as 999 ("saved as 999").
    /// - A line without a count is shown, dropped ("no count"; "the count is too large" for a count over `Int`).
    /// - A card whose key is not the written name's (a base-name match, a pick) says "as written: <text>".
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
                let note = DeckText.hasTooLargeCount(text) ? "the count is too large" : "no count"
                result.append(PastedLine(number: line.number, text: text, count: 0, match: .dropped, section: "", note: note))
            case .card(let count, let name):
                let card = known(name)
                let kind = card?.kind ?? CardKind(group: CardKind.other, flags: [])
                var notes: [String] = []
                // Matched by the base name or a pick: the row shows the catalog's name, and this says what was written.
                if let card, card.cardKey != CardName.searchKey(name) { notes.append("as written: \(name)") }
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
        var index: [DeckCardKey: Int] = [:]
        for line in lines where line.count >= 1 {
            guard case .card(let cardKey, let name) = line.match else { continue }
            let card = DeckCard(cardKey: cardKey, name: name, section: line.section, count: min(line.count, DeckRules.maxCount))
            if let i = index[card.key] {
                cards[i].count = min(cards[i].count + card.count, DeckRules.maxCount)
            } else {
                index[card.key] = cards.count
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

    /// At most `limit` of `candidates` nearest to `text` (`NameIndex.nearest`).
    static func nearest(_ text: String, among candidates: [Suggestion], limit: Int) -> [Suggestion] {
        NameIndex(candidates.map { ($0.cardKey, $0.name) }).nearest(text, limit: limit)
    }

    /// The names of one game's cards, ready to rank written names against, in memory (fix round 1 of task 7: the game's
    /// names are read once per paste, `CatalogStore.cardNames`). Pure; build and use it off the main thread.
    ///
    /// `nearest` ranks in three steps: a cheap filter (the candidates that share a run of letters with the written name,
    /// letters only, folded: runs of 3 letters, or of 2 for a written name of 5 letters or fewer, so `mixt` still meets
    /// `Mist`; final fix B4), of which the `preselected` that share the largest part of their own runs (shared runs ÷ the
    /// candidate's runs: a long name does not crowd out a short one); then the edit distance on the folded names (first
    /// to the candidate's first words, as many as the written name has, then to the whole candidate, then by name); at
    /// most `limit`, none further than half the written name's length.
    nonisolated struct NameIndex: Sendable {
        private struct Entry: Sendable {
            let suggestion: Suggestion
            /// The folded name (`CardName.searchKey`) as Unicode scalar values.
            let key: [UInt32]
            /// How many distinct runs of 2 and of 3 letters the name has.
            let pairs: Int32
            let triples: Int32
        }

        private let entries: [Entry]
        /// Each run of 2 letters, and each run of 3, to the entries that have it.
        private let pairRuns: [UInt64: [Int32]]
        private let tripleRuns: [UInt64: [Int32]]
        /// How many candidates of the filter get an edit distance.
        static let preselected = 400
        /// A written name of this many letters or fewer is filtered by runs of 2 letters.
        static let shortName = 5

        init(_ names: [(cardKey: String, name: String)]) {
            var seen = Set<String>()
            var entries: [Entry] = []
            var pairRuns: [UInt64: [Int32]] = [:], tripleRuns: [UInt64: [Int32]] = [:]
            for (cardKey, name) in names where seen.insert(cardKey).inserted {
                let key = Array(CardName.searchKey(name).unicodeScalars.map(\.value))
                let letters = key.filter { $0 != 32 }
                let index = Int32(entries.count)
                let pairs = Set(Self.runs(letters, length: 2)), triples = Set(Self.runs(letters, length: 3))
                for run in pairs { pairRuns[run, default: []].append(index) }
                for run in triples { tripleRuns[run, default: []].append(index) }
                entries.append(Entry(suggestion: Suggestion(cardKey: cardKey, name: name), key: key,
                                     pairs: Int32(pairs.count), triples: Int32(triples.count)))
            }
            self.entries = entries
            self.pairRuns = pairRuns
            self.tripleRuns = tripleRuns
        }

        func nearest(_ text: String, limit: Int) -> [Suggestion] {
            let key = Array(CardName.searchKey(text).unicodeScalars.map(\.value))
            let letters = key.filter { $0 != 32 }
            guard !letters.isEmpty, limit > 0 else { return [] }
            let short = letters.count <= Self.shortName
            let index = short ? pairRuns : tripleRuns
            var shared = [Int32](repeating: 0, count: entries.count)
            var touched: [Int] = []
            for run in Set(Self.runs(letters, length: short ? 2 : 3)) {
                for entry in index[run] ?? [] {
                    let i = Int(entry)
                    if shared[i] == 0 { touched.append(i) }
                    shared[i] += 1
                }
            }
            // The share of the candidate's own runs, compared without division: a/b > c/d ⇔ a·d > c·b.
            func runs(_ i: Int) -> Int64 { Int64(short ? entries[i].pairs : entries[i].triples) }
            let candidates = touched.sorted { a, b in
                let left = Int64(shared[a]) * runs(b), right = Int64(shared[b]) * runs(a)
                return left != right ? left > right : a < b
            }
            .prefix(Self.preselected)
            let words = key.split(separator: 32).count
            let most = key.count / 2
            let scored = candidates.compactMap { i -> (Suggestion, Int, Int)? in
                let entry = entries[i]
                let start = Array(entry.key.split(separator: 32, omittingEmptySubsequences: true).prefix(words)
                    .joined(separator: [32]))
                let first = DeckPaste.distance(key, start)
                guard first <= most else { return nil }
                return (entry.suggestion, first, DeckPaste.distance(key, entry.key))
            }
            return scored.sorted { ($0.1, $0.2, $0.0.name) < ($1.1, $1.2, $1.0.name) }.prefix(limit).map(\.0)
        }

        /// Every run of `length` letters, packed into one number (21 bits a letter).
        private static func runs(_ letters: [UInt32], length: Int) -> [UInt64] {
            guard letters.count >= length else { return [] }
            return (0...(letters.count - length)).map { start in
                (start..<start + length).reduce(UInt64(0)) { $0 << 21 | UInt64(letters[$1]) }
            }
        }
    }

    /// The Levenshtein distance: insertions, deletions and substitutions of one element each.
    static func distance(_ a: [UInt32], _ b: [UInt32]) -> Int {
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
