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

    /// Sets the count of one card in one section, clamped to `0...maxCount`. 0 removes the card; a new card is appended.
    /// An existing card keeps its name.
    static func setting(_ deck: Deck, count: Int, cardKey: String, name: String, section: String) -> Deck {
        let count = min(max(count, 0), maxCount)
        var deck = deck
        if let i = deck.cards.firstIndex(where: { $0.cardKey == cardKey && $0.section == section }) {
            if count == 0 { deck.cards.remove(at: i) } else { deck.cards[i].count = count }
        } else if count > 0 {
            deck.cards.append(DeckCard(cardKey: cardKey, name: name, section: section, count: count))
        }
        return deck
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
        deck.cards = summed(moved, limit: nil)
        return deck
    }

    /// A paste: each card with a count of 1 or more is summed into the card of its (card, section), or appended. A sum is
    /// kept at `maxCount` at most.
    static func adding(_ deck: Deck, _ cards: [DeckCard]) -> Deck {
        var deck = deck
        let pasted = cards.filter { $0.count >= 1 }.map { card -> DeckCard in
            var card = card
            card.count = min(card.count, maxCount)
            return card
        }
        deck.cards = summed(deck.cards + pasted, limit: maxCount)
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
    private static func summed(_ cards: [DeckCard], limit: Int?) -> [DeckCard] {
        var result: [DeckCard] = []
        var index: [String: Int] = [:]
        for card in cards {
            if let i = index[card.id] {
                result[i].count += card.count
                if let limit { result[i].count = min(result[i].count, limit) }
                if result[i].name.isEmpty { result[i].name = card.name }
            } else {
                index[card.id] = result.count
                result.append(card)
            }
        }
        return result
    }
}
