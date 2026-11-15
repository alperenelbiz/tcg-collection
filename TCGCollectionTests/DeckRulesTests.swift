import Testing
import Foundation
@testable import TCGCollection2

struct DeckRulesTests {
    private func card(_ key: String, _ section: String, _ count: Int, name: String = "") -> DeckCard {
        DeckCard(cardKey: key, name: name.isEmpty ? key.capitalized : name, section: section, count: count)
    }

    private func deck(_ cards: [DeckCard], format: String = "constructed") -> Deck {
        Deck(id: "d", name: "Burn", format: format, active: true, cards: cards)
    }

    private var total: (Deck) -> Int { { $0.cards.reduce(0) { $0 + $1.count } } }

    @Test func aNewDeckIsEmptyAndNotActive() {
        #expect(DeckRules.new(name: "Burn", format: "constructed", id: "x")
                == Deck(id: "x", name: "Burn", format: "constructed", active: false, cards: []))
    }

    @Test func aCardsIDIsItsKeyAndSection() {
        #expect(card("bolt", "sideboard", 1).id == "bolt|sideboard")
    }

    @Test func settingAddsChangesAndRemoves() {
        var d = DeckRules.setting(deck([]), count: 4, cardKey: "bolt", name: "Lightning Bolt", section: "deck")
        #expect(d.cards == [card("bolt", "deck", 4, name: "Lightning Bolt")])
        d = DeckRules.setting(d, count: 2, cardKey: "bolt", name: "Other name", section: "sideboard")
        #expect(d.cards.map(\.id) == ["bolt|deck", "bolt|sideboard"])
        d = DeckRules.setting(d, count: 3, cardKey: "bolt", name: "Other name", section: "deck")
        #expect(d.cards[0] == card("bolt", "deck", 3, name: "Lightning Bolt"))      // an existing card keeps its name
        d = DeckRules.setting(d, count: 0, cardKey: "bolt", name: "", section: "deck")
        #expect(d.cards.map(\.id) == ["bolt|sideboard"])
        #expect(DeckRules.setting(d, count: 0, cardKey: "none", name: "", section: "deck") == d)
        #expect(DeckRules.setting(d, count: -3, cardKey: "bolt", name: "", section: "sideboard").cards.isEmpty)
    }

    @Test func countsAreClampedTo999() {
        let d = DeckRules.setting(deck([]), count: 5000, cardKey: "bolt", name: "B", section: "deck")
        #expect(d.cards.map(\.count) == [999])
    }

    @Test func movingChangesTheSectionAndSumsIntoACardThere() {
        let start = deck([card("bolt", "deck", 3), card("ring", "deck", 1), card("bolt", "sideboard", 2)])
        let moved = DeckRules.moving(start, cardKey: "ring", from: "deck", to: "sideboard")
        #expect(moved.cards == [card("bolt", "deck", 3), card("ring", "sideboard", 1), card("bolt", "sideboard", 2)])
        let summed = DeckRules.moving(start, cardKey: "bolt", from: "deck", to: "sideboard")
        #expect(summed.cards == [card("ring", "deck", 1), card("bolt", "sideboard", 5)])
        #expect(total(summed) == total(start))
        #expect(DeckRules.moving(start, cardKey: "none", from: "deck", to: "sideboard") == start)
        #expect(DeckRules.moving(start, cardKey: "bolt", from: "deck", to: "deck") == start)
    }

    /// D12: no card and no count is lost; a card whose section the new format has stays; the others go to the closure's
    /// section; cards that land on one (card, section) are summed into the first.
    @Test func aFormatChangeKeepsEveryCard() throws {
        let commander = try #require(Games.game("magic-the-gathering")?.format("commander"))
        let start = deck([card("bolt", "deck", 4), card("ring", "sideboard", 1), card("bolt", "sideboard", 2),
                          card("sol", "unknown", 1)])
        let changed = DeckRules.changingFormat(start, to: commander) { _ in "deck" }
        #expect(changed.format == "commander")
        #expect(changed.cards == [card("bolt", "deck", 6), card("ring", "deck", 1), card("sol", "deck", 1)])
        #expect(total(changed) == total(start))
        #expect(changed.id == start.id && changed.name == start.name && changed.active == start.active)
        // The closure gets each card that has to move, and only those.
        var asked: [String] = []
        _ = DeckRules.changingFormat(deck([card("a", "deck", 1), card("b", "sideboard", 1)]), to: commander) {
            asked.append($0.id); return "deck"
        }
        #expect(asked == ["b|sideboard"])
    }

    @Test func addingSumsPastedCardsByKey() {
        let start = deck([card("bolt", "deck", 2)])
        let pasted = [card("ring", "deck", 1), card("bolt", "deck", 2), card("bolt", "sideboard", 1), card("ring", "deck", 2),
                      card("zero", "deck", 0)]
        #expect(DeckRules.adding(start, pasted).cards
                == [card("bolt", "deck", 4), card("ring", "deck", 3), card("bolt", "sideboard", 1)])
        #expect(DeckRules.adding(start, [card("bolt", "deck", 998)]).cards.map(\.count) == [999])
        #expect(DeckRules.adding(start, [card("ring", "deck", 5000)]).cards.map(\.count) == [2, 999])
    }

    @Test func uniqueName() {
        #expect(DeckRules.uniqueName("Deck", among: []) == "Deck")
        #expect(DeckRules.uniqueName("Deck", among: ["Deck"]) == "Deck 2")
        #expect(DeckRules.uniqueName("Deck", among: ["Deck", "Deck 2", "Deck 3"]) == "Deck 4")
        #expect(DeckRules.uniqueName("Deck", among: ["Deck 2"]) == "Deck")
    }
}
