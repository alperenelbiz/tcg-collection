import Foundation

/// One card of a deck (D1, D2): the catalog's card key, the card's name when it was added, the section id (a section of
/// the deck's format, kept as written when the format lacks it) and a count. One card can stand in two sections.
nonisolated struct DeckCard: Codable, Sendable, Equatable, Identifiable {
    var cardKey: String
    var name: String
    var section: String
    var count: Int

    /// The card's key in its deck (D2): the card and its section. Every merge of deck cards uses it.
    var key: DeckCardKey { DeckCardKey(cardKey: cardKey, section: section) }
    /// The same as a string, `cardKey|section`, for SwiftUI's ids and the UI tests' identifiers only.
    var id: String { "\(cardKey)|\(section)" }

    enum CodingKeys: String, CodingKey, CaseIterable { case cardKey, name, section, count }
    /// The JSON keys this type writes; the game file takes them out of the object it read before writing them.
    static let storedKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

/// The key of a card in its deck (D2): one card can stand in two sections (final fix B9: a struct, not `cardKey|section`).
nonisolated struct DeckCardKey: Hashable, Sendable {
    let cardKey: String
    let section: String
}

/// A deck of one game (D1): a stable id (a UUID string), a name, a format id of the game (kept as written when this build
/// does not know it), whether it is active (A14: a new deck is not) and its cards. The order of a game's decks is the
/// user's deck order.
nonisolated struct Deck: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var format: String
    var active: Bool
    var cards: [DeckCard]

    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, format, active, cards }
    /// The JSON keys this type writes; the game file takes them out of the object it read before writing them.
    static let storedKeys = Set(CodingKeys.allCases.map(\.rawValue))
}
