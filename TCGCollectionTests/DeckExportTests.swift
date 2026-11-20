import Testing
@testable import TCGCollection2

/// A80: a deck as the text the Paste… sheet reads.
struct DeckExportTests {
    private let magic = Games.game("magic-the-gathering")!
    private let yugioh = Games.game("yu-gi-oh")!

    private func card(_ key: String, _ name: String, _ section: String, _ count: Int) -> DeckCard {
        DeckCard(cardKey: key, name: name, section: section, count: count)
    }

    private func deck(_ cards: [DeckCard], format: String = "standard") -> Deck {
        Deck(id: "d", name: "Wind", format: format, active: false, cards: cards)
    }

    private var standard: DeckFormat { yugioh.format("standard") }

    @Test func sectionsInFormatOrderCardsByName() {
        let d = deck([card("stardust dragon", "Stardust Dragon", "extra", 1), card("zeta", "Zeta", "main", 1),
                      card("alpha", "alpha", "main", 3)])
        #expect(DeckExport.text(d, format: standard) == "Main Deck:\n3 alpha\n1 Zeta\n\nExtra Deck:\n1 Stardust Dragon\n")
    }

    @Test func anEmptySectionIsLeftOut() {
        let text = DeckExport.text(deck([card("zeta", "Zeta", "main", 1)]), format: standard)
        #expect(!text.contains("Side Deck"))
        #expect(!text.contains("Extra Deck"))
    }

    @Test func anEmptyDeckIsEmpty() {
        #expect(DeckExport.text(deck([]), format: standard) == "")
    }

    @Test func aSectionTheFormatLacksComesLast() {
        let d = deck([card("x", "X", "maybe", 1), card("zeta", "Zeta", "main", 1)])
        #expect(DeckExport.text(d, format: standard) == "Main Deck:\n1 Zeta\n\nmaybe:\n1 X\n")
    }

    @Test func aCardWithoutANameUsesItsKey() {
        #expect(DeckExport.text(deck([card("bolt", "  ", "main", 1)]), format: standard) == "Main Deck:\n1 bolt\n")
    }

    @Test func accentsAndCaseDoNotChangeTheOrder() {
        let d = deck([card("zed", "Zed", "main", 1), card("eclair", "Éclair", "main", 1), card("apple", "apple", "main", 1)])
        #expect(DeckExport.text(d, format: standard) == "Main Deck:\n1 apple\n1 Éclair\n1 Zed\n")
    }

    @Test func theTextReadsBack() {
        let format = magic.format("commander")
        let d = deck([card("plains", "Plains", "deck", 12), card("quintorius history chaser", "Quintorius, History Chaser",
                     "commander", 1), card("7 colored fish", "7 Colored Fish", "deck", 2)], format: "commander")
        let parsed = DeckText.parse(DeckExport.text(d, format: format))
        var sections: [String?] = [], cards: [(Int, String)] = []
        for line in parsed {
            switch line.kind {
            case .section(let name): sections.append(DeckPaste.sectionID(named: name, in: format))
            case .card(let count, let name): cards.append((count, name))
            case .note: continue
            case .unreadable(let text): Issue.record("unreadable: \(text)")
            }
        }
        #expect(sections == ["commander", "deck"])
        #expect(cards.map(\.0) == [1, 2, 12])
        #expect(cards.map(\.1) == ["Quintorius, History Chaser", "7 Colored Fish", "Plains"])
    }

    @MainActor @Test func copyWritesAndSaysCopied() {
        var got: String?
        let copy = DeckExportCopy(write: { got = $0 })
        #expect(!copy.copied)
        copy.copy("a")
        #expect(got == "a")
        #expect(copy.copied)
    }
}
