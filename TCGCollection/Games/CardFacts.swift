import Foundation

nonisolated struct CardStat: Sendable, Equatable {
    let label: String
    let value: String
}

/// The text of the card page, as plain functions so tests can read it.
nonisolated enum CardFacts {
    /// Set name, rarity and number joined by ` · `. Empty parts are left out.
    static func line(setName: String, product: ProductRecord) -> String {
        [setName, product.rarity, product.number].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The stats a printing has, in the order of the game. Fields that are missing or empty are left out.
    static func stats(_ product: ProductRecord, game: GameDefinition) -> [CardStat] {
        func field(_ name: String) -> String? {
            let value = (product.fields[name] ?? "").trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        func stat(_ label: String, _ name: String) -> CardStat? {
            field(name).map { CardStat(label: label, value: $0) }
        }
        switch game.id {
        case "magic-the-gathering":
            guard field("P") != nil || field("T") != nil else { return [] }
            return [CardStat(label: "P/T", value: "\(field("P") ?? "–")/\(field("T") ?? "–")")]
        case "yu-gi-oh":
            return [stat("Attribute", "Attribute"), stat("Type", "MonsterType"), stat("ATK", "Attack"),
                    stat("DEF", "Defense"), stat("Link", "LinkRating")].compactMap { $0 }
        case "riftbound":
            return [stat("Domain", "Domain"), stat("Energy", "Energy Cost"), stat("Power", "Power Cost"),
                    stat("Might", "Might"), stat("Tag", "Tag")].compactMap { $0 }
        case "cyberpunk":
            let eddies = field("Eddies").map { CardStat(label: "Eddies", value: $0.lowercased() == "true" ? "Yes" : "No") }
            return [stat("Color", "Color"), stat("Cost", "Cost"), stat("Power", "Power"), stat("RAM", "RAM"), eddies].compactMap { $0 }
        default:
            return []
        }
    }

    /// `$4.12`; `~$9.50` when only a low price exists; `—` with no price.
    static func priceText(_ shown: ShownPrice?) -> String {
        guard let shown else { return "—" }
        let amount = shown.amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        return shown.isLow ? "~" + amount : amount
    }
}
