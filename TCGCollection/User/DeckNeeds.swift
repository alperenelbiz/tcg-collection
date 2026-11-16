import Foundation

/// One active deck's use of a card (E2, E4): its copies over all sections, the copies it may count as owned, and the
/// printings stored on its lines of the card (A18, without nils).
nonisolated struct DeckUse: Sendable, Equatable {
    let deckID: String
    let deckName: String
    let use: Int
    let got: Int
    var missing: Int { use - got }
    let productIDs: Set<Int>
}

/// A card over the game's active decks (E2, E3).
/// - `name`: the first user deck's saved name of the card (the next user deck's when empty; the card key when none has one).
/// - `users`: the active decks with a use over 0, in deck order.
/// - `owned`: copies over all the card's printings.
/// - `answer`: the stored sharing answer (true: shared), nil when none.
/// - `sum`: the users' use summed. `need` (E2): the largest use whenever the answer is "shared", else `sum`.
///   `fromDecks`: `max(0, need − owned)`; 0 for a basic card. On a card not in conflict an answer changes `need` only:
///   `fromDecks` and every deck's `got` are the same for every answer (E3).
/// - `inConflict`: not basic, 2 or more users, `sum` over `owned`. `pending`: in conflict without an answer.
nonisolated struct CardNeed: Sendable, Equatable {
    let cardKey: String
    let name: String
    let users: [DeckUse]
    let owned: Int
    let answer: Bool?
    let isBasic: Bool
    var sum: Int
    var need: Int
    var inConflict: Bool
    var pending: Bool
    var fromDecks: Int
}

/// The maths of copies shared between active decks (E2–E4, E9, A14, A22, A23). Pure: no catalog, library, clock or file.
nonisolated enum DeckNeeds {
    /// Every card the active decks use, keyed by card key. `owned` and `isBasic` answer for any card key.
    static func needs(decks: [Deck], sharing: [String: Bool], owned: (String) -> Int,
                      isBasic: (String) -> Bool) -> [String: CardNeed] {
        struct Line { var use = 0; var name = ""; var productIDs: Set<Int> = [] }
        var order: [String] = []
        var lines: [String: [(deck: Deck, line: Line)]] = [:]
        for deck in decks where deck.active {
            var byCard: [String: Line] = [:]
            var cardOrder: [String] = []
            for card in deck.cards where card.count > 0 {
                if byCard[card.cardKey] == nil { cardOrder.append(card.cardKey) }
                var line = byCard[card.cardKey, default: Line()]
                line.use += card.count
                if line.name.isEmpty { line.name = card.name }
                if let id = card.productID { line.productIDs.insert(id) }
                byCard[card.cardKey] = line
            }
            for key in cardOrder {
                if lines[key] == nil { order.append(key) }
                lines[key, default: []].append((deck, byCard[key]!))
            }
        }
        var result: [String: CardNeed] = [:]
        for key in order {
            let entries = lines[key] ?? []
            let have = max(0, owned(key))
            let basic = isBasic(key)
            let answer = sharing[key]
            let uses = entries.map(\.line.use)
            let sum = uses.reduce(0, +)
            let inConflict = !basic && entries.count >= 2 && sum > have
            let need = answer == true ? (uses.max() ?? 0) : sum
            let gots = got(uses: uses, owned: have, shared: answer == true, isBasic: basic)
            let users = zip(entries, gots).map { entry, got in
                DeckUse(deckID: entry.deck.id, deckName: entry.deck.name, use: entry.line.use, got: got,
                        productIDs: entry.line.productIDs)
            }
            let name = entries.first(where: { !$0.line.name.isEmpty })?.line.name ?? key
            result[key] = CardNeed(cardKey: key, name: name, users: users, owned: have, answer: answer, isBasic: basic,
                                   sum: sum, need: need, inConflict: inConflict, pending: inConflict && answer == nil,
                                   fromDecks: basic ? 0 : max(0, need - have))
        }
        return result
    }

    /// What each user deck gets (E4): a basic card is never missing; shared: every deck sees all owned copies (`min(use,
    /// owned)`); else the decks are served in deck order. When the card is not in conflict both rules give each deck its
    /// whole use, so an answer there changes no number.
    private static func got(uses: [Int], owned: Int, shared: Bool, isBasic: Bool) -> [Int] {
        if isBasic { return uses }
        if shared { return uses.map { min($0, owned) } }
        var left = owned
        return uses.map { use in
            let got = min(use, left)
            left -= got
            return got
        }
    }

    /// The copies a deck may count as owned, per card key (E4): for an active deck from `needs`; for a deck that is not
    /// active, all owned copies. Only the cards the deck uses (a count over 0) are keys. An active deck that `needs` does
    /// not list as a user of a card (`needs` made from another deck list) also gets all owned copies of it.
    static func available(to deck: Deck, needs: [String: CardNeed], owned: (String) -> Int) -> [String: Int] {
        let keys = Set(deck.cards.filter { $0.count > 0 }.map(\.cardKey))
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            if deck.active, let user = needs[key]?.users.first(where: { $0.deckID == deck.id }) {
                return (key, user.got)
            }
            return (key, max(0, owned(key)))
        })
    }

    static func pendingCount(_ needs: [String: CardNeed]) -> Int {
        needs.values.filter(\.pending).count
    }

    /// The printing the decks chose (A23): the one product id over the users that miss the card, when exactly one distinct
    /// id is stored there; else nil.
    static func chosenPrinting(_ need: CardNeed) -> Int? {
        let ids = need.users.filter { $0.missing > 0 }.reduce(into: Set<Int>()) { $0.formUnion($1.productIDs) }
        return ids.count == 1 ? ids.first : nil
    }

    /// The names of the active decks whose missing count of the card goes up when `sold` copies leave the collection (E9);
    /// empty for a basic card.
    static func decksLeftShort(_ need: CardNeed, selling sold: Int) -> [String] {
        guard !need.isBasic else { return [] }
        let after = got(uses: need.users.map(\.use), owned: max(0, need.owned - max(0, sold)),
                        shared: need.answer == true, isBasic: false)
        return zip(need.users, after).compactMap { user, got in user.use - got > user.missing ? user.deckName : nil }
    }

    /// The Sold dialog's message (E9, "The look of the new parts"); nil when no deck is left short.
    static func soldMessage(decks: [String]) -> String? {
        switch decks.count {
        case 0: return nil
        case 1: return "You use this card in \(decks[0]). If you sell it the deck will miss a copy."
        case 2: return "You use this card in \(decks[0]) and \(decks[1]). If you sell it a deck will miss a copy."
        default:
            return "You use this card in \(decks[0]), \(decks[1]) and \(decks.count - 2) more. "
                + "If you sell it a deck will miss a copy."
        }
    }
}
