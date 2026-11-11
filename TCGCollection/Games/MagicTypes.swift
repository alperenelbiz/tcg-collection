import Foundation

/// The Magic card types, and the map from a printed type line to them. Old cards print words that
/// are not types (`Summon`, `Interrupt`, `Mono`); they map to a type or to nothing.
nonisolated enum MagicTypes {
    /// The 15 card types of the comprehensive rules (`Tribal` is `Kindred`), in menu order.
    static let all: [String] = [
        "Artifact", "Battle", "Conspiracy", "Creature", "Dungeon", "Enchantment", "Instant", "Kindred",
        "Land", "Phenomenon", "Plane", "Planeswalker", "Scheme", "Sorcery", "Vanguard",
    ]

    /// Old words that stand for one type. Words that are not here are kept only when they are in `all`.
    private static let oldWords: [String: String] = [
        "interrupt": "Instant", "mana": "Instant", "tribal": "Kindred",
    ]
    /// A face that starts with one of these words has that one type: the words after it name a
    /// creature kind or a target.
    private static let onlyType: [String: String] = ["summon": "Creature", "enchant": "Enchantment"]
    private static let dashes = [" — ", " – ", " - "]

    /// The words of a face before its first dash, split at spaces and `/`.
    static func typeWords(_ face: String) -> [String] {
        let types = dashes.compactMap { face.range(of: $0)?.lowerBound }.min().map { String(face[..<$0]) } ?? face
        return types.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
    }

    /// The card types of a type line, in the order of `all`, without repeats. A split card gives
    /// the union of its faces. Supertypes, subtypes and unknown words give nothing.
    static func facets(_ typeLine: String) -> [String] {
        var found = Set<String>()
        for face in typeLine.components(separatedBy: " // ") {
            let words = typeWords(face).map { $0.lowercased() }
            if let first = words.first, let only = onlyType[first] {
                found.insert(only)
                continue
            }
            for word in words {
                if let type = oldWords[word] ?? all.first(where: { $0.lowercased() == word }) { found.insert(type) }
            }
        }
        return all.filter(found.contains)
    }
}
