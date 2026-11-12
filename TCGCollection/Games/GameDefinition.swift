import Foundation

nonisolated enum PictureSourceKind: Sendable { case tcgplayer, ygoprodeck }

/// One line of the card page stats: a label and the extended-data fields that fill it.
nonisolated struct StatField: Sendable {
    let label: String
    let fields: [String]
    let format: Format

    nonisolated enum Format: Sendable {
        case text
        /// `a/b` from two fields; a missing half is `–`. Left out when both are missing.
        case pair
        /// `true` (any case) is `Yes`, anything else `No`.
        case yesNo
    }
}

extension StatField {
    /// Shorthand for the table in `Games.all`.
    nonisolated init(_ label: String, _ fields: String..., format: Format = .text) {
        self.init(label: label, fields: fields, format: format)
    }
}

/// A card type word that makes a printing a card of its own: the bracket is added to the card name (A5).
nonisolated struct TypeSuffix: Sendable {
    let typeWord: String
    let bracket: String
}

/// One supported game: where its products live on tcgcsv, which extended-data fields hold the card
/// type and the rules text, and how it behaves (type menu, stats, basic cards) as data.
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
    /// The values of the card-type filter for one non-empty, trimmed type line.
    let facets: @Sendable (String) -> [String]
    /// The Type menu: only these values, in this order. Nil: every stored value, sorted.
    let facetOrder: [String]?
    /// The stat lines of the card page, in order.
    let stats: [StatField]
    /// Search keys of card names that are basic cards.
    let basicNames: Set<String>
    /// Words that, with `Land`, mark a basic card in the type line (before the dash).
    let basicTypeWords: [String]
    /// True when only the plain printing of a basic card is basic; its bracketed printings are normal.
    let altArtBasicsAreNormal: Bool
    /// Card type words whose printings get a bracket in the card name (Yu-Gi-Oh! `Skill` → `Skill Card`).
    let typeSuffixes: [TypeSuffix]
    /// Sets whose name starts with one of these are not in the catalog (Magic `Art Series:`).
    let excludedSetPrefixes: [String]
    /// How many copies of a card make a full set in a deck.
    let playset: Int
    /// The `Product Line` values of a TCGplayer CSV that belong to this game.
    let productLines: [String]

    static func == (a: GameDefinition, b: GameDefinition) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// A product is a card when its type field is filled, or when it has both a `Number` and a `Rarity` and the Number is
    /// not a range (A7: a range with no type field is a sealed or bundle product).
    func isCard(fields: [String: String]) -> Bool {
        func filled(_ key: String) -> Bool {
            !(fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if filled(typeField) { return true }
        let number = (fields["Number"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if number.wholeMatch(of: /\d+ *- *\d+/) != nil { return false }       // a range such as 448-451 (A7)
        return filled("Number") && filled("Rarity")
    }

    /// True when the game keeps no set of this name (A6).
    func excludesSet(named name: String) -> Bool {
        excludedSetPrefixes.contains { name.lowercased().hasPrefix($0.lowercased()) }
    }

    /// The values of the card-type filter for one raw type line. An empty line has none.
    func typeFacets(_ raw: String) -> [String] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? [] : facets(line)
    }

    /// True when the card is a basic card of its game: no deck misses it and it is never wanted.
    /// Games with `basicTypeWords` (Magic): the type line says so, or the type line is a land (or `Colorless` or empty)
    /// and the first segment of the name is a basic name. Other games: the name, after the bracket rule, is a basic name.
    func isBasicCard(name: String, cardType: String) -> Bool {
        guard !basicTypeWords.isEmpty else {
            return basicNames.contains(CardName.searchKey(CardName.base(name, game: self, cardType: cardType)))
        }
        let words = MagicTypes.typeWords(cardType)
        if words.contains("Land") && basicTypeWords.allSatisfy(words.contains) { return true }
        let line = cardType.trimmingCharacters(in: .whitespaces)
        guard words.contains("Land") || line.isEmpty || line.lowercased() == "colorless" else { return false }
        let segment = name.range(of: " - ").map { String(name[..<$0.lowerBound]) } ?? name
        return basicNames.contains(CardName.searchKey(CardName.withoutBrackets(segment, game: self)))
    }

    /// True when this printing is a basic printing (not an alt-art one) of a basic card.
    func isBasicPrinting(_ product: ProductRecord) -> Bool {
        guard isBasicCard(name: product.name, cardType: product.cardType) else { return false }
        return !altArtBasicsAreNormal || product.name == product.cardName
    }
}

nonisolated enum Games {
    static let all: [GameDefinition] = [
        GameDefinition(id: "magic-the-gathering", name: "Magic: The Gathering", categoryID: 1,
                       typeField: "SubType", textField: "OracleText", pictures: .tcgplayer,
                       keptBrackets: [], wholeNames: ["Erase (Not the Urza's Legacy One)"],
                       facets: MagicTypes.facets, facetOrder: MagicTypes.all,
                       stats: [StatField("P/T", "P", "T", format: .pair)],
                       basicNames: Set(["Plains", "Island", "Swamp", "Mountain", "Forest", "Wastes"]
                           .flatMap { [$0, "Snow-Covered \($0)"] }.map(CardName.searchKey)),
                       basicTypeWords: ["Basic"], altArtBasicsAreNormal: false,
                       typeSuffixes: [], excludedSetPrefixes: ["Art Series:"], playset: 4,
                       productLines: ["Magic", "Magic: The Gathering"]),
        GameDefinition(id: "yu-gi-oh", name: "Yu-Gi-Oh!", categoryID: 2,
                       typeField: "Card Type", textField: "Description", pictures: .ygoprodeck,
                       keptBrackets: ["Skill Card"], wholeNames: [],
                       facets: { $0.split(separator: " ").last.map { [String($0)] } ?? [] }, facetOrder: nil,
                       stats: [StatField("Attribute", "Attribute"), StatField("Type", "MonsterType"),
                               StatField("ATK", "Attack"), StatField("DEF", "Defense"), StatField("Link", "LinkRating")],
                       basicNames: [], basicTypeWords: [], altArtBasicsAreNormal: false,
                       typeSuffixes: [TypeSuffix(typeWord: "Skill", bracket: "Skill Card")],
                       excludedSetPrefixes: [], playset: 3, productLines: ["YuGiOh"]),
        GameDefinition(id: "riftbound", name: "Riftbound", categoryID: 89,
                       typeField: "Card Type", textField: "Description", pictures: .tcgplayer,
                       keptBrackets: [], wholeNames: [],
                       facets: { [$0] }, facetOrder: nil,
                       stats: [StatField("Domain", "Domain"), StatField("Energy", "Energy Cost"),
                               StatField("Power", "Power Cost"), StatField("Might", "Might"), StatField("Tag", "Tag")],
                       basicNames: Set(["Body Rune", "Calm Rune", "Chaos Rune", "Fury Rune", "Mind Rune", "Order Rune"]
                           .map(CardName.searchKey)),
                       basicTypeWords: [], altArtBasicsAreNormal: true,
                       typeSuffixes: [], excludedSetPrefixes: [], playset: 3,
                       productLines: ["Riftbound: League of Legends Trading Card Game",
                                      "Riftbound League of Legends Trading Card Game"]),
        GameDefinition(id: "cyberpunk", name: "Cyberpunk TCG", categoryID: 92,
                       typeField: "CardType", textField: "Description", pictures: .tcgplayer,
                       keptBrackets: [], wholeNames: [],
                       facets: { [$0] }, facetOrder: nil,
                       stats: [StatField("Color", "Color"), StatField("Cost", "Cost"), StatField("Power", "Power"),
                               StatField("RAM", "RAM"), StatField("Eddies", "Eddies", format: .yesNo)],
                       basicNames: [], basicTypeWords: [], altArtBasicsAreNormal: false,
                       typeSuffixes: [], excludedSetPrefixes: [], playset: 3, productLines: ["Cyberpunk TCG"]),
    ]

    static func game(_ id: String) -> GameDefinition? { all.first { $0.id == id } }
    static func game(productLine: String) -> GameDefinition? {
        all.first { $0.productLines.contains { $0.caseInsensitiveCompare(productLine) == .orderedSame } }
    }
    static func game(category: Int) -> GameDefinition? { all.first { $0.categoryID == category } }
}
