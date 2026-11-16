import Foundation

/// One card of one section of a deck as the deck page shows it.
/// - `shown`: the printing the cell shows (A18, `DeckMaths.shownPrinting`: the stored one, else the one owned most, else the
///   cheapest); nil when the catalog has no printing of the card (D13: whether it is pending or gone is the view's
///   decision).
/// - `kind`: the card's kind; nil for a card without a printing.
/// - `owned`: the copies owned over all the card's printings; 0 for a card without a printing.
/// - `missing`: the card's missing copies in this deck that fall on this line: owned copies serve the format's earlier
///   sections first (D6). Never for a basic card or a card without a printing.
/// - `price`: the card's cheapest price over all its printings, for the totals (card-level); nil without a printing or a
///   price.
/// - `shownPrice`: the cell's price, the shown printing's own cheapest finish price (A18); nil without one.
nonisolated struct DeckLine: Sendable, Identifiable, Equatable {
    let card: DeckCard
    let shown: ProductRecord?
    let kind: CardKind?
    let isBasic: Bool
    let owned: Int
    let missing: Int
    let price: ShownPrice?
    var shownPrice: ShownPrice? = nil

    var id: String { card.id }

    /// The catalog's card name when the card has a printing, else the saved one, else the card key.
    var name: String {
        if let shown { return shown.cardName }
        return card.name.isEmpty ? card.cardKey : card.name
    }
}

/// One group of a section (Monsters, Lands, …) with its lines, by name.
nonisolated struct DeckGroup: Sendable, Identifiable, Equatable {
    let name: String
    let lines: [DeckLine]

    var id: String { name }
}

/// One section of a deck: its cards' count, its non-empty groups in the game's order, and its warning (`DeckMaths.warnings`;
/// nil when it has none).
nonisolated struct DeckSectionView: Sendable, Identifiable, Equatable {
    let section: DeckSection
    let count: Int
    let groups: [DeckGroup]
    let warning: String?

    var id: String { section.id }
}

