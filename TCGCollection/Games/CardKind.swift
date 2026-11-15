import Foundation

/// What decides a card's group on a deck page and its default section: one value per card (D4). Views never read
/// type text.
nonisolated struct CardKind: Sendable, Hashable {
    let group: String
    let flags: Set<String>

    /// The group of a card whose type is unknown or empty, and of tokens and other pieces no group names.
    static let other = "Other"

    /// Yu-Gi-Oh!: a Fusion, Synchro, Xyz or Link monster.
    static let extraDeck = "extraDeck"
    /// Riftbound and Cyberpunk: a Legend.
    static let legend = "legend"
    /// Riftbound: a Rune.
    static let rune = "rune"
    /// Riftbound: a Battlefield.
    static let battlefield = "battlefield"
    /// Riftbound: a Champion Unit (it goes to the Main Deck; the user may move it to Champion).
    static let champion = "champion"
    /// Magic: a land.
    static let land = "land"
}

/// The type text of each game to a `CardKind`. Pure.
nonisolated enum CardKinds {
    private static func words(_ text: String, separators: Set<Character>) -> [String] {
        text.split(whereSeparator: { separators.contains($0) }).map { $0.lowercased() }
    }

    private static let extraDeckWords: Set<String> = ["fusion", "synchro", "xyz", "link"]

    /// Yu-Gi-Oh!: the YGOPRODeck `frameType` (`effect`, `xyz_pendulum`, `spell`, …) when it is one this app knows (A15),
    /// else the TCGplayer `Card Type` text (`Xyz/Effect Monster`, `Spell Card`, `Counter Trap`, …).
    static func yugioh(cardType: String, ygoType: String?) -> CardKind {
        if let frame = ygoType.map({ words($0, separators: ["_", " "]) }), let kind = frameKind(frame) {
            return kind
        }
        let typeWords = words(cardType, separators: [" ", "/"])
        if typeWords.contains("skill") || typeWords.contains("token") { return CardKind(group: CardKind.other, flags: []) }
        if typeWords.contains("spell") { return CardKind(group: "Spells", flags: []) }
        if typeWords.contains("trap") { return CardKind(group: "Traps", flags: []) }
        if typeWords.contains("monster") { return monster(typeWords) }
        return CardKind(group: CardKind.other, flags: [])
    }

    private static let mainFrames: Set<String> = ["normal", "effect", "ritual"]

    private static func frameKind(_ frameWords: [String]) -> CardKind? {
        guard let first = frameWords.first else { return nil }
        switch first {
        case "spell": return CardKind(group: "Spells", flags: [])
        case "trap": return CardKind(group: "Traps", flags: [])
        case "token", "skill": return CardKind(group: CardKind.other, flags: [])
        case _ where extraDeckWords.contains(first) || mainFrames.contains(first): return monster(frameWords)
        default: return nil
        }
    }

    private static func monster(_ words: [String]) -> CardKind {
        CardKind(group: "Monsters", flags: words.contains(where: extraDeckWords.contains) ? [CardKind.extraDeck] : [])
    }

    /// Magic: the card types of the front face (`MagicTypes`), the first of Land, Creature, Planeswalker, Instant,
    /// Sorcery, Artifact, Enchantment. An artifact creature is a Creature, a land creature a Land.
    static func magic(cardType: String, ygoType: String?) -> CardKind {
        let front = cardType.components(separatedBy: " // ").first ?? cardType
        let types = Set(MagicTypes.facets(front))
        for (type, group) in magicPriority where types.contains(type) {
            return CardKind(group: group, flags: type == "Land" ? [CardKind.land] : [])
        }
        return CardKind(group: CardKind.other, flags: [])
    }

    private static let magicPriority: [(String, String)] = [
        ("Land", "Lands"), ("Creature", "Creatures"), ("Planeswalker", "Planeswalkers"), ("Instant", "Instants"),
        ("Sorcery", "Sorceries"), ("Artifact", "Artifacts"), ("Enchantment", "Enchantments"),
    ]

    /// Riftbound: the `Card Type` text, parts split at `;` (`Unit;Token`). A token is Other. A Legend, Rune or Battlefield
    /// has its own group and flag; otherwise Unit, Spell, Gear (also `Champion Unit`, `Signature Spell`) in that order.
    static func riftbound(cardType: String, ygoType: String?) -> CardKind {
        let parts = cardType.split(separator: ";").map { words(String($0), separators: [" "]) }.filter { !$0.isEmpty }
        if parts.contains(["token"]) { return CardKind(group: CardKind.other, flags: []) }
        if parts.contains(["legend"]) { return CardKind(group: "Legends", flags: [CardKind.legend]) }
        if parts.contains(["rune"]) { return CardKind(group: "Runes", flags: [CardKind.rune]) }
        if parts.contains(["battlefield"]) { return CardKind(group: "Battlefields", flags: [CardKind.battlefield]) }
        let flags: Set<String> = parts.contains { $0.first == "champion" } ? [CardKind.champion] : []
        for (word, group) in [("unit", "Units"), ("spell", "Spells"), ("gear", "Gear")]
        where parts.contains(where: { $0.last == word }) {
            return CardKind(group: group, flags: flags)
        }
        return CardKind(group: CardKind.other, flags: [])
    }

    /// Cyberpunk: the `CardType` word (`Legend`, `Unit`, `Program`, `Gear`).
    static func cyberpunk(cardType: String, ygoType: String?) -> CardKind {
        switch cardType.trimmingCharacters(in: .whitespaces).lowercased() {
        case "legend": CardKind(group: "Legends", flags: [CardKind.legend])
        case "unit": CardKind(group: "Units", flags: [])
        case "program": CardKind(group: "Programs", flags: [])
        case "gear": CardKind(group: "Gear", flags: [])
        default: CardKind(group: CardKind.other, flags: [])
        }
    }
}
