import Foundation

/// One card on the Wanted list as the screen shows it (C2, C12, E5): the hand-added entry, the copies the active decks
/// miss, the printing whose picture stands for the card, the card's price and the copies the user owns of it.
/// - `entry`: the hand-added entry; for a card only from decks one made in memory (count 0, the deck card's saved name, no
///   pin) that is never written (E5).
/// - `forDecks`: the copies the active decks miss (`CardNeed.fromDecks`); `total` = `entry.count + forDecks` (A17).
/// - `pending`: the card's sharing question has no answer (E3); `users`: the active decks that use it (`CardNeed.users`).
/// - `shown` (A23): the pinned printing when it is in the catalog; else the printing the decks that miss the card chose
///   (`DeckNeeds.chosenPrinting`), when it is in the catalog; else the card's cheapest printing (the newest one when none
///   has a price); else nil (Review Focus 4: the card is not in the catalog, or not yet).
/// - `price`: the pinned printing's price for the pinned finish, else (that finish has no price) the pinned printing's
///   cheapest finish; the decks' printing: its own cheapest finish; else the cheapest over the card's printings
///   (`PriceTable.cheapest`).
/// - `owned`: the card's copies over all its collection rows. C5: it never lowers the hand-added count, and the cell does
///   not show it.
nonisolated struct WantedCard: Sendable, Identifiable, Equatable {
    let entry: WantedEntry
    let shown: ProductRecord?
    let price: ShownPrice?
    let owned: Int
    var forDecks: Int = 0
    var pending: Bool = false
    var users: [DeckUse] = []

    var id: String { entry.cardKey }

    /// The copies on the list: the hand-added ones and the decks' (A24: the cell shows this; its control the first part).
    var total: Int { entry.count + forDecks }

    /// The card's name: the catalog's when it has a printing, else the saved one, else the card key.
    var name: String {
        if let shown { return shown.cardName }
        return entry.name.isEmpty ? entry.cardKey : entry.name
    }

    /// True when the shown printing is the pinned one (a pin whose product left the catalog falls back and is not shown).
    var showsPin: Bool {
        guard let pin = entry.pin, let shown else { return false }
        return shown.productID == pin.productID
    }
}

/// What a join of the Wanted list with the catalog read (`WantedJoin`).
nonisolated struct WantedRead: Sendable, Equatable {
    /// Each card key's printings, newest set first; a key the catalog has no product of the game for is not in it.
    var printings: [String: [ProductRecord]]
    /// The card keys the join looked up: the hand-added ones and every card key of the active decks
    /// (`WantedList.joinKeys`).
    var keys: Set<String>
    var setNames: [Int: String]
    /// The copies owned of each card of `printings` when the join ran (`WantedList.ownedByCard`): read once per join, not
    /// on every render (`WantedCard.owned`, and the decks' needs: E2).
    var ownedByCard: [String: Int] = [:]
    /// The keys of the basic cards among `printings` (`DeckMaths.isBasic`, the deciding printing): never on Wanted from a
    /// deck.
    var basics: Set<String> = []
}

/// Where a Wanted cell opens (`WantedContent.link(for:)`).
nonisolated enum WantedCellLink: Equatable, Sendable {
    /// The card page, on the shown printing.
    case card
    /// The page of a card that is not in the catalog any more (its saved name and its count).
    case unknownCard
    /// Pending: the catalog cannot say yet what this card is.
    case none
}

