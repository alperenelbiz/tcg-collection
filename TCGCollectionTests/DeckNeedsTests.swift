import Testing
import Foundation
@testable import TCGCollection2

struct DeckNeedsTests {
    private func deck(_ name: String, _ cards: [DeckCard], active: Bool = true) -> Deck {
        Deck(id: "id-\(name)", name: name, format: "standard", active: active, cards: cards)
    }

    private func x(_ count: Int, section: String = "main", productID: Int? = nil, name: String = "Card X") -> DeckCard {
        DeckCard(cardKey: "x", name: name, section: section, count: count, productID: productID)
    }

    private func needs(_ decks: [Deck], answer: Bool? = nil, owned: Int = 3, basic: Bool = false) -> [String: CardNeed] {
        DeckNeeds.needs(decks: decks, sharing: answer.map { ["x": $0] } ?? [:], owned: { $0 == "x" ? owned : 0 },
                        isBasic: { _ in basic })
    }

    private func need(_ decks: [Deck], answer: Bool? = nil, owned: Int = 3, basic: Bool = false) throws -> CardNeed {
        try #require(needs(decks, answer: answer, owned: owned, basic: basic)["x"])
    }

    /// The sum of `missing` over the users equals `fromDecks` (E4).
    private func checkSum(_ need: CardNeed) {
        #expect(need.users.reduce(0) { $0 + $1.missing } == need.fromDecks)
    }

