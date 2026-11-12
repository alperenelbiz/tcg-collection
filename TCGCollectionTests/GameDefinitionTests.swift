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
    /// M15: the order of the Type menu is data of the game: Magic's 15 card types in their order; the others sort.
    @Test func theTypeMenuOrderIsPartOfTheGame() {
        #expect(Games.all.map(\.facetOrder) == [MagicTypes.all, nil, nil, nil])
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
    @Test func enchantCreatureIsOnlyAnEnchantment() {
        #expect(Games.game("magic-the-gathering")!.typeFacets("Enchant Creature") == ["Enchantment"])
    }
    @Test func basics() {
        let m = Games.game("magic-the-gathering")!, r = Games.game("riftbound")!, y = Games.game("yu-gi-oh")!
        #expect(m.isBasicCard(name: "Forest (0276) - Full Art", cardType: "Basic Land — Forest"))
        #expect(m.isBasicCard(name: "Snow-Covered Island", cardType: "Basic Snow Land — Island"))
        #expect(!m.isBasicCard(name: "Dryad Arbor", cardType: "Land Creature — Forest Dryad"))
        #expect(m.isBasicPrinting(product(game: "magic-the-gathering", name: "Forest (0276) - Full Art", cardType: "Basic Land — Forest")))
        #expect(m.isBasicPrinting(product(game: "magic-the-gathering", name: "Forest - Golgari", cardType: "Land")))
        #expect(r.isBasicCard(name: "Calm Rune", cardType: "Rune")); #expect(!r.isBasicCard(name: "Rune Prison", cardType: "Spell"))
        #expect(r.isBasicPrinting(product(game: "riftbound", name: "Calm Rune", cardType: "Rune")))
        #expect(!r.isBasicPrinting(product(game: "riftbound", name: "Calm Rune (R02a)", cardType: "Rune")))
        #expect(!r.isBasicPrinting(product(game: "riftbound", name: "Calm Rune (A)", cardType: "Rune")))
        #expect(!y.isBasicCard(name: "Forest", cardType: "Basic Land — Forest"))
    }
    @Test func noFacetsForAnEmptyType() {
        for game in Games.all { #expect(game.typeFacets("").isEmpty); #expect(game.typeFacets("  ").isEmpty) }
    }
    @Test func basicSettingsPerGame() {
        #expect(Games.all.map(\.altArtBasicsAreNormal) == [false, false, true, false])
        #expect(Games.all.map(\.basicNames.count) == [12, 0, 6, 0])
        #expect(Games.game("riftbound")!.basicNames.contains("body rune"))
        #expect(Games.game("magic-the-gathering")!.basicNames.contains("snow covered wastes"))
    }

    @Test func aNumberRangeIsNotACard() {                                   // A7
        let m = Games.game("magic-the-gathering")!
        #expect(!m.isCard(fields: ["Number": "448-451", "Rarity": "R"])); #expect(!m.isCard(fields: ["Number": "448 - 451", "Rarity": "R", "SubType": "Land"]))
        #expect(m.isCard(fields: ["Number": "448", "Rarity": "R"])); #expect(Games.game("yu-gi-oh")!.isCard(fields: ["Number": "LEDE-EN061", "Rarity": "Ultra Rare"]))
        #expect(Games.game("riftbound")!.isCard(fields: ["Number": "136/167", "Rarity": "Epic"]))
    }
    @Test func artSeriesSetsAreExcluded() {                                 // A6
        let m = Games.game("magic-the-gathering")!
        #expect(m.excludesSet(named: "Art Series: The Hobbit")); #expect(!m.excludesSet(named: "Reality Fracture"))
        #expect(!m.excludesSet(named: "The Art Series")); #expect(!Games.game("yu-gi-oh")!.excludesSet(named: "Art Series: X"))
    }
    @Test func magicBasicsByTypeOrByName() {                                // A8
        let m = Games.game("magic-the-gathering")!
        #expect(m.isBasicCard(name: "Forest (0276) - Full Art", cardType: "Basic Land — Forest"))
        #expect(m.isBasicCard(name: "Forest - Golgari", cardType: "Land")); #expect(m.isBasicCard(name: "Forest (French) - \"Foret\"", cardType: "Land"))
        #expect(m.isBasicCard(name: "Wastes", cardType: "Colorless")); #expect(m.isBasicCard(name: "Snow-Covered Island", cardType: ""))
        #expect(!m.isBasicCard(name: "Mountain Valley", cardType: "Land")); #expect(!m.isBasicCard(name: "Forest Bear", cardType: "Creature — Bear"))
        #expect(!m.isBasicCard(name: "Island Sanctuary", cardType: "Enchantment")); #expect(!m.isBasicCard(name: "Dryad Arbor", cardType: "Land Creature — Forest Dryad"))
        #expect(Games.game("riftbound")!.isBasicCard(name: "Calm Rune (R02a)", cardType: "Rune"))
    }
    @Test func playsetsAndProductLines() {
        #expect(Games.all.map(\.playset) == [4, 3, 3, 3])
        #expect(Games.game(productLine: "YuGiOh")?.id == "yu-gi-oh"); #expect(Games.game(productLine: "Riftbound: League of Legends Trading Card Game")?.id == "riftbound")
        #expect(Games.game(productLine: "magic")?.id == "magic-the-gathering"); #expect(Games.game(productLine: "Pokemon") == nil)
        #expect(Games.game(productLine: "Cyberpunk TCG")?.id == "cyberpunk")
    }
}
