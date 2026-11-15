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

    /// Task 3 review, task 5 fix round 1: the clamp never lowers a count. A card already above 999 (a file written by
    /// hand) keeps its count on a step up, and `−` takes exactly one copy off; it cannot rise further.
    @Test func theClampNeverLowersACount() {
        let big = deck([card("bolt", "deck", 1200)])
        #expect(DeckRules.setting(big, count: 1201, cardKey: "bolt", name: "B", section: "deck").cards.map(\.count) == [1200])
        #expect(DeckRules.setting(big, count: 1199, cardKey: "bolt", name: "B", section: "deck").cards.map(\.count) == [1199])
        #expect(DeckRules.setting(big, count: 5000, cardKey: "bolt", name: "B", section: "deck").cards.map(\.count) == [1200])
        let at = deck([card("bolt", "deck", 999)])
        #expect(DeckRules.setting(at, count: 1000, cardKey: "bolt", name: "B", section: "deck").cards.map(\.count) == [999])
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

    /// Task 5's review, fixed in task 7: a paste never lowers a count. A card above 999 (written by hand) keeps its count;
    /// otherwise a sum is 999 at most.
    @Test func addingNeverLowersACount() {
        #expect(DeckRules.adding(deck([card("bolt", "deck", 1200)]), [card("bolt", "deck", 1)]).cards.map(\.count) == [1200])
        #expect(DeckRules.adding(deck([card("bolt", "deck", 990)]), [card("bolt", "deck", 5), card("bolt", "deck", 10)])
            .cards.map(\.count) == [999])
        #expect(DeckRules.adding(deck([]), [card("bolt", "deck", 600), card("bolt", "deck", 600)]).cards.map(\.count) == [999])
        #expect(DeckRules.adding(deck([card("bolt", "deck", 1200)]), [card("ring", "deck", 1200)]).cards.map(\.count) == [1200, 999])
    }

    @Test func uniqueName() {
        #expect(DeckRules.uniqueName("Deck", among: []) == "Deck")
        #expect(DeckRules.uniqueName("Deck", among: ["Deck"]) == "Deck 2")
        #expect(DeckRules.uniqueName("Deck", among: ["Deck", "Deck 2", "Deck 3"]) == "Deck 4")
        #expect(DeckRules.uniqueName("Deck", among: ["Deck 2"]) == "Deck")
    }

    // MARK: Adding and taking one copy (phase 3A task 6)

    /// The copies of a card over every section of the deck.
    @Test func copiesCountACardOverAllSections() {
        let start = deck([card("bolt", "deck", 3), card("ring", "deck", 1), card("bolt", "sideboard", 2)])
        #expect(DeckRules.copies(start, cardKey: "bolt") == 5)
        #expect(DeckRules.copies(start, cardKey: "ring") == 1)
        #expect(DeckRules.copies(start, cardKey: "none") == 0)
    }

    /// `+` of a search cell or "Add to deck": one copy more in the section, a new card appended with its name; the 999
    /// clamp holds.
    @Test func addingOneAddsACopyToTheSection() {
        let start = deck([card("bolt", "deck", 3)])
        #expect(DeckRules.addingOne(start, cardKey: "bolt", name: "Bolt", section: "deck").cards == [card("bolt", "deck", 4)])
        #expect(DeckRules.addingOne(start, cardKey: "bolt", name: "Bolt", section: "sideboard").cards
                == [card("bolt", "deck", 3), card("bolt", "sideboard", 1, name: "Bolt")])
        #expect(DeckRules.addingOne(start, cardKey: "ring", name: "The Ring", section: "deck").cards
                == [card("bolt", "deck", 3), card("ring", "deck", 1, name: "The Ring")])
        #expect(DeckRules.addingOne(deck([card("bolt", "deck", 999)]), cardKey: "bolt", name: "Bolt", section: "deck")
            .cards.map(\.count) == [999])
    }

    /// `−` of a search cell: one copy off the default section first, then off the other sections in the format's order,
    /// then off a section the format lacks; a card at 1 leaves its section; a card not in the deck changes nothing.
    @Test func takingOneTakesFromTheDefaultSectionFirst() {
        let order = ["main", "extra", "side"]
        let start = deck([card("x", "side", 1), card("x", "extra", 2), card("x", "main", 1), card("y", "main", 1)], format: "standard")
        let first = DeckRules.takingOne(start, cardKey: "x", defaultSection: "main", order: order)
        #expect(first.cards == [card("x", "side", 1), card("x", "extra", 2), card("y", "main", 1)])
        let second = DeckRules.takingOne(first, cardKey: "x", defaultSection: "main", order: order)
        #expect(second.cards == [card("x", "side", 1), card("x", "extra", 1), card("y", "main", 1)])
        let third = DeckRules.takingOne(second, cardKey: "x", defaultSection: "main", order: order)
        #expect(third.cards == [card("x", "side", 1), card("y", "main", 1)])
        let fourth = DeckRules.takingOne(third, cardKey: "x", defaultSection: "main", order: order)
        #expect(fourth.cards == [card("y", "main", 1)])
        #expect(DeckRules.takingOne(fourth, cardKey: "x", defaultSection: "main", order: order) == fourth)
        // A section the format lacks (a file written elsewhere) comes after the format's sections.
        let odd = deck([card("x", "maybe", 1), card("x", "side", 1)], format: "standard")
        #expect(DeckRules.takingOne(odd, cardKey: "x", defaultSection: "main", order: order).cards == [card("x", "maybe", 1)])
        #expect(DeckRules.takingOne(deck([card("x", "maybe", 2)]), cardKey: "x", defaultSection: "main", order: order).cards
                == [card("x", "maybe", 1)])
    }
}
