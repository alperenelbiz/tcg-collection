import Testing
@testable import TCGCollection2

struct CardNameTests {
    @Test func baseRemovesEveryTrailingBracketGroup() {
        let r = Games.game("riftbound")!
        #expect(CardName.base("Adam Smasher - Ender of Legends (Epic)", game: r, cardType: "") == "Adam Smasher - Ender of Legends")
        #expect(CardName.base("Rescue Cat (Alternate Art)", game: r, cardType: "") == "Rescue Cat")
        #expect(CardName.base("Stingcaster Mage (Borderless) (0329)", game: r, cardType: "") == "Stingcaster Mage")
        #expect(CardName.base("The Great Gallant Bandit (Starlight Rare) (Extended Art)", game: r, cardType: "") == "The Great Gallant Bandit")
        #expect(CardName.base("Beyond the Brave Booster Box [1st Edition]", game: r, cardType: "") == "Beyond the Brave Booster Box")
    }
    @Test func baseKeepsANameThatIsOnlyABracketOrHasAnInnerOne() {
        let r = Games.game("riftbound")!
        #expect(CardName.base("(Untitled)", game: r, cardType: "") == "(Untitled)")
        #expect(CardName.base("B.F.M. (Big Furry Monster) Left", game: r, cardType: "") == "B.F.M. (Big Furry Monster) Left")
        #expect(CardName.base("  Rescue Cat  ", game: r, cardType: "") == "Rescue Cat")
    }
    @Test func skillCardBracketStays() {
        let y = Games.game("yu-gi-oh")!
        #expect(CardName.base("Power Bond (Skill Card)", game: y, cardType: "") == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (Skill Card) (Ultra Rare)", game: y, cardType: "") == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (skill card)", game: y, cardType: "") == "Power Bond (skill card)")
        #expect(CardName.base("Power Bond (Ultra Rare)", game: y, cardType: "") == "Power Bond")
        #expect(CardName.base("Power Bond (Skill Card)", game: Games.game("magic-the-gathering")!, cardType: "") == "Power Bond")
    }
    @Test func anOfficialNameWithABracketStaysWhole() {
        let m = Games.game("magic-the-gathering")!
        #expect(CardName.base("Erase (Not the Urza's Legacy One)", game: m, cardType: "") == "Erase (Not the Urza's Legacy One)")
        #expect(CardName.base("Erase", game: m, cardType: "") == "Erase")
        #expect(CardName.searchKey(CardName.base("Erase (Not the Urza's Legacy One)", game: m, cardType: "")) != CardName.searchKey("Erase"))
    }
    @Test func aWholeNameStaysWhenBracketGroupsFollowIt() {
        let m = Games.game("magic-the-gathering")!
        #expect(CardName.base("Erase (Not the Urza's Legacy One) (Foil)", game: m, cardType: "") == "Erase (Not the Urza's Legacy One)")
        #expect(CardName.base("Erase (Not the Urza's Legacy One) (Foil) (0123)", game: m, cardType: "") == "Erase (Not the Urza's Legacy One)")
        #expect(CardName.searchKey(CardName.base("Erase (Not the Urza's Legacy One) (Foil)", game: m, cardType: "")) != CardName.searchKey("Erase"))
    }
    @Test func aKeptBracketSurvivesWhereverItStands() {
        let y = Games.game("yu-gi-oh")!
        #expect(CardName.base("Power Bond (Ultra Rare) (Skill Card)", game: y, cardType: "") == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (Ultra Rare) (Skill Card) (1st Edition)", game: y, cardType: "") == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (skill card) (Ultra Rare)", game: y, cardType: "") == "Power Bond (skill card)")
        #expect(CardName.base("Power Bond (Skill Card)", game: y, cardType: "") == "Power Bond (Skill Card)")
        #expect(CardName.base("(Skill Card)", game: y, cardType: "") == "(Skill Card)")
        #expect(CardName.base("Power Bond (Skill Card) (Skill Card)", game: y, cardType: "") == "Power Bond (Skill Card)")
    }
    @Test func searchKeyFoldsCaseAccentsAndPunctuation() {
        #expect(CardName.searchKey("\"A Case for K9\"") == "a case for k9")
        #expect(CardName.searchKey("Lim-Dûl's Vault") == "lim dul s vault")
        #expect(CardName.searchKey("K'Sante,  Courageous") == "k sante courageous")
        #expect(CardName.searchKey("KERRY eurodyne") == CardName.searchKey("Kerry Eurodyne"))
        #expect(CardName.searchKey("  ") == "")
    }

    @Test func aSkillPrintingIsItsOwnCard() {                               // A5
        let y = Games.game("yu-gi-oh")!
        #expect(CardName.base("Power Bond", game: y, cardType: "Skill") == "Power Bond (Skill Card)")
        #expect(CardName.base("Destiny Draw", game: y, cardType: "Yami Yugi/Skill") == "Destiny Draw (Skill Card)")
        #expect(CardName.base("Power Bond (Skill Card)", game: y, cardType: "Skill") == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (skill card)", game: y, cardType: "Skill") == "Power Bond (skill card)")
        #expect(CardName.base("Power Bond (Ultra Rare)", game: y, cardType: "Normal Spell") == "Power Bond")
        #expect(CardName.base("Power Bond (Ultra Rare)", game: y, cardType: "Skill") == "Power Bond (Skill Card)")
        #expect(CardName.base("Skill Drain", game: y, cardType: "Continuous Trap") == "Skill Drain")
        #expect(CardName.base("Power Bond", game: Games.game("magic-the-gathering")!, cardType: "Skill") == "Power Bond")
    }
}
