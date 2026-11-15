import Foundation

/// Pure rules over one deck. A card is addressed by (`cardKey`, `section`). No change made here loses a card: a move
/// and a format change keep the sum of the counts; a count set by hand or pasted is kept in `0...maxCount`.
nonisolated enum DeckRules {
    /// The most copies of one card in one section that a count control or a paste sets.
    static let maxCount = 999

    /// A new deck: no cards, not active (A14).
    static func new(name: String, format: String, id: String) -> Deck {
        Deck(id: id, name: name, format: format, active: false, cards: [])
    }

    /// Sets the count of one card in one section, clamped to `0...maxCount`, except that the clamp never lowers a count: a
    /// card already above `maxCount` (a file written by hand) keeps its count at most, so `−` takes one copy off it. 0
    /// removes the card; a new card is appended. An existing card keeps its name.
    static func setting(_ deck: Deck, count: Int, cardKey: String, name: String, section: String) -> Deck {
        let index = deck.cards.firstIndex(where: { $0.cardKey == cardKey && $0.section == section })
        let current = index.map { deck.cards[$0].count } ?? 0
        let count = min(max(count, 0), max(maxCount, current))
        var deck = deck
        if let i = index {
            if count == 0 { deck.cards.remove(at: i) } else { deck.cards[i].count = count }
        } else if count > 0 {
            deck.cards.append(DeckCard(cardKey: cardKey, name: name, section: section, count: count))
        }
        return deck
    }

    /// The copies of a card over every section of the deck.
    static func copies(_ deck: Deck, cardKey: String) -> Int {
        deck.cards.filter { $0.cardKey == cardKey }.reduce(0) { $0 + $1.count }
    }

    /// One copy more of a card in `section` (`setting`: a new card is appended with `name`; the 999 clamp holds).
    static func addingOne(_ deck: Deck, cardKey: String, name: String, section: String) -> Deck {
        let now = deck.cards.first { $0.cardKey == cardKey && $0.section == section }?.count ?? 0
        return setting(deck, count: now + 1, cardKey: cardKey, name: name, section: section)
    }

    /// One copy less of a card over the deck (the `−` of a search cell): off `defaultSection` when it holds the card, else
    /// off the first section of `order` (the format's) that holds it, else off its first card in a section `order` lacks.
    /// A card at 1 leaves that section; a card not in the deck changes nothing.
    static func takingOne(_ deck: Deck, cardKey: String, defaultSection: String, order: [String]) -> Deck {
        let held = deck.cards.filter { $0.cardKey == cardKey }
        let sections = [defaultSection] + order.filter { $0 != defaultSection }
        guard let card = sections.lazy.compactMap({ section in held.first { $0.section == section } }).first ?? held.first else {
            return deck
        }
        return setting(deck, count: card.count - 1, cardKey: cardKey, name: card.name, section: card.section)
    }

    /// Moves a card from one section to another. When the card is in the other section already, the copies are summed
    /// into that card (its place and name); otherwise the card keeps its place. Nothing changes for a card not in `from`.
    static func moving(_ deck: Deck, cardKey: String, from: String, to: String) -> Deck {
        guard from != to, let i = deck.cards.firstIndex(where: { $0.cardKey == cardKey && $0.section == from }) else {
            return deck
        }
        var deck = deck
        if let j = deck.cards.firstIndex(where: { $0.cardKey == cardKey && $0.section == to }) {
            deck.cards[j].count += deck.cards[i].count
            deck.cards.remove(at: i)
        } else {
            deck.cards[i].section = to
        }
        return deck
    }

    /// D12: the deck takes `format`; a card whose section the new format has stays there, every other card goes to
    /// `defaultSection(card)`. Cards that land on one (card, section) are summed into the first. No card and no copy is
    /// lost.
    static func changingFormat(_ deck: Deck, to format: DeckFormat, defaultSection: (DeckCard) -> String) -> Deck {
        var deck = deck
        deck.format = format.id
        let moved = deck.cards.map { card -> DeckCard in
            guard format.section(card.section) == nil else { return card }
            var card = card
            card.section = defaultSection(card)
            return card
        }
        deck.cards = summed(moved)
        return deck
    }

    /// A paste: each card with a count of 1 or more is summed into the card of its (card, section), or appended. A paste
    /// never lowers a count: a sum is kept at `max(maxCount, the count before the paste)` at most, so a card above
    /// `maxCount` (a file written by hand) keeps its count, and any other sum is `maxCount` at most.
    static func adding(_ deck: Deck, _ cards: [DeckCard]) -> Deck {
        var deck = deck
        deck.cards = summed(deck.cards)
        var index = Dictionary(deck.cards.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let before = deck.cards.map(\.count)
        for card in cards where card.count >= 1 {
            if let i = index[card.id] {
                deck.cards[i].count = min(deck.cards[i].count + card.count, max(maxCount, i < before.count ? before[i] : 0))
                if deck.cards[i].name.isEmpty { deck.cards[i].name = card.name }
            } else {
                var card = card
                card.count = min(card.count, maxCount)
                index[card.id] = deck.cards.count
                deck.cards.append(card)
            }
        }
        return deck
    }

    /// `name` when no other deck has it, else `name 2`, `name 3`, … ("Deck", "Deck 2").
    static func uniqueName(_ name: String, among names: [String]) -> String {
        let taken = Set(names)
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    /// Cards of one (card, section) summed into the first (its place and name; an empty name is filled).
    private static func summed(_ cards: [DeckCard]) -> [DeckCard] {
        var result: [DeckCard] = []
        var index: [String: Int] = [:]
        for card in cards {
            if let i = index[card.id] {
                result[i].count += card.count
                if result[i].name.isEmpty { result[i].name = card.name }
            } else {
                index[card.id] = result.count
                result.append(card)
            }
        }
        return result
    }
}
