import Testing
@testable import TCGCollection2

@MainActor
struct DeckMathsTests {
    private let yugioh = Games.game("yu-gi-oh")!
    private let magic = Games.game("magic-the-gathering")!
    private let riftbound = Games.game("riftbound")!
    private let cyberpunk = Games.game("cyberpunk")!

    private func card(_ key: String, _ section: String, _ count: Int, name: String? = nil) -> DeckCard {
        DeckCard(cardKey: key, name: name ?? key, section: section, count: count)
    }

    private func deck(_ cards: [DeckCard], format: String = "standard") -> Deck {
        Deck(id: "d1", name: "Deck", format: format, active: true, cards: cards)
    }

    private func notBasic(_ key: String) -> Bool { false }

    private func sections(_ deck: Deck, game: GameDefinition, printings: [String: [ProductRecord]],
                          owned: [String: Int] = [:], isBasic: (String) -> Bool = { _ in false },
                          kinds: [String: CardKind] = [:],
                          prices: [Int: ShownPrice] = [:]) -> [DeckSectionView] {
        DeckMaths.sections(deck, format: game.format(deck.format), game: game, printings: printings,
                           ownedByCard: owned, isBasic: isBasic, kindOf: { kinds[$0] },
                           price: { list in
                               let shown = list.compactMap { prices[$0.productID] }
                               return shown.filter { !$0.isLow }.min { $0.amount < $1.amount }
                                   ?? shown.min { $0.amount < $1.amount }
                           })
    }

    private func lines(_ view: DeckSectionView?) -> [DeckLine] { view?.groups.flatMap(\.lines) ?? [] }

    // MARK: use and missing

    @Test func useSumsACardOverMainAndSide() {
        let use = DeckMaths.use(deck([card("ash", "main", 3), card("ash", "side", 1), card("pot", "main", 2)]))
        #expect(use == ["ash": 4, "pot": 2])
    }

    @Test func missingIsUseLessOwnedAndNeverForABasicCard() {
        #expect(DeckMaths.missing(use: 4, owned: 1, isBasic: false) == 3)
        #expect(DeckMaths.missing(use: 2, owned: 5, isBasic: false) == 0)
        #expect(DeckMaths.missing(use: 2, owned: 2, isBasic: false) == 0)
        #expect(DeckMaths.missing(use: 20, owned: 0, isBasic: true) == 0)
        #expect(DeckMaths.missing(use: 20, owned: 3, isBasic: true) == 0)
    }

