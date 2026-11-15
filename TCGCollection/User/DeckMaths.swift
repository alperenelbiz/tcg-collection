import Foundation

/// One card of one section of a deck as the deck page shows it.
/// - `shown`: the card's cheapest printing (market prices first; the first printing when none has a price); nil when the
///   catalog has no printing of the card (D13: whether it is pending or gone is the view's decision).
/// - `kind`: the card's kind; nil for a card without a printing.
/// - `owned`: the copies owned over all the card's printings; 0 for a card without a printing.
/// - `missing`: the card's missing copies in this deck that fall on this line: owned copies serve the format's earlier
///   sections first (D6). Never for a basic card or a card without a printing.
/// - `price`: the card's cheapest price; nil without a printing or a price.
nonisolated struct DeckLine: Sendable, Identifiable, Equatable {
    let card: DeckCard
    let shown: ProductRecord?
    let kind: CardKind?
    let isBasic: Bool
    let owned: Int
    let missing: Int
    let price: ShownPrice?

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

    /// True for a card whose first printing is a basic card of the game (`GameDefinition.isBasicCard`); false for a card
    /// without a printing.
    static func isBasic(game: GameDefinition, printings: [String: [ProductRecord]]) -> (String) -> Bool {
        let basics = Set(printings.compactMap { key, list in
            list.first.map { game.isBasicCard(name: $0.name, cardType: $0.cardType) } == true ? key : nil
        })
        return { basics.contains($0) }
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

    /// Each line's missing copies (by `DeckCard.id`): a card's owned copies serve its lines in the order of `sections`.
    private static func missingByLine(_ deck: Deck, sections: [DeckSection], printings: [String: [ProductRecord]],
                                      ownedByCard: [String: Int], isBasic: (String) -> Bool) -> [String: Int] {
        var left: [String: Int] = [:]
        var result: [String: Int] = [:]
        for section in sections {
            for card in deck.cards where card.section == section.id {
                guard !(printings[card.cardKey] ?? []).isEmpty, !isBasic(card.cardKey) else {
                    result[card.id] = 0
                    continue
                }
                let owned = left[card.cardKey] ?? ownedByCard[card.cardKey] ?? 0
                let covered = min(max(card.count, 0), owned)
                left[card.cardKey] = owned - covered
                result[card.id, default: 0] += max(card.count, 0) - covered
            }
        }
        return result
    }

    /// The deck page's sections: every section of the format (then any the format lacks), each with its count, its lines
    /// in groups of `game.deckGroups` order (only the non-empty ones; a group the game does not name comes before Other),
    /// by name inside a group, and its warning.
    static func sections(_ deck: Deck, format: DeckFormat, game: GameDefinition, printings: [String: [ProductRecord]],
                         ownedByCard: [String: Int], isBasic: (String) -> Bool, kindOf: (String) -> CardKind?,
                         price: ([ProductRecord]) -> ShownPrice?) -> [DeckSectionView] {
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
                             missing: missing[card.id] ?? 0, isBasic: isBasic(card.cardKey), kindOf: kindOf,
                             price: price))
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

    private static func line(_ card: DeckCard, printings: [ProductRecord], owned: Int, missing: Int, isBasic: Bool,
                             kindOf: (String) -> CardKind?, price: ([ProductRecord]) -> ShownPrice?) -> DeckLine {
        guard !printings.isEmpty else {
            return DeckLine(card: card, shown: nil, kind: nil, isBasic: isBasic, owned: 0, missing: 0, price: nil)
        }
        return DeckLine(card: card, shown: cheapestPrinting(printings, price: price), kind: kindOf(card.cardKey),
                        isBasic: isBasic, owned: owned, missing: missing, price: price(printings))
    }

    /// Name, then card key, both ignoring case, then the deck's order.
    private static func byName(_ a: (Int, DeckLine), _ b: (Int, DeckLine)) -> Bool {
        for (x, y) in [(a.1.name, b.1.name), (a.1.card.cardKey, b.1.card.cardKey)] {
            let order = x.caseInsensitiveCompare(y)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return a.0 < b.0
    }

    /// The printing with the lowest price; a low price counts only when no printing has a market price; the first printing
    /// on a tie and when none has a price.
    private static func cheapestPrinting(_ printings: [ProductRecord],
                                         price: ([ProductRecord]) -> ShownPrice?) -> ProductRecord? {
        let priced = printings.compactMap { printing in price([printing]).map { (printing: printing, price: $0) } }
        let market = priced.filter { !$0.price.isLow }
        return (market.isEmpty ? priced : market).min { $0.price.amount < $1.price.amount }?.printing ?? printings.first
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

    /// `40–60 cards`, `at least 40 cards`, `at most 15 cards`, `1 card`, `100 cards`; nil without a bound.
    private static func boundText(min: Int?, max: Int?) -> String? {
        func cards(_ n: Int) -> String { n == 1 ? "1 card" : "\(n) cards" }
        switch (min, max) {
        case let (low?, high?) where low == high: return cards(low)
        case let (low?, high?): return "\(low)–\(high) cards"
        case let (low?, nil): return "at least \(cards(low))"
        case let (nil, high?): return "at most \(cards(high))"
        case (nil, nil): return nil
        }
    }

    private static func breaks(_ count: Int, min: Int?, max: Int?) -> Bool {
        if let min, count < min { return true }
        if let max, count > max { return true }
        return false
    }

    /// Section id → warning text (rule checks warn, never block). On one section, in this order, joined by " · ":
    /// - its own bound, when its count breaks it;
    /// - each total (`DeckFormat.totals`) that the count of its sections breaks, on the last of its sections the format
    ///   has, prefixed by the total's name when it differs from that section's (`Commander deck: 100 cards`);
    /// - the copy limit, on the first counted section the format has: `more than 3 copies: A, B, C and 2 more`, the cards
    ///   over the limit by name (basics exempt), over the counted sections together.
    static func warnings(_ deck: Deck, format: DeckFormat, isBasic: (String) -> Bool,
                         nameOf: (String) -> String) -> [String: String] {
        func count(_ ids: [String]) -> Int { deck.cards.filter { ids.contains($0.section) }.reduce(0) { $0 + $1.count } }
        var texts: [String: [String]] = [:]
        for section in format.sections where breaks(count([section.id]), min: section.min, max: section.max) {
            if let text = boundText(min: section.min, max: section.max) { texts[section.id, default: []].append(text) }
        }
        for total in format.totals {
            guard let last = total.sections.last(where: { format.section($0) != nil }).flatMap(format.section),
                  breaks(count(total.sections), min: total.min, max: total.max),
                  let text = boundText(min: total.min, max: total.max) else { continue }
            texts[last.id, default: []].append(total.name == last.name ? text : "\(total.name): \(text)")
        }
        if let limit = format.copyLimit,
           let first = format.countedSections.first(where: { format.section($0) != nil }) {
            let counted = deck.cards.filter { format.countedSections.contains($0.section) }
            let copies = counted.reduce(into: [String: Int]()) { $0[$1.cardKey, default: 0] += $1.count }
            let over = copies.filter { $0.value > limit && !isBasic($0.key) }.keys.map(nameOf)
                .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            if !over.isEmpty {
                let named = over.prefix(3).joined(separator: ", ") + (over.count > 3 ? " and \(over.count - 3) more" : "")
                texts[first, default: []].append("more than \(limit) \(limit == 1 ? "copy" : "copies"): \(named)")
            }
        }
        return texts.mapValues { $0.joined(separator: " · ") }
    }
}
