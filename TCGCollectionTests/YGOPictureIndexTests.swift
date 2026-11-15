import Foundation
import Testing
@testable import TCGCollection2

struct YGOPictureIndexTests {
    @Test func aCardWithoutSetsIsFoundByName() throws {
        let index = try YGOPictureIndex(cardinfo: fixture("cardinfo-sample.json"))
        #expect(index.pictureID(number: "", name: "Hand Written Promo") == 99999001)
        #expect(index.codes.values.contains(99999001) == false)
    }

    @Test func theIndexSurvivesEncodingAndRefreshWritesIt() async throws {
        let paths = AppPaths(root: tempDir())
        let body = try fixture("cardinfo-sample.json")
        let fake = FakeFetcher(body: body)
        let loader = YGOIndexLoader(paths: paths, fetcher: fake)
        #expect(await loader.current() == nil)
        let fresh = try await loader.refresh()
        #expect(await fake.calls == 1)
        let again = YGOIndexLoader(paths: paths, fetcher: fake)
        #expect(await again.current() == fresh)
        #expect(fresh.pictureID(number: "JUSH-EN040", name: "") == 80181649)
    }

    @Test func aBadStatusThrowsAndWritesNothing() async {
        let paths = AppPaths(root: tempDir())
        let loader = YGOIndexLoader(paths: paths, fetcher: FakeFetcher(body: Data(), status: 503))
        await #expect(throws: (any Error).self) { try await loader.refresh() }
        #expect(FileManager.default.fileExists(atPath: paths.ygoIndex.path) == false)
    }

    @Test func theSampleGivesEachCardItsFrameType() throws {
        let index = try YGOPictureIndex(cardinfo: fixture("cardinfo-sample.json"))
        #expect(index.type(name: "Stardust Dragon") == "synchro")
        #expect(index.type(name: "Dark Magician") == "normal")
        #expect(index.type(name: "\"A Case for K9\"") == "spell")
        #expect(index.types.count == 4 && index.version == YGOPictureIndex.currentVersion && index.isCurrent)
    }

    @Test func aTypeIsFoundWheneverThePictureIsFoundByName() throws {
        let index = try YGOPictureIndex(cardinfo: fixture("cardinfo-sample.json"))
        for spelling in ["stardust dragon", "STARDUST  DRAGON", "Stardust-Dragon", "Stardüst Dragon", "A Case for K9"] {
            #expect(index.pictureID(number: "", name: spelling) != nil)
            #expect(index.type(name: spelling) != nil)
        }
        #expect(index.type(name: "No Such Card") == nil)
    }

    @Test func aKeptBracketAndATokenGiveNoType() throws {
        let body = Data(#"""
        {"data":[{"name":"Absolute Authority","frameType":"skill","card_images":[{"id":1}]},
                 {"name":"Joey Token","frameType":"token","card_images":[{"id":2}]}]}
        """#.utf8)
        let index = try YGOPictureIndex(cardinfo: body)
        #expect(index.type(name: "Absolute Authority") == "skill")
        #expect(index.type(name: "Absolute Authority (Skill Card)") == nil)
        #expect(index.type(name: "Token: Joey Token") == nil)
        #expect(index.type(name: "Joey Token") == "token")
    }

    @Test func twoCardsWithOneNameKeyKeepTheFirstType() throws {
        let body = Data(#"""
        {"data":[{"name":"Foo-Bar","frameType":"effect","card_images":[{"id":1}]},
                 {"name":"Foo Bar","frameType":"fusion","card_images":[{"id":2}]},
                 {"name":"No Type","card_images":[{"id":3}]}]}
        """#.utf8)
        let index = try YGOPictureIndex(cardinfo: body)
        #expect(index.type(name: "Foo Bar") == "effect" && index.pictureID(number: "", name: "Foo Bar") == 1)
        #expect(index.type(name: "No Type") == nil && index.pictureID(number: "", name: "No Type") == 3)
    }

    @Test func anIndexFileOfTheOldShapeDecodesWithoutTypesAndIsNotCurrent() throws {
        let old = Data(#"{"codes":{"JUSH-EN040":80181649},"names":{"dark magician":46986414}}"#.utf8)
        let index = try JSONDecoder().decode(YGOPictureIndex.self, from: old)
        #expect(index.version == 0 && index.isCurrent == false && index.types.isEmpty)
        #expect(index.pictureID(number: "JUSH-EN040", name: "") == 80181649)
        #expect(index.type(name: "Dark Magician") == nil)
    }

    @Test func aRefreshedIndexRoundTripsWithItsTypesAndIsCurrent() async throws {
        let paths = AppPaths(root: tempDir())
        let fake = FakeFetcher(body: try fixture("cardinfo-sample.json"))
        let fresh = try await YGOIndexLoader(paths: paths, fetcher: fake).refresh()
        #expect(await fake.calls == 1)
        let again = try #require(await YGOIndexLoader(paths: paths, fetcher: fake).current())
        #expect(again == fresh && again.isCurrent && again.type(name: "Stardust Dragon") == "synchro")
    }

    @Test func theTypesAddLessThanTheNamesAlreadyCost() throws {
        // 2,000 made-up cards with real-looking names and 8 frame types: the per-type overhead is small beside the cards.
        let frames = ["normal", "effect", "fusion", "synchro", "xyz", "link", "spell", "trap"]
        let cards = (0..<2000).map { n in
            #"{"name":"Blue-Eyes Card Number \#(n)","frameType":"\#(frames[n % 8])","card_images":[{"id":\#(n + 1)}]}"#
        }
        let index = try YGOPictureIndex(cardinfo: Data(#"{"data":[\#(cards.joined(separator: ","))]}"#.utf8))
        var picturesOnly = index
        picturesOnly.types = [:]
        let withTypes = try JSONEncoder().encode(index).count
        let without = try JSONEncoder().encode(picturesOnly).count
        let namesOnly = try JSONEncoder().encode(index.names).count
        print("YGO index bytes (2000 cards): without types \(without), with types \(withTypes), names alone \(namesOnly)")
        #expect(index.types.count == 2000)
        #expect(withTypes - without < namesOnly)
    }
}