/// A deck's maths, each deck alone (D6): the copies it uses, what the owner is missing, the size and copy warnings, the
/// totals line. Pure.
nonisolated enum DeckMaths {
    /// The copies of each card over all the deck's sections.
    static func use(_ deck: Deck) -> [String: Int] {
        deck.cards.reduce(into: [:]) { $0[$1.cardKey, default: 0] += $1.count }
    }

    /// `max(0, use − owned)`; 0 for a basic card whatever is owned (D6).
    static func missing(use: Int, owned: Int, isBasic: Bool) -> Int {
        isBasic ? 0 : max(0, use - owned)
    }

    /// True for a card whose deciding printing (`CardKinds.decidingPrinting`, the one that decides its kind) is a basic
    /// card of the game (`GameDefinition.isBasicCard`); false for a card without a printing.
    static func isBasic(game: GameDefinition, printings: [String: [ProductRecord]]) -> (String) -> Bool {
        let basics = Set(printings.compactMap { key, list in
            CardKinds.decidingPrinting(list).map { game.isBasicCard(name: $0.name, cardType: $0.cardType) } == true ? key : nil
        })
        return { basics.contains($0) }
    }

    /// The deck with each `DeckCard.key` once: a later card of the same card key and section is summed into the first,
    /// so every line id is unique and no copy counts twice.
    static func merged(_ deck: Deck) -> Deck {
        var cards: [DeckCard] = []
        var index: [DeckCardKey: Int] = [:]
        for card in deck.cards {
            if let at = index[card.key] {
                cards[at].count += card.count
            } else {
                index[card.key] = cards.count
                cards.append(card)
            }
        }
        var result = deck
        result.cards = cards
        return result
    }

    /// Every section of the format in its order, then each section id the deck uses that the format lacks (a file written
    /// elsewhere), under its id and without bounds, so no card is hidden.
    private static func shownSections(_ deck: Deck, format: DeckFormat) -> [DeckSection] {
        var sections = format.sections
        for card in deck.cards where !sections.contains(where: { $0.id == card.section }) {
            sections.append(DeckSection(id: card.section, name: card.section, min: nil, max: nil, byHandOnly: true))
        }
        return sections
    }

    /// Each line's missing copies (by `DeckCard.key`): a card's owned copies serve its lines in the order of `sections`.
    private static func missingByLine(_ deck: Deck, sections: [DeckSection], printings: [String: [ProductRecord]],
                                      ownedByCard: [String: Int], isBasic: (String) -> Bool) -> [DeckCardKey: Int] {
        var left: [String: Int] = [:]
        var result: [DeckCardKey: Int] = [:]
        for section in sections {
            for card in deck.cards where card.section == section.id {
                guard !(printings[card.cardKey] ?? []).isEmpty, !isBasic(card.cardKey) else {
                    result[card.key] = 0
                    continue
                }
                let owned = left[card.cardKey] ?? ownedByCard[card.cardKey] ?? 0
                let covered = min(max(card.count, 0), owned)
                left[card.cardKey] = owned - covered
                result[card.key, default: 0] += max(card.count, 0) - covered
            }
        }
        return result
    }

    /// The deck page's sections: every section of the format (then any the format lacks), each with its count, its lines
    /// in groups of `game.deckGroups` order (only the non-empty ones; a group the game does not name comes before Other),
    /// by name inside a group, and its warning.
    static func sections(_ deck: Deck, format: DeckFormat, game: GameDefinition, printings: [String: [ProductRecord]],
                         ownedByCard: [String: Int], ownedByPrinting: [Int: Int], isBasic: (String) -> Bool,
                         kindOf: (String) -> CardKind?, price: ([ProductRecord]) -> ShownPrice?) -> [DeckSectionView] {
        let deck = merged(deck)
        let sections = shownSections(deck, format: format)
        let missing = missingByLine(deck, sections: sections, printings: printings, ownedByCard: ownedByCard,
                                    isBasic: isBasic)
        let warnings = warnings(deck, format: format, isBasic: isBasic, nameOf: { key in
            printings[key]?.first?.cardName ?? deck.cards.first { $0.cardKey == key }?.name ?? key
        })
        let order = game.deckGroups.filter { $0 != CardKind.other }
        return sections.map { section in
            let lines = deck.cards.enumerated().filter { $0.element.section == section.id }.map { index, card in
                (index, line(card, printings: printings[card.cardKey] ?? [], owned: ownedByCard[card.cardKey] ?? 0,
                             ownedByPrinting: ownedByPrinting, missing: missing[card.key] ?? 0,
                             isBasic: isBasic(card.cardKey), kindOf: kindOf, price: price))
            }
            let byGroup = Dictionary(grouping: lines) { $0.1.kind?.group ?? CardKind.other }
            let names = order.filter { byGroup[$0] != nil }
                + byGroup.keys.filter { !order.contains($0) && $0 != CardKind.other }.sorted()
                + (byGroup[CardKind.other] == nil ? [] : [CardKind.other])
            let groups = names.map { name in
                DeckGroup(name: name, lines: byGroup[name]!.sorted(by: byName).map(\.1))
            }
            return DeckSectionView(section: section, count: deck.cards.filter { $0.section == section.id }
                                       .reduce(0) { $0 + $1.count },
                                   groups: groups, warning: warnings[section.id])
        }
    }

    private static func line(_ card: DeckCard, printings: [ProductRecord], owned: Int, ownedByPrinting: [Int: Int],
                             missing: Int, isBasic: Bool, kindOf: (String) -> CardKind?,
                             price: ([ProductRecord]) -> ShownPrice?) -> DeckLine {
        guard !printings.isEmpty else {
            return DeckLine(card: card, shown: nil, kind: nil, isBasic: isBasic, owned: 0, missing: 0, price: nil)
        }
        let shown = shownPrinting(card, printings: printings, ownedByPrinting: ownedByPrinting) { price([$0]) }
        return DeckLine(card: card, shown: shown, kind: kindOf(card.cardKey), isBasic: isBasic, owned: owned,
                        missing: missing, price: price(printings), shownPrice: shown.flatMap { price([$0]) })
    }

    /// A18: the printing a deck cell shows, of the card's `printings` (the catalog's order, newest set first):
    /// 1. the card's stored printing (`DeckCard.productID`), when it is one of them (one that left the catalog falls
    ///    through, and stays in the file);
    /// 2. else the printing owned most (`ownedByPrinting`: copies over its finishes); on a tie the cheaper
    ///    (`CollectionRules.cheapestPrinting`: market prices first), then the catalog's order;
    /// 3. else the cheapest printing (the first when none has a price). Nil without printings.
    static func shownPrinting(_ card: DeckCard, printings: [ProductRecord], ownedByPrinting: [Int: Int],
                              price: (ProductRecord) -> ShownPrice?) -> ProductRecord? {
        if let stored = card.productID, let printing = printings.first(where: { $0.productID == stored }) {
            return printing
        }
        let most = printings.map { ownedByPrinting[$0.productID] ?? 0 }.max() ?? 0
        if most > 0 {
            return CollectionRules.cheapestPrinting(printings.filter { (ownedByPrinting[$0.productID] ?? 0) == most },
                                                    price: price)
        }
        return CollectionRules.cheapestPrinting(printings, price: price)
    }

    /// Name, then card key, both ignoring case, then the deck's order.
    private static func byName(_ a: (Int, DeckLine), _ b: (Int, DeckLine)) -> Bool {
        for (x, y) in [(a.1.name, b.1.name), (a.1.card.cardKey, b.1.card.cardKey)] {
            let order = x.caseInsensitiveCompare(y)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return a.0 < b.0
    }

    /// The deck's missing copies (D6): per card with a printing that is not basic, `max(0, use − owned)`.
    static func missingCopies(_ deck: Deck, printings: [String: [ProductRecord]], ownedByCard: [String: Int],
                              isBasic: (String) -> Bool) -> Int {
        use(deck).reduce(0) { sum, item in
            guard !(printings[item.key] ?? []).isEmpty else { return sum }
            return sum + missing(use: item.value, owned: ownedByCard[item.key] ?? 0, isBasic: isBasic(item.key))
        }
    }

    /// `60 cards · 7 missing · $41.50 to complete`: the cards, the missing copies and their price (missing × the card's
    /// cheapest price; a low price counts as its amount). Cards with missing copies and no price are counted after it
    /// (`CollectionList.priceTail`): `… · $10.24 to complete + 1 without a price`, or `… · 2 without a price`. `60 cards`
    /// when nothing is missing.
    static func totals(_ sections: [DeckSectionView]) -> String {
        let cards = sections.reduce(0) { $0 + $1.count }
        let head = "\(cards) \(cards == 1 ? "card" : "cards")"
        let lines = sections.flatMap { $0.groups.flatMap(\.lines) }.filter { $0.missing > 0 }
        let missing = lines.reduce(0) { $0 + $1.missing }
        guard missing > 0 else { return head }
        let priced = lines.filter { $0.price != nil }
        let sum = priced.isEmpty ? nil : priced.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.missing) }
        let unpriced = Set(lines.filter { $0.price == nil }.map(\.card.cardKey)).count
        let money = CollectionList.priceTail(sum: sum, unpriced: 0).map { "\($0) to complete" }
        let tail = [money, CollectionList.priceTail(sum: nil, unpriced: unpriced)].compactMap { $0 }.joined(separator: " + ")
        return [head, "\(missing) missing", tail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The warning of a count that breaks its bound says which way (final fix B2). With `sizes` (E10, the allowed sizes:
    /// Cyberpunk's Side Deck 0 or 7), only they decide and `min` / `max` are not read: a count over the largest says `at
    /// most 7 cards`, any other count not in the list `needs 0 or 7 cards`. Else, under a minimum: `needs 40–60 cards`,
    /// `needs at least 40 cards`, `needs 1 card`, `needs 100 cards`; over a maximum: `at most 60 cards`, `at most 1 card`
    /// (also for an exact size or a range). Nil when the count breaks no bound.
    private static func boundText(count: Int, min: Int?, max: Int?, sizes: [Int] = []) -> String? {
        func cards(_ n: Int) -> String { n == 1 ? "1 card" : "\(n) cards" }
        if let largest = sizes.max() {
            guard !sizes.contains(count) else { return nil }
            return count > largest ? "at most \(cards(largest))" : "needs \(sizes.sorted().map(String.init).joined(separator: " or ")) cards"
        }
        if let max, count > max { return "at most \(cards(max))" }
        guard let min, count < min else { return nil }
        switch max {
        case min?: return "needs \(cards(min))"
        case let high?: return "needs \(min)–\(high) cards"
        case nil: return "needs at least \(cards(min))"
        }
    }

    /// Section id → warning text (rule checks warn, never block). On one section, in this order, joined by " · ":
    /// - its own bound (`min`, `max`, or its `sizes`: `boundText`), when its count breaks it;
    /// - each total (`DeckFormat.totals`) that the count of its sections breaks, on the last of its sections the format
    ///   has, prefixed by the total's name when it differs from that section's (`Commander deck: needs 100 cards`);
    /// - the section's own `maxCopies` (E10: copies of one card inside this section alone; Cyberpunk's Legends, 1):
    ///   `more than 1 copy: Alt`, the cards over it by name (basics exempt);
    /// - the copy limit (when the format has one): `more than 3 copies: A, B, C and 2 more`, the cards over the limit by
    ///   name (basics exempt). A card's copies count over the format's counted sections together plus every section the
    ///   format does not know (a section from elsewhere has no size bound and no total, but the limit is per card). The
    ///   warning stands on the first section, in the order of the deck page, that holds a card over the limit.
    /// Two deck cards with one id count as one (`merged`).
    static func warnings(_ deck: Deck, format: DeckFormat, isBasic: (String) -> Bool,
                         nameOf: (String) -> String) -> [String: String] {
        let deck = merged(deck)
        func count(_ ids: [String]) -> Int { deck.cards.filter { ids.contains($0.section) }.reduce(0) { $0 + $1.count } }
        var texts: [String: [String]] = [:]
        for section in format.sections {
            if let text = boundText(count: count([section.id]), min: section.min, max: section.max,
                                  sizes: section.sizes) {
                texts[section.id, default: []].append(text)
            }
        }
        for total in format.totals {
            guard let last = total.sections.last(where: { format.section($0) != nil }).flatMap(format.section),
                  let text = boundText(count: count(total.sections), min: total.min, max: total.max) else { continue }
            texts[last.id, default: []].append(total.name == last.name ? text : "\(total.name): \(text)")
        }
        func named(_ keys: Set<String>) -> String {
            let over = keys.map(nameOf).sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            return over.prefix(3).joined(separator: ", ") + (over.count > 3 ? " and \(over.count - 3) more" : "")
        }
        func copyText(_ limit: Int, _ keys: Set<String>) -> String {
            "more than \(limit) \(limit == 1 ? "copy" : "copies"): \(named(keys))"
        }
        for section in format.sections {
            guard let limit = section.maxCopies else { continue }
            let copies = deck.cards.filter { $0.section == section.id }
                .reduce(into: [String: Int]()) { $0[$1.cardKey, default: 0] += $1.count }
            let over = Set(copies.filter { $0.value > limit && !isBasic($0.key) }.keys)
            if !over.isEmpty { texts[section.id, default: []].append(copyText(limit, over)) }
        }
        if let limit = format.copyLimit {
            let counted = deck.cards.filter { format.countedSections.contains($0.section) || format.section($0.section) == nil }
            let copies = counted.reduce(into: [String: Int]()) { $0[$1.cardKey, default: 0] += $1.count }
            let overKeys = Set(copies.filter { $0.value > limit && !isBasic($0.key) }.keys)
            let holders = Set(counted.filter { overKeys.contains($0.cardKey) && $0.count > 0 }.map(\.section))
            if !overKeys.isEmpty, let first = shownSections(deck, format: format).first(where: { holders.contains($0.id) })?.id {
                texts[first, default: []].append(copyText(limit, overKeys))
            }
        }
        return texts.mapValues { $0.joined(separator: " · ") }
    }
}
