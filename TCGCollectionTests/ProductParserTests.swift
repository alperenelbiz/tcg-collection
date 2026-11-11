import Foundation
import Testing
@testable import TCGCollection2

// Fixture products, trimmed from tcgcsv.com on 2026-11-11 (every field of a kept product is intact).
// groups-89.json: all 14 Riftbound sets.
// products-1.json (Magic, set 24684):
//   692977 Reality Fracture - Prerelease Pack (sealed, no SubType)
//   692993 Chandra, Chill of Compliance
//   692994 Bloodline Recollector (has P and T)
//   692997 Stingcaster Mage (Borderless) (0329) (two bracket groups)
//   706970 Ajani Resolute (Borderless)
// products-2.json (Yu-Gi-Oh!, set 24815):
//   711263 Beyond the Brave Booster Box [1st Edition] (sealed)
//   719829 Token: Joey and Red-Eyes Black Dragon
//   719834 Swiftwind Panther Warrior (Effect Monster)
//   719835 Swiftwind Panther Warrior (Starlight Rare)
// products-89.json (Riftbound, set 24819):
//   711362 Radiance - Booster Pack (sealed)
//   721334 Dockside Lock-Up
//   721337 Kai'Sa, Rebel (Champion Unit)
//   722282 Calm Rune (R02a) (Rune, name ends in a bracket)
// products-92.json (Cyberpunk, set 24884):
//   719684 Kerry Eurodyne - The Last Rockerboy
//   719686 Satori - Sword of Saburo
//   719687 Jackie Welles - Ride or Die Choom

struct ProductParserTests {
    @Test func setsOfRiftbound() throws {
        let sets = try ProductParser.sets(fixture("groups-89.json"), game: Games.game("riftbound")!)
        #expect(sets.count == 14)
        let radiance = try #require(sets.first { $0.groupID == 24819 })
        #expect(radiance.name == "Radiance" && radiance.gameID == "riftbound")
        #expect(radiance.publishedOn == TCGDate.date("2026-10-23T00:00:00"))
    }

    @Test func datesAreReadAsUTC() {
        #expect(TCGDate.date("2026-10-02T00:00:00")?.timeIntervalSince1970 == 1_790_899_200)
        let withFraction = TCGDate.date("2026-10-13T14:05:57.413")
        #expect(withFraction != nil)
        #expect(abs(withFraction!.timeIntervalSince1970 - (1_791_849_600 + 14 * 3600 + 5 * 60 + 57.413)) < 0.001)
        #expect(TCGDate.date("not a date") == nil)
    }

    @Test func aMagicCardKeepsItsFields() throws {
        let (cards, dropped) = try ProductParser.products(fixture("products-1.json"), game: Games.game("magic-the-gathering")!)
        #expect(dropped == 1)                                   // the sealed product
        let c = try #require(cards.first { $0.productID == 692993 })
        #expect(c.name == "Chandra, Chill of Compliance" && c.cardName == c.name && c.searchKey == "chandra chill of compliance")
        #expect(c.number == "212" && c.rarity == "M" && c.cardType == "Legendary Planeswalker — Chandra")
        #expect(c.typeFacets == ["Planeswalker"]); #expect(c.rulesText.hasPrefix("[+1]: Surveil 1."))
        #expect(c.url == "https://www.tcgplayer.com/product/692993/magic-reality-fracture-chandra-chill-of-compliance")
        #expect(c.groupID == 24684 && c.gameID == "magic-the-gathering")
    }

    @Test func bracketPrintingsShareACardName() throws {
        let (cards, _) = try ProductParser.products(fixture("products-1.json"), game: Games.game("magic-the-gathering")!)
        #expect(cards.first { $0.productID == 692997 }?.cardName == "Stingcaster Mage")
        #expect(cards.first { $0.productID == 706970 }?.cardName == "Ajani Resolute")
    }

