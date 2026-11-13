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

    /// I3: Wi-Fi off, then on again. A thrown error is not remembered: the next call tries again and gets the picture.
    @Test func aNetworkErrorIsNotRemembered() async {
        let fake = FakeFetcher(body: Data(repeating: 7, count: 5000), networkErrors: 1)
        let store = PictureStore(directory: tempDir(), fetcher: fake)
        let url = URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/3_200w.jpg")!
        #expect(await store.data(for: url) == nil)
        #expect(await store.data(for: url)?.count == 5000)
        #expect(await fake.calls == 2)
    }

    @Test func aTinyBodyIsRejected() async {
        let fake = FakeFetcher(body: Data(repeating: 1, count: 500)); let store = PictureStore(directory: tempDir(), fetcher: fake)
        #expect(await store.data(for: URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/2_200w.jpg")!) == nil)
    }

    // MARK: At most 4 downloads at a time (constraints), over every caller: the gallery's cells and a PDF export

    private static func urls(_ range: ClosedRange<Int>) -> [URL] {
        range.map { URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\($0)_200w.jpg")! }
    }

    private func until(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < end else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func twelvePicturesAskedAtOnceDownloadFourAtATime() async throws {
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"))
        let store = PictureStore(directory: tempDir(), fetcher: fetcher)
        let answers = await withTaskGroup(of: Data?.self) { group in
            for url in Self.urls(1...12) { group.addTask { await store.data(for: url) } }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(answers.count == 12 && answers.allSatisfy { $0 != nil })
        #expect(await fetcher.mostAtOnce == 4)
        let calls = await fetcher.calls
        #expect(calls.count == 12 && calls.values.allSatisfy { $0 == 1 })
        #expect(await store.downloadsRunning == 0)
        #expect(await store.downloadsWaiting == 0)
    }

    /// A picture on disk answers at once, also while every download slot is taken.
    @Test func aCachedPictureDoesNotWaitForADownload() async throws {
        let picture = try fixture("picture.jpg")
        let directory = tempDir()
        let cached = Self.urls(99...99)[0]
        #expect(await PictureStore(directory: directory, fetcher: FakeFetcher(body: picture)).data(for: cached) != nil)
        let fetcher = PictureFetcher(body: picture, gated: true)
        let store = PictureStore(directory: directory, fetcher: fetcher)
        let held = Self.urls(1...4).map { url in Task { await store.data(for: url) } }
        try await until { await fetcher.waiting == 4 }
        #expect(await store.data(for: cached) != nil)
        let fifth = Task { await store.data(for: Self.urls(5...5)[0]) }
        try await until { await store.downloadsWaiting == 1 }
        #expect(await fetcher.calls.count == 4)                            // the fifth waits for a slot
        await fetcher.open()
        for task in held { #expect(await task.value != nil) }
        #expect(await fifth.value != nil)
        #expect(await fetcher.mostAtOnce == 4)
    }

    /// A caller cancelled while it waits for a slot leaves the queue, downloads nothing and takes no slot with it.
    @Test func aCancelledWaiterTakesNoSlot() async throws {
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"), gated: true)
        let store = PictureStore(directory: tempDir(), fetcher: fetcher)
        let held = Self.urls(1...4).map { url in Task { await store.data(for: url) } }
        try await until { await fetcher.waiting == 4 }
        let waiter = Task { await store.data(for: Self.urls(5...5)[0]) }
        try await until { await store.downloadsWaiting == 1 }
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(await store.downloadsWaiting == 0)
        await fetcher.open()
        for task in held { #expect(await task.value != nil) }
        #expect(await store.downloadsRunning == 0)                          // every slot came back
        #expect(await fetcher.calls[Self.urls(5...5)[0]] == nil)
        // The slots are free: four new pictures download at once again, and are answered.
        let fresh = await withTaskGroup(of: Data?.self) { group in
            for url in Self.urls(6...9) { group.addTask { await store.data(for: url) } }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(fresh.allSatisfy { $0 != nil })
        // The cancelled picture can be asked for again.
        #expect(await store.data(for: Self.urls(5...5)[0]) != nil)
    }

    /// Two callers of one picture that both waited for a slot: the second finds the first's download and joins it.
    @Test func twoWaitersOfOnePictureDownloadItOnce() async throws {
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"), gated: true)
        let store = PictureStore(directory: tempDir(), fetcher: fetcher)
        let held = Self.urls(1...4).map { url in Task { await store.data(for: url) } }
        try await until { await fetcher.waiting == 4 }
        let url = Self.urls(5...5)[0]
        let first = Task { await store.data(for: url) }, second = Task { await store.data(for: url) }
        try await until { await store.downloadsWaiting == 2 }
        await fetcher.open()
        for task in held { _ = await task.value }
        #expect(await first.value != nil)
        #expect(await second.value != nil)
        #expect(await fetcher.calls[url] == 1)
        #expect(await store.downloadsRunning == 0)
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
