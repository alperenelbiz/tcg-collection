import Foundation

nonisolated enum PictureSourceKind: Sendable { case tcgplayer, ygoprodeck }

/// One supported game: where its products live on tcgcsv and which extended-data fields hold
/// the card type and the rules text.
nonisolated struct GameDefinition: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let categoryID: Int
    let typeField: String
    let textField: String
    let pictures: PictureSourceKind
    /// Bracket texts that are part of a card name, such as `Skill Card`: the bracket is never removed.
    let keptBrackets: [String]
    /// Official card names that contain a bracket: such a name is kept whole.
    let wholeNames: Set<String>

    /// A product is a card when its type field is filled, or when it has both a `Number` and a `Rarity`.
    func isCard(fields: [String: String]) -> Bool {
        func filled(_ key: String) -> Bool {
            !(fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return filled(typeField) || (filled("Number") && filled("Rarity"))
    }

    /// The values of the card-type filter for one raw type line.
    func typeFacets(_ raw: String) -> [String] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        switch id {
        case "magic-the-gathering":
            let supertypes: Set<String> = ["Legendary", "Basic", "Snow", "World", "Token"]
            let types = line.components(separatedBy: "—")[0]
            return types.split(separator: " ").map(String.init).filter { !supertypes.contains($0) }
        case "yu-gi-oh":
            return line.split(separator: " ").last.map { [String($0)] } ?? []
        default:
            return [line]
        }
    }
}

nonisolated enum Games {
    static let all: [GameDefinition] = [
        GameDefinition(id: "magic-the-gathering", name: "Magic: The Gathering", categoryID: 1,
                       typeField: "SubType", textField: "OracleText", pictures: .tcgplayer,
                       keptBrackets: [], wholeNames: ["Erase (Not the Urza's Legacy One)"]),
        GameDefinition(id: "yu-gi-oh", name: "Yu-Gi-Oh!", categoryID: 2,
                       typeField: "Card Type", textField: "Description", pictures: .ygoprodeck,
                       keptBrackets: ["Skill Card"], wholeNames: []),
        GameDefinition(id: "riftbound", name: "Riftbound", categoryID: 89,
                       typeField: "Card Type", textField: "Description", pictures: .tcgplayer,
                       keptBrackets: [], wholeNames: []),
        GameDefinition(id: "cyberpunk", name: "Cyberpunk TCG", categoryID: 92,
                       typeField: "CardType", textField: "Description", pictures: .tcgplayer,
                       keptBrackets: [], wholeNames: []),
    ]

    static func game(_ id: String) -> GameDefinition? { all.first { $0.id == id } }
    static func game(category: Int) -> GameDefinition? { all.first { $0.categoryID == category } }
}