    @Test func aProductWithNumberAndRarityButNoTypeIsKept() throws {
        let inlineBody = Data("""
        {"success":true,"errors":[],"results":[
        {"productId":1,"name":"Promo Dragon","groupId":7,"url":"https://example.test/1","imageUrl":null,
         "extendedData":[{"name":"Number","value":"TP3-001"},{"name":"Rarity","value":"Ultra Rare"}]},
        {"productId":2,"name":"Sealed Box","groupId":7,"url":"https://example.test/2","imageUrl":null,
         "extendedData":[{"name":"UPC","value":"123"}]}
        ],"totalItems":2}
        """.utf8)
        let (cards, dropped) = try ProductParser.products(inlineBody, game: Games.game("yu-gi-oh")!)
        #expect(cards.count == 1 && dropped == 1); #expect(cards[0].cardType == "" && cards[0].typeFacets.isEmpty)
        #expect(cards[0].number == "TP3-001")
    }
    @Test func everyFieldIsKept() throws {
        let (cards, _) = try ProductParser.products(fixture("products-1.json"), game: Games.game("magic-the-gathering")!)
        let creature = try #require(cards.first { $0.productID == 692994 })
        #expect(creature.fields["P"] == "2" && creature.fields["T"] == "2")
        #expect(creature.typeFacets == ["Creature"])
    }

    @Test func yugiohKeepsTheSetCodeAndDropsTheBox() throws {
        let (cards, dropped) = try ProductParser.products(fixture("products-2.json"), game: Games.game("yu-gi-oh")!)
        #expect(dropped == 1)
        #expect(cards.first { $0.productID == 719829 }?.number == "TKN5-EN052")
        #expect(cards.first { $0.productID == 719829 }?.typeFacets == ["Token"])
        #expect(cards.first { $0.productID == 719834 }?.typeFacets == ["Monster"])
        #expect(cards.first { $0.productID == 719835 }?.cardName == "Swiftwind Panther Warrior")
    }

    @Test func riftboundKeepsRunesAndDropsThePack() throws {
        let (cards, dropped) = try ProductParser.products(fixture("products-89.json"), game: Games.game("riftbound")!)
        #expect(dropped == 1)
        #expect(cards.count == 3)
        #expect(cards.first { $0.productID == 721334 }?.name == "Dockside Lock-Up")
        #expect(cards.first { $0.productID == 721337 }?.typeFacets == ["Champion Unit"])
        #expect(cards.first { $0.productID == 722282 }?.cardName == "Calm Rune")
    }

    @Test func cyberpunkFieldsAreKeptAsText() throws {
        let (cards, dropped) = try ProductParser.products(fixture("products-92.json"), game: Games.game("cyberpunk")!)
        #expect(dropped == 0)
        let k = try #require(cards.first { $0.productID == 719684 })
        #expect(k.cardType == "Unit" && k.fields["Color"] == "Red" && k.fields["Eddies"] == "FALSE")
    }

    @Test func aBodyThatIsNotTheShapeThrows() {
        let xml = Data("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>".utf8)
        #expect(throws: (any Error).self) { try ProductParser.products(xml, game: Games.game("riftbound")!) }
        #expect(throws: (any Error).self) { try ProductParser.products(Data(), game: Games.game("riftbound")!) }
    }

    @Test func aBodyWithSuccessFalseThrows() throws {
        let body = Data(#"{"success":false,"errors":["boom"],"results":[]}"#.utf8)
        #expect(throws: ProductParserError.unsuccessful) { try ProductParser.sets(body, game: Games.game("riftbound")!) }
        #expect(throws: ProductParserError.unsuccessful) { try ProductParser.products(body, game: Games.game("riftbound")!) }
        let fine = Data(#"{"success":true,"errors":[],"results":[],"totalItems":0}"#.utf8)
        #expect(try ProductParser.products(fine, game: Games.game("riftbound")!).cards.isEmpty)
    }
}
