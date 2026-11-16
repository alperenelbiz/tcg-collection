import Foundation

/// Which printings of one game have a price history (A35, A36, H6), pure. The caller passes the decks in play
/// (`decksInPlay(game:)`: none without the player role) and the catalog's product ids of each card key.
nonisolated enum TrackedPrintings {
    /// The card keys whose every printing is tracked: each card on Wanted and each card of the decks passed, once.
    static func cardKeys(wanted: [WantedEntry], decks: [Deck]) -> Set<String> {
        var keys = Set(wanted.map(\.cardKey))
        for deck in decks { keys.formUnion(deck.cards.map(\.cardKey)) }
        return keys
    }

    /// The tracked product ids: every collection row and for-sale entry with a count of 1 or more, every Wanted pin (also
    /// one whose card has no printing in `printingsByCard`), and every product of each key in `cardKeys`.
    static func productIDs(collection: [CollectionRow], forSale: [SaleEntry], wanted: [WantedEntry],
                           printingsByCard: [String: [Int]], cardKeys: Set<String>) -> Set<Int> {
        var ids = Set<Int>()
        for row in collection where row.count >= 1 { ids.insert(row.productID) }
        for entry in forSale where entry.count >= 1 { ids.insert(entry.productID) }
        for entry in wanted { if let pin = entry.pin { ids.insert(pin.productID) } }
        for key in cardKeys { ids.formUnion(printingsByCard[key] ?? []) }
        return ids
    }
}