/// What Wanted lists, given the state of the catalog (`WantedList.content`), as `CollectionContent` is for the Collection.
/// A card the decks use that the last join did not look up is not in `cards` at all until a join covers it: its owned
/// copies are not known, so a "for decks" count would be false. A hand-added card the join did not look up is listed and
/// pending (`uncovered`), with no decks' part.
nonisolated struct WantedContent: Equatable {
    let cards: [WantedCard]
    /// True when the game's catalog is settled: only then is a card without a printing "not in the catalog any more".
    let settled: Bool
    /// One muted line above the gallery that says what the catalog cannot give; nil when it gives everything.
    let note: String?
    /// Card keys the join that made `cards` did not look up (a card added since): pending until the next join.
    let uncovered: Set<String>
    let setNames: [Int: String]

    /// The card page when the card has a printing; the page of a card that left the catalog when the catalog is settled,
    /// the join looked the card up and it has a hand-added entry; else nowhere (pending, or a card only from decks that is
    /// not in the catalog: Review Focus 3, its page would have no entry to show).
    func link(for card: WantedCard) -> WantedCellLink {
        if card.shown != nil { return .card }
        return settled && !uncovered.contains(card.id) && card.entry.count > 0 ? .unknownCard : .none
    }

    /// The set of the pinned printing, when it is the shown one.
    func pinnedSet(of card: WantedCard) -> String? {
        guard card.showsPin, let shown = card.shown, let name = setNames[shown.groupID], !name.isEmpty else { return nil }
        return name
    }

    /// The cell's count line: `×<total>[ · <n> for decks][ · <set>]`: `×2`, `×3 · 2 for decks`, `×1 · <set>` for a card
    /// pinned to a printing of that set.
    func countText(for card: WantedCard) -> String {
        (["×\(card.total)", Self.decksText(card) ?? ""] + [pinnedSet(of: card) ?? ""]).filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// What VoiceOver and the UI tests read for a cell: name, the total, the decks' part, the pinned set (when shown) and
    /// the price: `Twin, ×3, 2 for decks, $1.50`.
    func accessibilityText(for card: WantedCard) -> String {
        [card.name, "×\(card.total)", Self.decksText(card) ?? "", pinnedSet(of: card) ?? "",
         card.price.map { CardFacts.priceText($0) } ?? "no price"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// `<n> for decks`, nil when the decks miss none.
    private static func decksText(_ card: WantedCard) -> String? {
        card.forDecks > 0 ? "\(card.forDecks) for decks" : nil
    }
}

/// The Wanted list: the wanted entries joined with the catalog's printings of their cards, then searched, sorted and
/// counted in memory. Pure; the view joins once per change of the list or the catalog, and lays the live list on it on
/// every render (`content`).
nonisolated enum WantedList {
    /// The union of the hand-added entries and the cards the active decks miss (E5): first one card per entry, in the order
    /// of `wanted`, then one per card of `needs` with `fromDecks` over 0 that has no entry, by card key. A card only from
    /// decks gets an entry made in memory (count 0, the deck card's saved name, no pin), never written. `price(entry,
    /// printings)` gives the price of an entry over the printings it may use: its pin's price when the entry has a pin,
    /// else the cheapest over `printings` (the view's `WantedList.price`, C12). A pin whose product is not among the card's
    /// printings is not used (the entry keeps it). The shown printing is A23's (`WantedCard`).
    static func cards(_ wanted: [WantedEntry], needs: [String: CardNeed], printings: [String: [ProductRecord]],
                      ownedByCard: [String: Int], price: (WantedEntry, [ProductRecord]) -> ShownPrice?) -> [WantedCard] {
        let hand = Set(wanted.map(\.cardKey))
        let fromDecks = needs.values.filter { $0.fromDecks > 0 && !hand.contains($0.cardKey) }
            .sorted { $0.cardKey < $1.cardKey }
            .map { WantedEntry(cardKey: $0.cardKey, name: $0.name, count: 0) }
        return (wanted + fromDecks).map { entry in
            let list = printings[entry.cardKey] ?? []
            let owned = ownedByCard[entry.cardKey] ?? 0
            let need = needs[entry.cardKey]
            func card(_ shown: ProductRecord?, _ price: ShownPrice?) -> WantedCard {
                WantedCard(entry: entry, shown: shown, price: price, owned: owned, forDecks: need?.fromDecks ?? 0,
                           pending: need?.pending ?? false, users: need?.users ?? [])
            }
            if let pin = entry.pin, let pinned = list.first(where: { $0.productID == pin.productID }) {
                return card(pinned, price(entry, list))
            }
            var anyPrinting = entry
            anyPrinting.pinProductID = nil
            anyPrinting.pinFinish = nil
            if let need, need.fromDecks > 0, let chosen = DeckNeeds.chosenPrinting(need),
               let printing = list.first(where: { $0.productID == chosen }) {
                return card(printing, price(anyPrinting, [printing]))
            }
            let cheapest = CollectionRules.cheapestPrinting(list) { price(anyPrinting, [$0]) }
            return card(cheapest, list.isEmpty ? nil : price(anyPrinting, list))
        }
    }

    /// The card keys a join looks up: the hand-added ones and every card key the active decks use (a count over 0).
    static func joinKeys(wanted: [WantedEntry], decks: [Deck]) -> Set<String> {
        Set(wanted.map(\.cardKey))
            .union(decks.filter(\.active).flatMap { $0.cards.filter { $0.count > 0 }.map(\.cardKey) })
    }

    /// The read of a join: `printings` as the store gave them for `keys`, the set names, the copies owned per card over
    /// `rows` and the basic cards (the deciding printing, as on a deck page).
    static func read(game: GameDefinition, printings: [String: [ProductRecord]], keys: Set<String>, rows: [CollectionRow],
                     setNames: [Int: String]) -> WantedRead {
        let isBasic = DeckMaths.isBasic(game: game, printings: printings)
        return WantedRead(printings: printings, keys: keys, setNames: setNames,
                          ownedByCard: ownedByCard(rows: rows, printings: printings),
                          basics: Set(printings.keys.filter(isBasic)))
    }

    /// The active decks' needs (E2–E4) on a read: its owned copies and basic cards; only the cards the read looked up (a
    /// card it did not has no known owned count). No read: none.
    static func needs(decks: [Deck], sharing: [String: Bool], read: WantedRead?) -> [String: CardNeed] {
        guard let read else { return [:] }
        let owned = read.ownedByCard, basics = read.basics
        return DeckNeeds.needs(decks: decks, sharing: sharing, owned: { owned[$0] ?? 0 }, isBasic: { basics.contains($0) })
            .filter { read.keys.contains($0.key) }
    }

    /// The copies of one card the active decks miss (`CardNeed.fromDecks`), for a card page: `owned` and `isBasic` are the
    /// page's own for that card.
    static func forDecks(_ cardKey: String, decks: [Deck], sharing: [String: Bool], owned: Int, isBasic: Bool) -> Int {
        DeckNeeds.needs(decks: decks, sharing: sharing, owned: { $0 == cardKey ? owned : 0 },
                        isBasic: { $0 == cardKey && isBasic })[cardKey]?.fromDecks ?? 0
    }

    /// The copies owned of each card of `printings`, over every printing and finish (`CollectionRules.copiesPerCard`). A
    /// row of a product that is not among them does not count.
    static func ownedByCard(rows: [CollectionRow], printings: [String: [ProductRecord]]) -> [String: Int] {
        var cardOf: [Int: String] = [:]
        for (key, list) in printings {
            for printing in list { cardOf[printing.productID] = key }
        }
        return CollectionRules.copiesPerCard(rows) { cardOf[$0] }
    }

    /// The cards whose key (the folded card name), or for a card without a printing whose folded saved name, holds every
    /// folded word of `text` (the catalog search's rule), in their order.
    static func filtered(_ cards: [WantedCard], text: String) -> [WantedCard] {
        let words = CardName.searchKey(text).split(separator: " ")
        guard !words.isEmpty else { return cards }
        return cards.filter { card in
            let key = card.shown?.searchKey ?? CardName.searchKey(card.name)
            return words.allSatisfy { key.contains($0) }
        }
    }

    /// Name: by card key. Price high to low and low to high: cards without a price last. Copies: the total (hand-added and
    /// for decks), high to low. Every tie goes by the name order.
    static func sorted(_ cards: [WantedCard], by sort: CollectionSort) -> [WantedCard] {
        func byName(_ a: WantedCard, _ b: WantedCard) -> Bool { a.entry.cardKey < b.entry.cardKey }
        switch sort {
        case .name:
            return cards.sorted(by: byName)
        case .priceHigh, .priceLow:
            let high = sort == .priceHigh
            return cards.sorted { a, b in
                switch (a.price?.amount, b.price?.amount) {
                case let (x?, y?) where x != y: return high ? x > y : x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        case .count:
            return cards.sorted { a, b in a.total != b.total ? a.total > b.total : byName(a, b) }
        }
    }

    /// `5 copies · 3 cards · $18.20`: the wanted copies (each card's total), the cards and the summed price (price × total; a
    /// low price counts as its amount). Cards without a price are left out of the sum and counted after it, as on For
    /// Sale: `… · $8.00 + 1 without a price`, or `… · 2 without a price` with no priced card. With `all` (the search text is
    /// on), the shown part of the whole: `2 of 3 copies · 1 of 2 cards · $8.00`; the sum is of the shown cards. "" for an
    /// empty list.
    static func totals(_ cards: [WantedCard], of all: [WantedCard]? = nil) -> String {
        guard !(all ?? cards).isEmpty else { return "" }
        func part(_ shown: Int, _ whole: Int?, _ one: String, _ many: String) -> String {
            guard let whole else { return "\(shown) \(shown == 1 ? one : many)" }
            return "\(shown) of \(whole) \(whole == 1 ? one : many)"
        }
        func copies(_ cards: [WantedCard]) -> Int { cards.reduce(0) { $0 + $1.total } }
        let priced = cards.filter { $0.price != nil }
        let sum = priced.isEmpty ? nil : priced.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.total) }
        let tail = CollectionList.priceTail(sum: sum, unpriced: cards.count - priced.count)
        return ([part(copies(cards), all.map(copies), "copy", "copies"), part(cards.count, all?.count, "card", "cards")]
                + [tail].compactMap { $0 }).joined(separator: " · ")
    }

    /// What Wanted lists, with the Collection's catalog states (`CollectionList.content`):
    /// - `read`: the last join that succeeded on a catalog with this game's products (nil when none did yet).
    /// - `joinFailed`: the latest join threw; what `read` holds is kept (its missing cards pending), else the cards alone.
    /// - `catalogHasProducts`: without products the hand-added cards are listed alone (saved names, no picture, no price).
    /// - `catalogSettled`: only on a settled catalog is a card without a printing "not in the catalog any more";
    ///   otherwise it is pending, with the downloading line.
    /// - `decks`, `sharing`: the game's decks and sharing answers in memory; the active decks' needs (`needs`) are made on
    ///   every render from them and the read, and their missing cards join the list (E5). A deck card the read did not look
    ///   up is left out until a join covers it; with no read no deck card is listed.
    /// A hand-added card the join did not look up (added since) is pending until the next join. `owned` comes from the read.
    static func content(_ wanted: [WantedEntry], decks: [Deck], sharing: [String: Bool], read: WantedRead?,
                        joinFailed: Bool, catalogHasProducts: Bool, catalogSettled: Bool,
                        price: (WantedEntry, [ProductRecord]) -> ShownPrice?) -> WantedContent {
        let keys = Set(wanted.map(\.cardKey))
        func listed(_ read: WantedRead?, settled: Bool, note: String?) -> WantedContent {
            return WantedContent(cards: cards(wanted, needs: needs(decks: decks, sharing: sharing, read: read),
                                              printings: read?.printings ?? [:], ownedByCard: read?.ownedByCard ?? [:],
                                              price: price),
                                 settled: settled, note: note, uncovered: keys.subtracting(read?.keys ?? []),
                                 setNames: read?.setNames ?? [:])
        }
        if joinFailed {
            return read == nil ? listed(nil, settled: false, note: CollectionList.catalogUnreadable)
                : listed(read, settled: false, note: CollectionList.catalogUnreadableKept)
        }
        guard catalogHasProducts, let read else {
            let note = catalogSettled ? CollectionList.catalogEmpty : CollectionList.catalogDownloading
            return listed(nil, settled: false, note: note)
        }
        let all = listed(read, settled: catalogSettled, note: nil)
        guard !catalogSettled, all.cards.contains(where: { (read.printings[$0.id] ?? []).isEmpty }) else { return all }
        return WantedContent(cards: all.cards, settled: all.settled, note: CollectionList.catalogDownloading,
                             uncovered: all.uncovered, setNames: all.setNames)
    }
}
