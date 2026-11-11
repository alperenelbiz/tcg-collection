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
        return game.stats.compactMap { stat in
            let values = stat.fields.map(field)
            switch stat.format {
            case .text:
                return values[0].map { CardStat(label: stat.label, value: $0) }
            case .pair:
                guard values.contains(where: { $0 != nil }) else { return nil }
                return CardStat(label: stat.label, value: values.map { $0 ?? "–" }.joined(separator: "/"))
            case .yesNo:
                return values[0].map { CardStat(label: stat.label, value: $0.lowercased() == "true" ? "Yes" : "No") }
            }
        }
    }

    /// `$4.12`; `~$9.50` when only a low price exists; `—` with no price.
    static func priceText(_ shown: ShownPrice?) -> String {
        guard let shown else { return "—" }
        let amount = shown.amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        return shown.isLow ? "~" + amount : amount
    }
}
