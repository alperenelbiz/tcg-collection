import Foundation

/// One section of a deck (Main Deck, Sideboard, …) with its size rule. A nil bound is no rule: no warning.
nonisolated struct DeckSection: Sendable, Hashable, Identifiable {
    /// A stable lowercase word, stored in the user's file (`main`, `extra`, `side`, `sideboard`, …).
    let id: String
    let name: String
    let min: Int?
    let max: Int?
    /// True when no card goes here by default: only the user puts a card here (Side Deck, Sideboard, Champion).
    let byHandOnly: Bool
    /// The allowed sizes when the rule is a list (Cyberpunk's Side Deck: 0 or 7). Empty: `min` and `max` decide.
    var sizes: [Int] = []
    /// The most copies of one card inside this section alone (Cyberpunk's Legends: different names). Nil: no rule.
    var maxCopies: Int? = nil
}

/// A way to build a deck of a game: its sections in order and the copy limit. Each number has its source in
/// `docs/deck-rules-sources.md`; a number without an official source is nil.
nonisolated struct DeckFormat: Sendable, Hashable, Identifiable {
    /// A stable lowercase word, stored in the user's file (`standard`, `commander`, `constructed`).
    let id: String
    let name: String
    let sections: [DeckSection]
    /// The most copies of one card over `countedSections` together. Nil: no rule.
    let copyLimit: Int?
    /// The section ids whose cards count toward the copy limit together.
    let countedSections: [String]
    /// Size rules over more than one section (Commander's 100 with the commander). Empty for most formats.
    let totals: [DeckTotal]

    init(id: String, name: String, sections: [DeckSection], copyLimit: Int?, countedSections: [String],
         totals: [DeckTotal] = []) {
        self.id = id
        self.name = name
        self.sections = sections
        self.copyLimit = copyLimit
        self.countedSections = countedSections
        self.totals = totals
    }

    func section(_ id: String) -> DeckSection? { sections.first { $0.id == id } }
}

/// A size rule over several sections together: the official number counts cards that the approved table splits into two
/// sections. A nil bound is no rule.
nonisolated struct DeckTotal: Sendable, Hashable {
    let sections: [String]
    let min: Int?
    let max: Int?
    /// What a warning calls these sections together: "Commander deck", "Main Deck with its Champion".
    let name: String
}

/// A flag of `CardKind` that sends a card to a section by default, when the format has that section.
nonisolated struct SectionDefault: Sendable {
    let flag: String
    let section: String
}

/// Everything a game says about decks: formats, group order, default sections and how a type text becomes a kind.
nonisolated struct DeckDefinition: Sendable {
    let formats: [DeckFormat]
    /// The order of the groups on a deck page; `CardKind.other` is last.
    let groups: [String]
    /// Checked in order; the first flag of the kind whose section the format has (and is not by hand only) wins.
    let defaults: [SectionDefault]
    /// The kind of a card from its catalog type text and, for Yu-Gi-Oh!, its YGOPRODeck `frameType`.
    let kind: @Sendable (_ cardType: String, _ ygoType: String?) -> CardKind

    /// No decks: the definition of a game that has none yet.
    static let none = DeckDefinition(formats: [], groups: [CardKind.other], defaults: [],
                                     kind: { _, _ in CardKind(group: CardKind.other, flags: []) })
}

nonisolated extension GameDefinition {
    var formats: [DeckFormat] { deck.formats }
    var deckGroups: [String] { deck.groups }

    /// The format of this id; the game's first format for an unknown id.
    func format(_ id: String) -> DeckFormat { formats.first { $0.id == id } ?? formats[0] }

    func kind(cardType: String, ygoType: String?) -> CardKind { deck.kind(cardType, ygoType) }

    /// The section a card goes to when it is added: the section of its first flag that the format has, else the first
    /// counted section that is not by hand only, else the first section that is not by hand only.
    func defaultSection(format: DeckFormat, kind: CardKind) -> String {
        for rule in deck.defaults where kind.flags.contains(rule.flag) {
            if let section = format.section(rule.section), !section.byHandOnly { return section.id }
        }
        let open = format.sections.filter { !$0.byHandOnly }
        return open.first { format.countedSections.contains($0.id) }?.id ?? open.first?.id ?? format.sections[0].id
    }
}