    private func got(_ need: CardNeed) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: need.users.map { ($0.deckName, $0.got) })
    }

    private func missing(_ need: CardNeed) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: need.users.map { ($0.deckName, $0.missing) })
    }

    private var a32: [Deck] { [deck("A", [x(3)]), deck("B", [x(2)])] }

    @Test func aConflictWithoutAnAnswerCountsTheSumAndServesInDeckOrder() throws {
        let n = try need(a32)
        #expect(n.sum == 5)
        #expect(n.need == 5)
        #expect(n.inConflict)
        #expect(n.pending)
        #expect(n.fromDecks == 2)
        #expect(n.answer == nil)
        #expect(got(n) == ["A": 3, "B": 0])
        #expect(missing(n) == ["A": 0, "B": 2])
        #expect(n.users.map(\.deckID) == ["id-A", "id-B"])
        #expect(n.name == "Card X")
        #expect(n.owned == 3)
        checkSum(n)
    }

    @Test func sharedNeedsTheLargestUseAndEveryDeckSeesAllCopies() throws {
        let n = try need(a32, answer: true)
        #expect(n.need == 3)
        #expect(n.fromDecks == 0)
        #expect(n.inConflict)
        #expect(!n.pending)
        #expect(got(n) == ["A": 3, "B": 2])      // the controller's ruling: got = min(use, owned); B uses 2
        #expect(missing(n) == ["A": 0, "B": 0])
        checkSum(n)
    }

    @Test func sharedWithFewerCopiesThanTheLargestUse() throws {
        let n = try need(a32, answer: true, owned: 2)
        #expect(n.fromDecks == 1)
        #expect(missing(n) == ["A": 1, "B": 0])
        checkSum(n)
    }

    @Test func notSharedIsServedAsAPendingCard() throws {
        let n = try need(a32, answer: false)
        #expect(n.need == 5)
        #expect(n.fromDecks == 2)
        #expect(n.inConflict)
        #expect(!n.pending)
        #expect(got(n) == ["A": 3, "B": 0])
        #expect(missing(n) == ["A": 0, "B": 2])
        checkSum(n)
    }

    @Test func enoughCopiesIsNoConflictWhateverTheAnswer() throws {
        let decks = [deck("A", [x(2)]), deck("B", [x(1)])]
        let plain = try need(decks)
        for answer in [nil, true, false] as [Bool?] {
            let n = try need(decks, answer: answer)
            #expect(!n.inConflict)
            #expect(!n.pending)
            #expect(n.fromDecks == 0)
            #expect(n.need == plain.need)       // E3: an answer on a card not in conflict changes no number
            #expect(n.users == plain.users)
            checkSum(n)
        }
    }

    @Test func oneUserIsNoConflict() throws {
        let n = try need([deck("A", [x(4)])], owned: 1)
        #expect(!n.inConflict)
        #expect(!n.pending)
        #expect(n.fromDecks == 3)
        #expect(missing(n) == ["A": 3])
        checkSum(n)
    }

    @Test func aDeckThatIsNotActiveIsLeftOutAndSeesAllCopies() throws {
        let b = deck("B", [x(2)], active: false)
        let decks = [deck("A", [x(3)]), b]
        let all = needs(decks)
        let n = try #require(all["x"])
        #expect(n.users.map(\.deckName) == ["A"])
        #expect(!n.inConflict)
        #expect(n.fromDecks == 0)
        checkSum(n)
        #expect(DeckNeeds.available(to: b, needs: all, owned: { $0 == "x" ? 3 : 0 }) == ["x": 3])
        #expect(DeckNeeds.available(to: decks[0], needs: all, owned: { $0 == "x" ? 3 : 0 }) == ["x": 3])
    }

    @Test func availableToAnActiveDeckIsWhatItGets() throws {
        let all = needs(a32)
        let owned: (String) -> Int = { $0 == "x" ? 3 : 0 }
        #expect(DeckNeeds.available(to: a32[0], needs: all, owned: owned) == ["x": 3])
        #expect(DeckNeeds.available(to: a32[1], needs: all, owned: owned) == ["x": 0])
    }

    @Test func noActiveDeckNeedsNothing() {
        #expect(needs([deck("A", [x(3)], active: false)]).isEmpty)
        #expect(needs([deck("A", [x(0)])]).isEmpty)
    }

    @Test func aBasicCardIsNeverMissingNorPending() throws {
        let decks = [deck("A", [x(10)]), deck("B", [x(10)]), deck("C", [x(10)])]
        let n = try need(decks, owned: 0, basic: true)
        #expect(n.isBasic)
        #expect(n.fromDecks == 0)
        #expect(!n.inConflict)
        #expect(!n.pending)
        #expect(missing(n) == ["A": 0, "B": 0, "C": 0])
        checkSum(n)
        #expect(DeckNeeds.decksLeftShort(n, selling: 1).isEmpty)
        #expect(DeckNeeds.pendingCount(needs(decks, owned: 0, basic: true)) == 0)
    }

    @Test func deckOrderDecidesWhoIsServedFirst() throws {
        let n = try need([deck("B", [x(2)]), deck("A", [x(3)])])
        #expect(n.users.map(\.deckName) == ["B", "A"])
        #expect(got(n) == ["B": 2, "A": 1])
        #expect(missing(n) == ["B": 0, "A": 2])
        checkSum(n)
    }

    @Test func useCountsEverySection() throws {
        let n = try need([deck("A", [x(2, section: "main"), x(1, section: "side")])])
        #expect(n.users.map(\.use) == [3])
        #expect(n.sum == 3)
        checkSum(n)
    }

    @Test func aCountUnderOneCountsAsZero() throws {
        let n = try need([deck("A", [x(2), x(-4, section: "side")]), deck("B", [x(0)])])
        #expect(n.users.map(\.use) == [2])
        checkSum(n)
    }

    @Test func pendingCountCountsPendingCards() {
        let y = DeckCard(cardKey: "y", name: "Y", section: "main", count: 2)
        let decks = [deck("A", [x(3), y]), deck("B", [x(2), y])]
        let owned: (String) -> Int = { $0 == "x" ? 3 : 0 }
        #expect(DeckNeeds.pendingCount(DeckNeeds.needs(decks: decks, sharing: [:], owned: owned, isBasic: { _ in false })) == 2)
        #expect(DeckNeeds.pendingCount(DeckNeeds.needs(decks: decks, sharing: ["y": true], owned: owned,
                                                       isBasic: { _ in false })) == 1)
    }

    @Test func theUsersKeepTheirStoredPrintings() throws {
        let n = try need([deck("A", [x(1, productID: 7), x(1, section: "side", productID: 8), x(1, section: "x")])])
        #expect(n.users.map(\.productIDs) == [[7, 8]])
    }

    @Test func theChosenPrintingIsTheOneOverTheDecksThatMissTheCard() throws {
        let one = try need([deck("A", [x(3, productID: 7)]), deck("B", [x(2)])], owned: 1)
        #expect(DeckNeeds.chosenPrinting(one) == 7)
        let two = try need([deck("A", [x(3, productID: 7)]), deck("B", [x(2, productID: 9)])], owned: 1)
        #expect(DeckNeeds.chosenPrinting(two) == nil)
        let notMissing = try need([deck("A", [x(3, productID: 7)]), deck("B", [x(2)])])
        #expect(missing(notMissing) == ["A": 0, "B": 2])
        #expect(DeckNeeds.chosenPrinting(notMissing) == nil)
    }

    @Test func decksLeftShortNamesTheDecksWhoseMissingGoesUp() throws {
        #expect(DeckNeeds.decksLeftShort(try need(a32, answer: false), selling: 1) == ["A"])
        #expect(DeckNeeds.decksLeftShort(try need(a32), selling: 1) == ["A"])
        #expect(DeckNeeds.decksLeftShort(try need(a32, answer: true), selling: 1) == ["A"])
        #expect(DeckNeeds.decksLeftShort(try need([deck("A", [x(2)])], owned: 5), selling: 1) == [])
        #expect(DeckNeeds.decksLeftShort(try need(a32, answer: true), selling: 9) == ["A", "B"])
    }

    @Test func theSoldMessage() {
        #expect(DeckNeeds.soldMessage(decks: []) == nil)
        #expect(DeckNeeds.soldMessage(decks: ["Wind"])
                == "You use this card in Wind. If you sell it the deck will miss a copy.")
        #expect(DeckNeeds.soldMessage(decks: ["Wind", "Cheap"])
                == "You use this card in Wind and Cheap. If you sell it a deck will miss a copy.")
        #expect(DeckNeeds.soldMessage(decks: ["Wind", "Cheap", "Burn"])
                == "You use this card in Wind, Cheap and 1 more. If you sell it a deck will miss a copy.")
        #expect(DeckNeeds.soldMessage(decks: ["Wind", "Cheap", "Burn", "Elves"])
                == "You use this card in Wind, Cheap and 2 more. If you sell it a deck will miss a copy.")
    }
}
