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
}