/// The deck data of the four games.
nonisolated enum GameDecks {
    private static func section(_ id: String, _ name: String, min: Int? = nil, max: Int? = nil,
                                sizes: [Int] = [], maxCopies: Int? = nil, byHand: Bool = false) -> DeckSection {
        DeckSection(id: id, name: name, min: min, max: max, byHandOnly: byHand, sizes: sizes, maxCopies: maxCopies)
    }

    /// Konami's rulebook: Main 40–60, Extra up to 15, Side up to 15, 3 copies over the three together.
    static let yugioh = DeckDefinition(
        formats: [DeckFormat(id: "standard", name: "Standard",
                             sections: [section("main", "Main Deck", min: 40, max: 60),
                                        section("extra", "Extra Deck", max: 15),
                                        section("side", "Side Deck", max: 15, byHand: true)],
                             copyLimit: 3, countedSections: ["main", "extra", "side"])],
        groups: ["Monsters", "Spells", "Traps", CardKind.other],
        defaults: [SectionDefault(flag: CardKind.extraDeck, section: "extra")],
        kind: { CardKinds.yugioh(cardType: $0, ygoType: $1) })

    /// Comprehensive Rules 903 and 702.124 (Commander), 100.2a and 100.4a (Constructed). Commander's 100 cards include
    /// its one or two commanders: a total over both sections. The Commander section is filled by hand.
    static let magic = DeckDefinition(
        formats: [DeckFormat(id: "commander", name: "Commander",
                             sections: [section("commander", "Commander", min: 1, max: 2, byHand: true),
                                        section("deck", "Deck")],
                             copyLimit: 1, countedSections: ["commander", "deck"],
                             totals: [DeckTotal(sections: ["commander", "deck"], min: 100, max: 100, name: "Commander deck")]),
                  DeckFormat(id: "constructed", name: "Constructed",
                             sections: [section("deck", "Deck", min: 60),
                                        section("sideboard", "Sideboard", max: 15, byHand: true)],
                             copyLimit: 4, countedSections: ["deck", "sideboard"])],
        groups: ["Creatures", "Instants", "Sorceries", "Artifacts", "Enchantments", "Planeswalkers", "Lands", CardKind.other],
        defaults: [],
        kind: { CardKinds.magic(cardType: $0, ygoType: $1) })

    /// Riftbound Core Rules 103 and Tournament Rules 601 (2026-10-09). The Main Deck's exactly 40 (A20) include the Chosen
    /// Champion, which stands in the Champion section: a total over both sections.
    static let riftbound = DeckDefinition(
        formats: [DeckFormat(id: "standard", name: "Standard",
                             sections: [section("legend", "Legend", min: 1, max: 1),
                                        section("champion", "Champion", min: 1, max: 1, byHand: true),
                                        section("main", "Main Deck"),
                                        section("runes", "Runes", min: 12, max: 12),
                                        section("battlefields", "Battlefields", min: 3, max: 3),
                                        section("sideboard", "Sideboard", max: 10, byHand: true)],
                             copyLimit: 3, countedSections: ["champion", "main", "sideboard"],
                             totals: [DeckTotal(sections: ["champion", "main"], min: 40, max: 40,
                                                name: "Main Deck with its Champion")])],
        groups: ["Units", "Spells", "Gear", "Legends", "Runes", "Battlefields", CardKind.other],
        defaults: [SectionDefault(flag: CardKind.legend, section: "legend"),
                   SectionDefault(flag: CardKind.rune, section: "runes"),
                   SectionDefault(flag: CardKind.battlefield, section: "battlefields")],
        kind: { CardKinds.riftbound(cardType: $0, ygoType: $1) })

    /// The official gameplay guide and Alperen's answer of 2026-11-16 (A21): exactly 3 Legends with different names,
    /// 40–50 other cards, a Side Deck of 0 or 7 cards, 3 copies over the Main Deck and the Side Deck together.
    static let cyberpunk = DeckDefinition(
        formats: [DeckFormat(id: "standard", name: "Standard",
                             sections: [section("legends", "Legends", min: 3, max: 3, maxCopies: 1),
                                        section("main", "Main Deck", min: 40, max: 50),
                                        section("side", "Side Deck", sizes: [0, 7], byHand: true)],
                             copyLimit: 3, countedSections: ["main", "side"])],
        groups: ["Units", "Programs", "Gear", "Legends", CardKind.other],
        defaults: [SectionDefault(flag: CardKind.legend, section: "legends")],
        kind: { CardKinds.cyberpunk(cardType: $0, ygoType: $1) })
}
