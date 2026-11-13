import Foundation

/// One card on the Wanted list as the screen shows it (C2, C12): the entry, the printing whose picture stands for the card,
/// the card's price and the copies the user owns of it.
/// - `shown`: the pinned printing when it is in the catalog, else the card's cheapest printing (the newest one when none
///   has a price), else nil (Review Focus 4: the card is not in the catalog, or not yet).
/// - `price`: the pinned printing's price for the pinned finish, else (that finish has no price) the pinned printing's
///   cheapest finish; without a pin in the catalog, the cheapest over the card's printings (`PriceTable.cheapest`).
/// - `owned`: the card's copies over all its collection rows. C5: it never lowers the wanted count, and the cell does not
///   show it; it is for the card page and later phases.
nonisolated struct WantedCard: Sendable, Identifiable, Equatable {
    let entry: WantedEntry
    let shown: ProductRecord?
    let price: ShownPrice?
    let owned: Int

    var id: String { entry.cardKey }

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
    /// The card keys the join looked up.
    var keys: Set<String>
    var setNames: [Int: String]
    /// The copies owned of each card of `printings` when the join ran (`WantedList.ownedByCard`): read once per join, not
    /// on every render (the screen does not show them; `WantedCard.owned`).
    var ownedByCard: [String: Int] = [:]
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
nonisolated struct WantedContent: Equatable {
    let cards: [WantedCard]
    /// True when the game's catalog is settled: only then is a card without a printing "not in the catalog any more".
    let settled: Bool
    /// One muted line above the gallery that says what the catalog cannot give; nil when it gives everything.
    let note: String?
    /// Card keys the join that made `cards` did not look up (a card added since): pending until the next join.
    let uncovered: Set<String>
    let setNames: [Int: String]

    /// The card page when the card has a printing; the page of a card that left the catalog when the catalog is settled
    /// and the join looked the card up; else nowhere (pending).
    func link(for card: WantedCard) -> WantedCellLink {
        if card.shown != nil { return .card }
        return settled && !uncovered.contains(card.id) ? .unknownCard : .none
    }

    /// The set of the pinned printing, when it is the shown one.
    func pinnedSet(of card: WantedCard) -> String? {
        guard card.showsPin, let shown = card.shown, let name = setNames[shown.groupID], !name.isEmpty else { return nil }
        return name
    }

    /// The cell's count line: `×2`, or `×1 · <set>` for a card pinned to a printing of that set.
    func countText(for card: WantedCard) -> String {
        pinnedSet(of: card).map { "×\(card.entry.count) · \($0)" } ?? "×\(card.entry.count)"
    }

    /// What VoiceOver and the UI tests read for a cell: name, count, the pinned set (when shown) and the price.
    func accessibilityText(for card: WantedCard) -> String {
        [card.name, "×\(card.entry.count)", pinnedSet(of: card) ?? "", card.price.map { CardFacts.priceText($0) } ?? "no price"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// The Wanted list: the wanted entries joined with the catalog's printings of their cards, then searched, sorted and
/// counted in memory. Pure; the view joins once per change of the list or the catalog, and lays the live list on it on
/// every render (`content`).
nonisolated enum WantedList {
    /// One card per entry, in the order of `wanted`. `price(entry, printings)` gives the price of an entry over the
    /// printings it may use: its pin's price when the entry has a pin, else the cheapest over `printings` (the view's
    /// `WantedList.price`, C12). A pin whose product is not among the card's printings is not used (the entry keeps it).
    static func cards(_ wanted: [WantedEntry], printings: [String: [ProductRecord]],
                      price: (WantedEntry, [ProductRecord]) -> ShownPrice?, ownedByCard: [String: Int]) -> [WantedCard] {
        wanted.map { entry in
            let list = printings[entry.cardKey] ?? []
            let owned = ownedByCard[entry.cardKey] ?? 0
            if let pin = entry.pin, let pinned = list.first(where: { $0.productID == pin.productID }) {
                return WantedCard(entry: entry, shown: pinned, price: price(entry, list), owned: owned)
            }
            var anyPrinting = entry
            anyPrinting.pinProductID = nil
            anyPrinting.pinFinish = nil
            let cheapest = cheapestPrinting(list) { price(anyPrinting, [$0]) }
            return WantedCard(entry: entry, shown: cheapest, price: list.isEmpty ? nil : price(anyPrinting, list), owned: owned)
        }
    }

    /// The printing with the lowest price, by the rule of `PriceTable.cheapest` (a low price counts only when no printing
    /// has a market price); the first one on a tie, and when no printing has a price (the newest: the card page's first).
    private static func cheapestPrinting(_ printings: [ProductRecord], price: (ProductRecord) -> ShownPrice?) -> ProductRecord? {
        let priced = printings.compactMap { printing in price(printing).map { (printing: printing, price: $0) } }
        let market = priced.filter { !$0.price.isLow }
        return (market.isEmpty ? priced : market).min { $0.price.amount < $1.price.amount }?.printing ?? printings.first
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

    /// Name: by card key. Price high to low and low to high: cards without a price last. Copies: the wanted count, high to
    /// low. Every tie goes by the name order.
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
            return cards.sorted { a, b in a.entry.count != b.entry.count ? a.entry.count > b.entry.count : byName(a, b) }
        }
    }

    /// `5 copies · 3 cards · $18.20`: the wanted copies, the cards and the summed price of the copies (price × count; a
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
        func copies(_ cards: [WantedCard]) -> Int { cards.reduce(0) { $0 + $1.entry.count } }
        let priced = cards.filter { $0.price != nil }
        let sum = priced.isEmpty ? nil : priced.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.entry.count) }
        let tail = CollectionList.priceTail(sum: sum, unpriced: cards.count - priced.count)
        return ([part(copies(cards), all.map(copies), "copy", "copies"), part(cards.count, all?.count, "card", "cards")]
                + [tail].compactMap { $0 }).joined(separator: " · ")
    }

    /// What Wanted lists, with the Collection's catalog states (`CollectionList.content`):
    /// - `read`: the last join that succeeded on a catalog with this game's products (nil when none did yet).
    /// - `joinFailed`: the latest join threw; what `read` holds is kept (its missing cards pending), else the cards alone.
    /// - `catalogHasProducts`: without products the cards are listed alone (saved names, no picture, no price).
    /// - `catalogSettled`: only on a settled catalog is a card without a printing "not in the catalog any more";
    ///   otherwise it is pending, with the downloading line.
    /// A card the join did not look up (added since) is pending until the next join. `owned` comes from the read.
    static func content(_ wanted: [WantedEntry], read: WantedRead?, joinFailed: Bool,
                        catalogHasProducts: Bool, catalogSettled: Bool,
                        price: (WantedEntry, [ProductRecord]) -> ShownPrice?) -> WantedContent {
        let keys = Set(wanted.map(\.cardKey))
        func listed(_ read: WantedRead?, settled: Bool, note: String?) -> WantedContent {
            return WantedContent(cards: cards(wanted, printings: read?.printings ?? [:], price: price,
                                              ownedByCard: read?.ownedByCard ?? [:]),
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
        let pending = !catalogSettled && wanted.contains { (read.printings[$0.cardKey] ?? []).isEmpty }
        return listed(read, settled: catalogSettled, note: pending ? CollectionList.catalogDownloading : nil)
    }
}
