import Foundation
import Testing
@testable import TCGCollection2

/// The sheet "Sharing decisions" (E7, A22): its rows, its choices and what Done writes (`SharingChoices`).
struct SharingSheetTests {
    private func deck(_ name: String, _ cards: [DeckCard], active: Bool = true) -> Deck {
        Deck(id: "id-\(name)", name: name, format: "standard", active: active, cards: cards)
    }

    private func card(_ key: String, _ count: Int, name: String) -> DeckCard {
        DeckCard(cardKey: key, name: name, section: "main", count: count)
    }

    /// Wind uses Zeta ×3, Alpha ×2 and Mid ×1; Cheap uses Zeta ×2, Alpha ×2 and Mid ×1; 3 copies of Zeta are owned, 1 of
    /// Alpha, 2 of Mid: Zeta and Alpha are pending, Mid is not in conflict.
    private var needs: [String: CardNeed] {
        let decks = [deck("Wind", [card("zeta", 3, name: "Zeta"), card("alpha", 2, name: "Alpha"), card("mid", 1, name: "Mid")]),
                     deck("Cheap", [card("zeta", 2, name: "Zeta"), card("alpha", 2, name: "Alpha"), card("mid", 1, name: "Mid")])]
        let owned = ["zeta": 3, "alpha": 1, "mid": 2]
        return DeckNeeds.needs(decks: decks, sharing: [:], owned: { owned[$0] ?? 0 }, isBasic: { _ in false })
    }

    @Test func theRowsAreThePendingCardsByName() {
        let choices = SharingChoices(needs: Array(needs.values))
        #expect(choices.rows.map(\.need.cardKey) == ["alpha", "zeta"])
        #expect(choices.rows.allSatisfy { $0.choice == nil })
    }

    @Test func noChoiceIsMadeAtFirstAndDoneWritesNothingThen() {
        let choices = SharingChoices(needs: Array(needs.values))
        #expect(choices.answers.isEmpty)
        #expect(!choices.canFinish)
    }

    @Test func chooseAllFillsEveryRow() {
        var choices = SharingChoices(needs: Array(needs.values))
        choices.chooseAll(true)
        #expect(choices.rows.map(\.choice) == [true, true])
        #expect(choices.answers == ["alpha": true, "zeta": true])
        choices.chooseAll(false)
        #expect(choices.answers == ["alpha": false, "zeta": false])
    }

    @Test func answersHoldOnlyTheRowsWithAChoice() {
        var choices = SharingChoices(needs: Array(needs.values))
        choices.choose(cardKey: "zeta", shared: false)
        #expect(choices.answers == ["zeta": false])
        #expect(choices.canFinish)
        choices.choose(cardKey: "alpha", shared: true)
        choices.choose(cardKey: "zeta", shared: true)
        #expect(choices.answers == ["alpha": true, "zeta": true])
        // A key that is not a row changes nothing.
        choices.choose(cardKey: "mid", shared: true)
        #expect(choices.answers == ["alpha": true, "zeta": true])
    }

    @Test func aRowSaysItsUsersAndTheOwnedCount() throws {
        let zeta = try #require(needs["zeta"])
        #expect(SharingChoices.rowText(zeta) == "Wind 3 · Cheap 2 · you own 3")
        let alpha = try #require(needs["alpha"])
        #expect(SharingChoices.rowText(alpha) == "Wind 2 · Cheap 2 · you own 1")
    }

    /// Review Focus 1: the second deck set not active while the question is open: a late answer is written, and no number
    /// of the card's need changes with it.
    @Test func aLateAnswerOnACardNoLongerInConflictChangesNoNumber() throws {
        let decks = [deck("Wind", [card("x", 2, name: "X")]), deck("Cheap", [card("x", 2, name: "X")], active: false)]
        func need(_ sharing: [String: Bool]) throws -> CardNeed {
            try #require(DeckNeeds.needs(decks: decks, sharing: sharing, owned: { _ in 2 }, isBasic: { _ in false })["x"])
        }
        let none = try need([:]), shared = try need(["x": true]), each = try need(["x": false])
        for answered in [shared, each] {
            #expect(!answered.pending && !none.pending)
            #expect(answered.sum == none.sum)
            #expect(answered.need == none.need)
            #expect(answered.fromDecks == none.fromDecks)
            #expect(answered.users == none.users)
        }
    }
}
