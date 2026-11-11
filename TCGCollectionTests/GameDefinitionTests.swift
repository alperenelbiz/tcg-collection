import Testing
@testable import TCGCollection2

struct GameDefinitionTests {
    @Test func fourGamesWithTheirCategories() {
        #expect(Games.all.map(\.id) == ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"])
        #expect(Games.all.map(\.categoryID) == [1, 2, 89, 92])
        #expect(Games.game(category: 89)?.id == "riftbound"); #expect(Games.game("nope") == nil)
    }
    @Test func fieldsAndPictureSources() {
        #expect(Games.all.map(\.typeField) == ["SubType", "Card Type", "Card Type", "CardType"])
        #expect(Games.all.map(\.textField) == ["OracleText", "Description", "Description", "Description"])
        #expect(Games.all.map(\.pictures) == [.tcgplayer, .ygoprodeck, .tcgplayer, .tcgplayer])
        #expect(Games.all.map(\.name) == ["Magic: The Gathering", "Yu-Gi-Oh!", "Riftbound", "Cyberpunk TCG"])
    }
    @Test func typeFacetsPerGame() {
        let m = Games.game("magic-the-gathering")!, y = Games.game("yu-gi-oh")!, r = Games.game("riftbound")!
        #expect(m.typeFacets("Legendary Creature — Human Officer") == ["Creature"])
        #expect(m.typeFacets("Artifact Creature — Golem") == ["Artifact", "Creature"])
        #expect(m.typeFacets("Basic Land — Forest") == ["Land"]); #expect(m.typeFacets("Instant") == ["Instant"])
        #expect(y.typeFacets("Fusion/Effect Monster") == ["Monster"]); #expect(y.typeFacets("Quick-Play Spell") == ["Spell"])
        #expect(y.typeFacets("Counter Trap") == ["Trap"]); #expect(y.typeFacets("Token") == ["Token"])
        #expect(r.typeFacets("Champion Unit") == ["Champion Unit"]); #expect(m.typeFacets("") == [])
    }
    @Test func aCardHasATypeOrANumberAndARarity() {
        let y = Games.game("yu-gi-oh")!
        #expect(y.isCard(fields: ["Card Type": "Effect Monster"]))
        #expect(y.isCard(fields: ["Number": "TP3-001", "Rarity": "Ultra Rare"]))
        #expect(!y.isCard(fields: ["Number": "TP3-001"])); #expect(!y.isCard(fields: ["Rarity": "Ultra Rare"]))
        #expect(!y.isCard(fields: ["Number": " ", "Rarity": "Ultra Rare"])); #expect(!y.isCard(fields: ["UPC": "123"]))
        #expect(!y.isCard(fields: [:]))
    }
    @Test func bracketExceptionsPerGame() {
        #expect(Games.all.map(\.keptBrackets) == [[], ["Skill Card"], [], []])
        #expect(Games.all.map(\.wholeNames) == [["Erase (Not the Urza's Legacy One)"], [], [], []])
    }
}
