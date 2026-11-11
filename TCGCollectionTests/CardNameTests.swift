import Testing
@testable import TCGCollection2

struct CardNameTests {
    @Test func baseRemovesEveryTrailingBracketGroup() {
        #expect(CardName.base("Adam Smasher - Ender of Legends (Epic)") == "Adam Smasher - Ender of Legends")
        #expect(CardName.base("Rescue Cat (Alternate Art)") == "Rescue Cat")
        #expect(CardName.base("Stingcaster Mage (Borderless) (0329)") == "Stingcaster Mage")
        #expect(CardName.base("The Great Gallant Bandit (Starlight Rare) (Extended Art)") == "The Great Gallant Bandit")
        #expect(CardName.base("Beyond the Brave Booster Box [1st Edition]") == "Beyond the Brave Booster Box")
    }
    @Test func baseKeepsANameThatIsOnlyABracketOrHasAnInnerOne() {
        #expect(CardName.base("(Untitled)") == "(Untitled)")
        #expect(CardName.base("B.F.M. (Big Furry Monster) Left") == "B.F.M. (Big Furry Monster) Left")
        #expect(CardName.base("  Rescue Cat  ") == "Rescue Cat")
    }
    @Test func searchKeyFoldsCaseAccentsAndPunctuation() {
        #expect(CardName.searchKey("\"A Case for K9\"") == "a case for k9")
        #expect(CardName.searchKey("Lim-Dûl's Vault") == "lim dul s vault")
        #expect(CardName.searchKey("K'Sante,  Courageous") == "k sante courageous")
        #expect(CardName.searchKey("KERRY eurodyne") == CardName.searchKey("Kerry Eurodyne"))
        #expect(CardName.searchKey("  ") == "")
    }
}