    /// The copies owned of a card come over all its printings (the read's `ownedByCard`).
    @Test func aCardOwnedOverTwoPrintingsCountsBoth() {
        let printings = ["twin": [product(id: 1, game: "yu-gi-oh", name: "Twin"),
                                  product(id: 2, game: "yu-gi-oh", name: "Twin")]]
        let rows = [CollectionRow(productID: 1, finish: "1st Edition", count: 1, condition: "", name: "Twin"),
                    CollectionRow(productID: 2, finish: "Unlimited", count: 1, condition: "", name: "Twin")]
        let owned = WantedList.ownedByCard(rows: rows, printings: printings)
        let view = sections(deck([card("twin", "main", 3)]), game: yugioh, printings: printings, owned: owned)
        let line = try? #require(lines(view.first).first)
        #expect(line?.owned == 2)
        #expect(line?.missing == 1)
        #expect(DeckMaths.missingCopies(deck([card("twin", "main", 3)]), printings: printings, ownedByCard: owned,
                                        isBasic: notBasic) == 1)
    }

    /// 3 in Main and 1 in Side, 2 owned: the owned copies serve Main first (the format's order, not the file's), so Main
    /// misses its third copy and Side its one.
    @Test func missingCopiesGoToTheLinesInSectionOrder() {
        let printings = ["ash": [product(id: 5, game: "yu-gi-oh", name: "Ash Blossom")]]
        let theDeck = deck([card("ash", "side", 1), card("ash", "main", 3)])
        let view = sections(theDeck, game: yugioh, printings: printings, owned: ["ash": 2])
        #expect(view.map(\.section.id) == ["main", "extra", "side"])
        #expect(lines(view[0]).map(\.missing) == [1])
        #expect(lines(view[2]).map(\.missing) == [1])
        #expect(lines(view[0]).map(\.owned) == [2])
        #expect(DeckMaths.missingCopies(theDeck, printings: printings, ownedByCard: ["ash": 2], isBasic: notBasic) == 2)
    }

    @Test func aBasicCardIsNeverMissing() {
        let printings = ["plains": [product(id: 9, game: "magic-the-gathering", name: "Plains",
                                            cardType: "Basic Land — Plains")]]
        let isBasic = DeckMaths.isBasic(game: magic, printings: printings)
        #expect(isBasic("plains"))
        let theDeck = deck([card("plains", "deck", 20)], format: "constructed")
        let view = sections(theDeck, game: magic, printings: printings, isBasic: isBasic)
        #expect(lines(view[0]).first?.missing == 0)
        #expect(lines(view[0]).first?.isBasic == true)
        #expect(DeckMaths.missingCopies(theDeck, printings: printings, ownedByCard: [:], isBasic: isBasic) == 0)
    }

    /// Final fix B6: one basic rule with the kind: the deciding printing (`CardKinds.decidingPrinting`, the first with a
    /// card type) says whether a card is basic, not the first printing.
    @Test func theDecidingPrintingSaysWhetherACardIsBasic() {
        let untyped = product(id: 10, game: "magic-the-gathering", name: "Plains Promo Sheet")
        let typed = product(id: 11, game: "magic-the-gathering", name: "Plains", cardType: "Basic Land — Plains")
        #expect(DeckMaths.isBasic(game: magic, printings: ["plains": [untyped, typed]])("plains"))
        let bear = product(id: 12, game: "magic-the-gathering", name: "Bear", cardType: "Creature — Bear")
        let island = product(id: 13, game: "magic-the-gathering", name: "Island")
        #expect(!DeckMaths.isBasic(game: magic, printings: ["bear": [island, bear]])("bear"))
    }

    // MARK: sections and groups

    @Test func everySectionOfTheFormatIsListedWithItsCount() {
        let printings = ["a": [product(id: 1, game: "yu-gi-oh", name: "A")]]
        let view = sections(deck([card("a", "main", 3), card("a", "side", 2)]), game: yugioh, printings: printings)
        #expect(view.map(\.section.id) == ["main", "extra", "side"])
        #expect(view.map(\.count) == [3, 0, 2])
        #expect(view[1].groups.isEmpty)
    }

    /// Groups in `deckGroups` order, only the non-empty ones, cards by name inside a group (case-insensitive).
    @Test func groupsFollowTheGameOrderAndCardsTheirNames() {
        let printings = ["beta": [product(id: 1, game: "yu-gi-oh", name: "beta")],
                         "alpha": [product(id: 2, game: "yu-gi-oh", name: "Alpha")],
                         "trap": [product(id: 3, game: "yu-gi-oh", name: "Trap Hole")]]
        let kinds = ["beta": CardKind(group: "Monsters", flags: []), "alpha": CardKind(group: "Monsters", flags: []),
                     "trap": CardKind(group: "Traps", flags: [])]
        let view = sections(deck([card("trap", "main", 1), card("beta", "main", 1), card("alpha", "main", 1)]),
                            game: yugioh, printings: printings, kinds: kinds)
        #expect(view[0].groups.map(\.name) == ["Monsters", "Traps"])
        #expect(view[0].groups[0].lines.map(\.card.cardKey) == ["alpha", "beta"])
        #expect(view[0].groups[0].lines[0].kind == CardKind(group: "Monsters", flags: []))
    }

    /// D13: a card the catalog has no printing of stays, with no picture, no kind, in Other, never missing.
    @Test func aCardNotInTheCatalogIsListedInOtherAndNotMissing() {
        let printings = ["alpha": [product(id: 2, game: "yu-gi-oh", name: "Alpha")]]
        let theDeck = deck([card("gone", "main", 3, name: "Gone Card"), card("alpha", "main", 1)])
        let view = sections(theDeck, game: yugioh, printings: printings, owned: ["gone": 5],
                            kinds: ["alpha": CardKind(group: "Monsters", flags: [])])
        #expect(view[0].groups.map(\.name) == ["Monsters", CardKind.other])
        let line = try? #require(view[0].groups.last?.lines.first)
        #expect(line?.card.name == "Gone Card")
        #expect(line?.shown == nil)
        #expect(line?.kind == nil)
        #expect(line?.missing == 0)
        #expect(line?.owned == 0)
        #expect(line?.price == nil)
        #expect(view[0].count == 4)
        #expect(DeckMaths.missingCopies(theDeck, printings: printings, ownedByCard: [:], isBasic: notBasic) == 1)
    }

    /// The shown printing is the cheapest one (market first); the line's price is the card's cheapest.
    @Test func aLineShowsTheCheapestPrintingAndPrice() {
        let printings = ["twin": [product(id: 1, game: "yu-gi-oh", name: "Twin"),
                                  product(id: 2, game: "yu-gi-oh", name: "Twin"),
                                  product(id: 3, game: "yu-gi-oh", name: "Twin")]]
        let view = sections(deck([card("twin", "main", 1)]), game: yugioh, printings: printings,
                            prices: [1: ShownPrice(amount: 4, isLow: false), 2: ShownPrice(amount: 1.5, isLow: false),
                                     3: ShownPrice(amount: 0.5, isLow: true)])
        let line = lines(view[0]).first
        #expect(line?.shown?.productID == 2)
        #expect(line?.price == ShownPrice(amount: 1.5, isLow: false))
    }

    /// A section the format lacks (a file from elsewhere) is listed after the format's, under its id, so no card hides.
    @Test func aSectionTheFormatLacksIsListedLast() {
        let printings = ["a": [product(id: 1, game: "yu-gi-oh", name: "A")]]
        let view = sections(deck([card("a", "maybe", 2), card("a", "main", 1)]), game: yugioh, printings: printings)
        #expect(view.map(\.section.id) == ["main", "extra", "side", "maybe"])
        #expect(view[3].section.name == "maybe")
        #expect(view[3].count == 2)
    }

    // MARK: warnings

    private func warnings(_ deck: Deck, game: GameDefinition, isBasic: (String) -> Bool = { _ in false },
                          names: [String: String] = [:]) -> [String: String] {
        DeckMaths.warnings(deck, format: game.format(deck.format), isBasic: isBasic, nameOf: { names[$0] ?? $0 })
    }

    /// Yu-Gi-Oh!'s Main Deck holds 40–60 cards: under gives the range ("needs …"), over gives the maximum ("at most …",
    /// final fix B2); inside gives nothing.
    @Test func aSectionUnderOrOverItsRangeWarns() {
        let fillers = (1...13).map { card("c\($0)", "main", 3) }       // 39 cards, 3 copies each
        #expect(warnings(deck(fillers), game: yugioh)["main"] == "needs 40–60 cards")
        #expect(warnings(deck(fillers + [card("x", "main", 1)]), game: yugioh)["main"] == nil)
        let sixtyOne = (1...20).map { card("c\($0)", "main", 3) } + [card("x", "main", 1)]
        #expect(warnings(deck(sixtyOne), game: yugioh)["main"] == "at most 60 cards")
    }

    @Test func aSectionWithOnlyAMaximumOrMinimumWarns() {
        let extra = (1...6).map { card("e\($0)", "extra", 3) }          // 18 > 15
        #expect(warnings(deck(extra), game: yugioh)["extra"] == "at most 15 cards")
        let fiftyNine = (1...14).map { card("c\($0)", "deck", 4) } + [card("x", "deck", 3)]
        #expect(warnings(deck(fiftyNine, format: "constructed"), game: magic)["deck"] == "needs at least 60 cards")
    }

    /// Riftbound's Legend is exactly 1: none warns "needs 1 card", two or nine "at most 1 card" (final fix B2); the
    /// Battlefields exactly 3: one warns "needs 3 cards", four "at most 3 cards".
    @Test func anExactSectionWarnsWithItsNumber() {
        #expect(warnings(deck([]), game: riftbound)["legend"] == "needs 1 card")
        #expect(warnings(deck([card("l1", "legend", 1), card("l2", "legend", 1)]), game: riftbound)["legend"] == "at most 1 card")
        #expect(warnings(deck([card("l1", "legend", 9)]), game: riftbound)["legend"] == "at most 1 card")
        #expect(warnings(deck([card("l1", "legend", 1)]), game: riftbound)["legend"] == nil)
        #expect(warnings(deck([card("b", "battlefields", 1)]), game: riftbound)["battlefields"] == "needs 3 cards")
        #expect(warnings(deck([card("b", "battlefields", 4)]), game: riftbound)["battlefields"] == "at most 3 cards")
    }

    @Test func aSectionWithoutNumbersNeverWarns() {
        let side = (1...30).map { card("s\($0)", "side", 1) }
        #expect(warnings(deck(side), game: cyberpunk)["side"] == nil)
    }

    /// Riftbound: the Champion counts in the Main Deck's at least 40; the warning stands on the Main Deck with its name.
    @Test func aTotalOverTwoSectionsWarnsOnItsLastSection() {
        let main39 = (1...13).map { card("c\($0)", "main", 3) }
        let short = warnings(deck(main39), game: riftbound)
        #expect(short["main"] == "Main Deck with its Champion: needs at least 40 cards")
        #expect(short["champion"] == "needs 1 card")
        let full = warnings(deck(main39 + [card("champ", "champion", 1)]), game: riftbound)
        #expect(full["main"] == nil)
        #expect(full["champion"] == nil)
    }

    /// Copies over all counted sections together; the warning stands on the first section holding the card; basics are exempt;
    /// a section that is not counted (Riftbound's Runes) does not count.
    @Test func theCopyLimitCountsTheCountedSectionsTogether() {
        let main = (1...13).map { card("c\($0)", "main", 3) } + [card("ash", "main", 2)]       // 41 cards
        let theDeck = deck(main + [card("ash", "side", 2)])
        #expect(warnings(theDeck, game: yugioh, names: ["ash": "Ash Blossom"])["main"]
                == "more than 3 copies: Ash Blossom")
        #expect(warnings(theDeck, game: yugioh)["side"] == nil)

        let runes = (1...13).map { card("c\($0)", "main", 3) }
            + [card("rune", "runes", 12), card("champ", "champion", 1), card("leg", "legend", 1), card("bf", "battlefields", 3)]
        #expect(warnings(deck(runes), game: riftbound).isEmpty)
        let plains = (1...14).map { card("c\($0)", "deck", 4) } + [card("plains", "deck", 10)]
        #expect(warnings(deck(plains, format: "constructed"), game: magic, isBasic: { $0 == "plains" }).isEmpty)
    }

    /// Up to three names (by name), then "and 2 more"; after the section's own bound, joined by " · ".
    @Test func theCopyWarningNamesThreeCardsThenTheRest() {
        let over = ["e", "d", "c", "b", "a"].map { card($0, "deck", 5) }                         // 25 cards, all over 4
        let names = ["a": "Avacyn", "b": "Bolt", "c": "Counterspell", "d": "Duress", "e": "Explore"]
        #expect(warnings(deck(over, format: "constructed"), game: magic, names: names)["deck"]
                == "needs at least 60 cards · more than 4 copies: Avacyn, Bolt, Counterspell and 2 more")
    }

    /// Commander: one copy over commander and deck (singleton), on the section that holds the card; the 100 on the Deck.
    @Test func commanderIsSingletonAndOneHundredCards() {
        let theDeck = deck([card("sol", "deck", 2), card("cmd", "commander", 1), card("x", "deck", 96)],
                           format: "commander")
        let result = warnings(theDeck, game: magic, isBasic: { $0 == "x" }, names: ["sol": "Sol Ring"])
        #expect(result["commander"] == nil)
        #expect(result["deck"] == "Commander deck: needs 100 cards · more than 1 copy: Sol Ring")
        let empty = warnings(deck([card("sol", "deck", 2)], format: "commander"), game: magic,
                             names: ["sol": "Sol Ring"])
        #expect(empty["commander"] == "needs 1–2 cards")
        #expect(empty["deck"] == "Commander deck: needs 100 cards · more than 1 copy: Sol Ring")
        let legal = deck([card("cmd", "commander", 1), card("x", "deck", 99)], format: "commander")
        #expect(warnings(legal, game: magic, isBasic: { $0 == "x" }).isEmpty)
        // Final fix B2: over a maximum says which way, for a section's range and for a total.
        let over = deck([card("c1", "commander", 1), card("c2", "commander", 1), card("c3", "commander", 1),
                         card("x", "deck", 98)], format: "commander")
        let overResult = warnings(over, game: magic, isBasic: { $0 == "x" })
        #expect(overResult["commander"] == "at most 2 cards")
        #expect(overResult["deck"] == "Commander deck: at most 100 cards")
    }

    /// Fix round 1: the copy warning stands on the first section, in the format's order, that holds a card over the limit.
    @Test func theCopyWarningStandsOnTheFirstSectionHoldingACardOverTheLimit() {
        let names = ["x": "Xolo"]
        let rift = warnings(deck([card("x", "main", 4)]), game: riftbound, names: names)
        #expect(rift["main"] == "Main Deck with its Champion: needs at least 40 cards · more than 3 copies: Xolo")
        #expect(rift["champion"] == "needs 1 card")
        let ygo = warnings(deck([card("x", "main", 2), card("x", "side", 2)]), game: yugioh, names: names)
        #expect(ygo["main"] == "needs 40–60 cards · more than 3 copies: Xolo")
        #expect(ygo["side"] == nil)
        let sideOnly = warnings(deck([card("x", "side", 4)]), game: yugioh, names: names)
        #expect(sideOnly["side"] == "more than 3 copies: Xolo")
        #expect(sideOnly["main"] == "needs 40–60 cards")
        let commander = warnings(deck([card("x", "deck", 2)], format: "commander"), game: magic, names: names)
        #expect(commander["deck"] == "Commander deck: needs 100 cards · more than 1 copy: Xolo")
        #expect(commander["commander"] == "needs 1–2 cards")
    }

    /// Fix round 1: a section the format does not know counts toward the copy limit (no size bound, no total).
    @Test func aSectionTheFormatLacksCountsTowardTheCopyLimit() {
        let main = (1...14).map { card("c\($0)", "main", 3) }                          // 42 cards
        let result = warnings(deck(main + [card("x", "side2", 4)]), game: yugioh, names: ["x": "Xolo"])
        #expect(result == ["side2": "more than 3 copies: Xolo"])
        let split = warnings(deck(main + [card("x", "main", 2), card("x", "side2", 2)]), game: yugioh,
                             names: ["x": "Xolo"])
        #expect(split == ["main": "more than 3 copies: Xolo"])
        // Cyberpunk's Side Deck is a known section that is not counted: it stays out.
        let cyber = (1...14).map { card("c\($0)", "main", 3) } + [card("l", "legends", 3), card("x", "side", 4)]
        #expect(warnings(deck(cyber), game: cyberpunk).isEmpty)
    }

    /// Fix round 1: two deck cards with one id are one line, their counts summed into the first.
    @Test func twoDeckCardsWithOneIdAreOneLine() {
        let printings = ["a": [product(id: 1, game: "yu-gi-oh", name: "A")]]
        let theDeck = deck([card("a", "main", 2, name: "First"), card("a", "main", 2, name: "Second")])
        let view = sections(theDeck, game: yugioh, printings: printings, owned: ["a": 1])
        let all = lines(view[0])
        #expect(all.count == 1)
        #expect(all.first?.card.count == 4)
        #expect(all.first?.card.name == "First")
        #expect(all.first?.missing == 3)
        #expect(view[0].count == 4)
        #expect(DeckMaths.totals(view) == "4 cards · 3 missing · 1 without a price")
        #expect(warnings(theDeck, game: yugioh, names: ["a": "A"])["main"] == "needs 40–60 cards · more than 3 copies: A")
    }

    /// An empty deck warns under each minimum (the view decides not to show warnings for an empty deck): Yu-Gi-Oh! 1,
    /// Magic Commander 2, Magic Constructed 1, Riftbound 5, Cyberpunk 2.
    @Test func anEmptyDeckWarnsUnderEachMinimum() {
        #expect(warnings(deck([]), game: yugioh) == ["main": "needs 40–60 cards"])
        #expect(warnings(deck([], format: "commander"), game: magic)
                == ["commander": "needs 1–2 cards", "deck": "Commander deck: needs 100 cards"])
        #expect(warnings(deck([], format: "constructed"), game: magic) == ["deck": "needs at least 60 cards"])
        #expect(warnings(deck([]), game: riftbound)
                == ["legend": "needs 1 card", "champion": "needs 1 card", "main": "Main Deck with its Champion: needs at least 40 cards",
                    "runes": "needs 12 cards", "battlefields": "needs 3 cards"])
        #expect(warnings(deck([]), game: cyberpunk) == ["legends": "needs 3 cards", "main": "needs 40–50 cards"])
    }

    @Test func riftboundsSideboardHoldsAtMostTen() {
        let side = (1...11).map { card("s\($0)", "sideboard", 1) }
        #expect(warnings(deck(side), game: riftbound)["sideboard"] == "at most 10 cards")
        #expect(warnings(deck(Array(side.prefix(10))), game: riftbound)["sideboard"] == nil)
    }

    // MARK: totals

    @Test func totalsCountCardsAndSayNothingMoreWhenNothingIsMissing() {
        let printings = ["a": [product(id: 1, game: "yu-gi-oh", name: "A")]]
        let one = sections(deck([card("a", "main", 1)]), game: yugioh, printings: printings, owned: ["a": 1])
        #expect(DeckMaths.totals(one) == "1 card")
        let sixty = sections(deck([card("a", "main", 40), card("a", "side", 20)]), game: yugioh, printings: printings,
                             owned: ["a": 60])
        #expect(DeckMaths.totals(sixty) == "60 cards")
        #expect(DeckMaths.totals([]) == "0 cards")
    }

    /// Only missing copies are priced, each at its card's cheapest price; a low price counts without its mark.
    @Test func totalsPriceTheMissingCopiesOnly() {
        let printings = ["a": [product(id: 1, game: "yu-gi-oh", name: "A")],
                         "b": [product(id: 2, game: "yu-gi-oh", name: "B")],
                         "c": [product(id: 3, game: "yu-gi-oh", name: "C")]]
        let view = sections(deck([card("a", "main", 3), card("b", "main", 2), card("c", "side", 1)]), game: yugioh,
                            printings: printings, owned: ["a": 1, "b": 2],
                            prices: [1: ShownPrice(amount: 1.5, isLow: false), 2: ShownPrice(amount: 100, isLow: false),
                                     3: ShownPrice(amount: 2, isLow: true)])
        #expect(DeckMaths.totals(view) == "6 cards · 3 missing · $5.00 to complete")
    }

    /// Cards without a price are counted after the sum (`CollectionList.priceTail`); once each, over two lines.
    @Test func totalsCountTheCardsWithoutAPrice() {
        let printings = ["a": [product(id: 1, game: "yu-gi-oh", name: "A")],
                         "b": [product(id: 2, game: "yu-gi-oh", name: "B")]]
        let theDeck = deck([card("a", "main", 2), card("b", "main", 3), card("b", "side", 1)])
        let some = sections(theDeck, game: yugioh, printings: printings,
                            prices: [1: ShownPrice(amount: 1.25, isLow: false)])
        #expect(DeckMaths.totals(some) == "6 cards · 6 missing · $2.50 to complete + 1 without a price")
        let none = sections(theDeck, game: yugioh, printings: printings)
        #expect(DeckMaths.totals(none) == "6 cards · 6 missing · 2 without a price")
    }
}
