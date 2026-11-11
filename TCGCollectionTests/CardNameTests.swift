import Testing
@testable import TCGCollection2

struct CardNameTests {
    @Test func baseRemovesEveryTrailingBracketGroup() {
        let r = Games.game("riftbound")!
        #expect(CardName.base("Adam Smasher - Ender of Legends (Epic)", game: r) == "Adam Smasher - Ender of Legends")
        #expect(CardName.base("Rescue Cat (Alternate Art)", game: r) == "Rescue Cat")
        #expect(CardName.base("Stingcaster Mage (Borderless) (0329)", game: r) == "Stingcaster Mage")
        #expect(CardName.base("The Great Gallant Bandit (Starlight Rare) (Extended Art)", game: r) == "The Great Gallant Bandit")
        #expect(CardName.base("Beyond the Brave Booster Box [1st Edition]", game: r) == "Beyond the Brave Booster Box")
    }
    @Test func baseKeepsANameThatIsOnlyABracketOrHasAnInnerOne() {
        let r = Games.game("riftbound")!
        #expect(CardName.base("(Untitled)", game: r) == "(Untitled)")
        #expect(CardName.base("B.F.M. (Big Furry Monster) Left", game: r) == "B.F.M. (Big Furry Monster) Left")
        #expect(CardName.base("  Rescue Cat  ", game: r) == "Rescue Cat")
    }
    @Test func skillCardBracketStays() {
        let y = Games.game("yu-gi-oh")!
        #expect(CardName.base("Power Bond (Skill Card)", game: y) == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (Skill Card) (Ultra Rare)", game: y) == "Power Bond (Skill Card)")
        #expect(CardName.base("Power Bond (skill card)", game: y) == "Power Bond (skill card)")
        #expect(CardName.base("Power Bond (Ultra Rare)", game: y) == "Power Bond")
        #expect(CardName.base("Power Bond (Skill Card)", game: Games.game("magic-the-gathering")!) == "Power Bond")
    }
    @Test func anOfficialNameWithABracketStaysWhole() {
        let m = Games.game("magic-the-gathering")!
        #expect(CardName.base("Erase (Not the Urza's Legacy One)", game: m) == "Erase (Not the Urza's Legacy One)")
        #expect(CardName.base("Erase", game: m) == "Erase")
        #expect(CardName.searchKey(CardName.base("Erase (Not the Urza's Legacy One)", game: m)) != CardName.searchKey("Erase"))
    }
    @Test func searchKeyFoldsCaseAccentsAndPunctuation() {
        #expect(CardName.searchKey("\"A Case for K9\"") == "a case for k9")
        #expect(CardName.searchKey("Lim-Dûl's Vault") == "lim dul s vault")
        #expect(CardName.searchKey("K'Sante,  Courageous") == "k sante courageous")
        #expect(CardName.searchKey("KERRY eurodyne") == CardName.searchKey("Kerry Eurodyne"))
        #expect(CardName.searchKey("  ") == "")
    }
}
