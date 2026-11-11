import Foundation
import Testing
@testable import TCGCollection2

struct PictureStoreTests {
    @Test func aPictureIsDownloadedOnce() async throws {                // the YGOPRODeck rule
        let fake = FakeFetcher(body: Data(repeating: 7, count: 5000)); let store = PictureStore(directory: tempDir(), fetcher: fake)
        let url = URL(string: "https://images.ygoprodeck.com/images/cards_small/80181649.jpg")!
        async let a = store.data(for: url); async let b = store.data(for: url)
        #expect(await a?.count == 5000); #expect(await b?.count == 5000)
        #expect(await store.data(for: url) != nil); #expect(await fake.calls == 1)
        let again = PictureStore(directory: store.directory, fetcher: fake)     // a new run reads the disk
        #expect(await again.data(for: url) != nil); #expect(await fake.calls == 1)
    }

    @Test func aBadAnswerIsNotCachedAndNotRetriedInTheSameRun() async {
        let fake = FakeFetcher(body: Data("nope".utf8), status: 404); let store = PictureStore(directory: tempDir(), fetcher: fake)
        let url = URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/1_200w.jpg")!
        #expect(await store.data(for: url) == nil); #expect(await store.data(for: url) == nil); #expect(await fake.calls == 1)
    }

    @Test func aTinyBodyIsRejected() async {
        let fake = FakeFetcher(body: Data(repeating: 1, count: 500)); let store = PictureStore(directory: tempDir(), fetcher: fake)
        #expect(await store.data(for: URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/2_200w.jpg")!) == nil)
    }

    @Test func smallAndLargeOfOneCardAreDifferentFiles() async {
        let small = URL(string: "https://images.ygoprodeck.com/images/cards_small/1.jpg")!
        let large = URL(string: "https://images.ygoprodeck.com/images/cards/1.jpg")!
        let fake = FakeFetcher(bodies: [small: Data(repeating: 1, count: 2000), large: Data(repeating: 2, count: 3000)])
        let store = PictureStore(directory: tempDir(), fetcher: fake)
        #expect(await store.data(for: small)?.count == 2000)
        #expect(await store.data(for: large)?.count == 3000)
        #expect(await fake.calls == 2)
    }
}
