import Foundation
import Testing
@testable import TCGCollection2

struct PictureStoreTests {
    @Test func aPictureIsDownloadedOnce() async throws {                // the YGOPRODeck rule
        let fake = FakeFetcher(body: Data(repeating: 7, count: 5000)); let store = PictureStore(directory: tempDir(), fetcher: fake)
        let url = URL(string: "https://images.ygoprodeck.com/images/cards/80181649.jpg")!
        async let a = store.data(for: url); async let b = store.data(for: url)
        #expect(await a?.count == 5000); #expect(await b?.count == 5000)
        #expect(await store.data(for: url) != nil); #expect(await fake.calls == 1)
        let again = PictureStore(directory: store.directory, fetcher: fake)     // a new run reads the disk
        #expect(await again.data(for: url) != nil); #expect(await fake.calls == 1)
    }

    @Test func aBadAnswerIsNotCachedAndNotRetriedInTheSameRun() async {
        let fake = FakeFetcher(body: Data("nope".utf8), status: 404); let store = PictureStore(directory: tempDir(), fetcher: fake)
        let url = URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/1_in_1000x1000.jpg")!
        #expect(await store.data(for: url) == nil); #expect(await store.data(for: url) == nil); #expect(await fake.calls == 1)
    }

    /// I3: Wi-Fi off, then on again. A thrown error is not remembered: the next call tries again and gets the picture.
    @Test func aNetworkErrorIsNotRemembered() async {
        let fake = FakeFetcher(body: Data(repeating: 7, count: 5000), networkErrors: 1)
        let store = PictureStore(directory: tempDir(), fetcher: fake)
        let url = URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/3_in_1000x1000.jpg")!
        #expect(await store.data(for: url) == nil)
        #expect(await store.data(for: url)?.count == 5000)
        #expect(await fake.calls == 2)
    }

    @Test func aTinyBodyIsRejected() async {
        let fake = FakeFetcher(body: Data(repeating: 1, count: 500)); let store = PictureStore(directory: tempDir(), fetcher: fake)
        #expect(await store.data(for: URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/2_in_1000x1000.jpg")!) == nil)
    }

    // MARK: At most 4 downloads at a time (constraints), over every caller: the gallery's cells and a PDF export

    private static func urls(_ range: ClosedRange<Int>) -> [URL] {
        range.map { URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\($0)_in_1000x1000.jpg")! }
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

    // MARK: The cache limit (feedback 1; phase 6B): 3 GB on the Mac, 1 GB on the iPhone, cleaned once per launch,
    // the least recently used first

    private static let day: TimeInterval = 86_400
    private static func at(_ days: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + days * day) }
    private static func file(_ name: String, _ bytes: Int, _ days: Double) -> CachedPicture {
        CachedPicture(name: name, bytes: bytes, used: at(days))
    }

    @Test func theCacheLimitPerPlatform() {                              // A63
        #if os(iOS)
        #expect(PictureStore.cacheLimit == 1 * 1024 * 1024 * 1024)
        #expect(PictureStore.cacheLimit == 1_073_741_824)
        #else
        #expect(PictureStore.cacheLimit == 3 * 1024 * 1024 * 1024)
        #expect(PictureStore.cacheLimit == 3_221_225_472)
        #endif
    }

    @Test func underTheLimitNothingIsDeleted() {
        #expect(PictureStore.filesToDelete([], limit: 1000).isEmpty)
        let files = [Self.file("a.jpg", 400, 1), Self.file("b.jpg", 600, 2)]       // 1000: at the limit, not over it
        #expect(PictureStore.filesToDelete(files, limit: 1000).isEmpty)
    }

    /// Over the limit: the least recently used first, until the rest is at most 90 % of the limit.
    @Test func overTheLimitTheOldestGoFirstUntilNinetyPercent() {
        let files = [Self.file("e.jpg", 250, 5), Self.file("a.jpg", 250, 3), Self.file("c.jpg", 250, 1),
                     Self.file("b.jpg", 250, 4), Self.file("d.jpg", 250, 2)]            // 1250 of 1000
        // c (day 1): 1000 left, still over 900; d (day 2): 750.
        #expect(PictureStore.filesToDelete(files, limit: 1000) == ["c.jpg", "d.jpg"])
        // One file is enough when it brings the rest to exactly 90 %.
        let two = [Self.file("new.jpg", 900, 9), Self.file("old.jpg", 200, 1)]
        #expect(PictureStore.filesToDelete(two, limit: 1000) == ["old.jpg"])
    }

    @Test func equalDatesGoInNameOrder() {
        let files = [Self.file("z.jpg", 300, 1), Self.file("m.jpg", 300, 1), Self.file("a.jpg", 300, 1), Self.file("k.jpg", 300, 1)]
        #expect(PictureStore.filesToDelete(files, limit: 1000) == ["a.jpg"])            // 1200 -> 900
        #expect(PictureStore.filesToDelete(files, limit: 600) == ["a.jpg", "k.jpg", "m.jpg"])  // 1200 -> 300, at most 540
    }

    /// The small pictures of earlier builds are never asked for again: deleted at the first cleaning, whatever the size.
    @Test func theOldSmallPicturesAreAlwaysDeleted() {
        let files = [Self.file("tcgplayer-cdn.tcgplayer.com-product-721334_in_1000x1000.jpg", 100, 1),
                     Self.file("tcgplayer-cdn.tcgplayer.com-product-721334_200w.jpg", 10, 9),
                     Self.file("images.ygoprodeck.com-cards-80181649.jpg", 100, 1),
                     Self.file("images.ygoprodeck.com-cards_small-80181649.jpg", 10, 9)]
        #expect(PictureStore.filesToDelete(files, limit: 1_000_000)
                == ["images.ygoprodeck.com-cards_small-80181649.jpg", "tcgplayer-cdn.tcgplayer.com-product-721334_200w.jpg"])
        // They do not count towards the limit: the full-size pictures alone are under it here.
        #expect(PictureStore.filesToDelete(files, limit: 200)
                == ["images.ygoprodeck.com-cards_small-80181649.jpg", "tcgplayer-cdn.tcgplayer.com-product-721334_200w.jpg"])
    }

    /// The name rule of the old small pictures, on the names `PictureStore` gives its files (`<host>-<two components>`).
    @Test func theOldSmallNameRule() {
        #expect(PictureStore.isOldSmallPicture("tcgplayer-cdn.tcgplayer.com-product-1_200w.jpg"))
        #expect(PictureStore.isOldSmallPicture("images.ygoprodeck.com-cards_small-1.jpg"))
        #expect(!PictureStore.isOldSmallPicture("tcgplayer-cdn.tcgplayer.com-product-1_in_1000x1000.jpg"))
        #expect(!PictureStore.isOldSmallPicture("images.ygoprodeck.com-cards-1.jpg"))
        #expect(!PictureStore.isOldSmallPicture("notes_200w.txt"))
        // The store names a new download that way: the old small address and the full one are different files.
        let store = PictureStore(directory: URL(fileURLWithPath: "/nowhere"), fetcher: FakeFetcher(body: Data()))
        #expect(store.fileName(for: URL(string: "https://images.ygoprodeck.com/images/cards_small/1.jpg")!)
                == "images.ygoprodeck.com-cards_small-1.jpg")
        #expect(store.fileName(for: URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/1_200w.jpg")!)
                == "tcgplayer-cdn.tcgplayer.com-product-1_200w.jpg")
    }

    /// The file step: it lists only the picture files (`*.jpg`, not hidden, not in a subfolder) of the store's own folder
    /// and deletes what `filesToDelete` names. Anything else in or next to the folder survives.
    @Test func cleaningDeletesOnlyPictureFilesOfItsFolder() throws {
        let fm = FileManager.default
        let caches = tempDir()
        let pictures = caches.appending(path: "pictures", directoryHint: .isDirectory)
        let archives = caches.appending(path: "archives", directoryHint: .isDirectory)
        try fm.createDirectory(at: pictures.appending(path: "sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        func put(_ url: URL, _ bytes: Int, _ days: Double) throws {
            try Data(repeating: 1, count: bytes).write(to: url)
            try fm.setAttributes([.modificationDate: Self.at(days)], ofItemAtPath: url.path)
        }
        try put(pictures.appending(path: "tcgplayer-cdn.tcgplayer.com-product-1_in_1000x1000.jpg"), 3000, 1)   // oldest
        try put(pictures.appending(path: "tcgplayer-cdn.tcgplayer.com-product-2_in_1000x1000.jpg"), 3000, 3)
        try put(pictures.appending(path: "images.ygoprodeck.com-cards-3.jpg"), 3000, 2)
        try put(pictures.appending(path: "tcgplayer-cdn.tcgplayer.com-product-4_200w.jpg"), 100, 9)
        try put(pictures.appending(path: "notes.txt"), 50_000, 0)                        // not a picture
        try put(pictures.appending(path: ".hidden.jpg"), 50_000, 0)                       // hidden
        try put(pictures.appending(path: "sub/deep.jpg"), 50_000, 0)                      // in a subfolder
        try put(archives.appending(path: "prices-2026-11-13.ppmd.7z"), 50_000, 0)        // next to the folder
        let store = PictureStore(directory: pictures, fetcher: FakeFetcher(body: Data()))
        // 9000 bytes of full-size pictures over a limit of 8000: the oldest goes (6000 ≤ 7200), and the old small one.
        let deleted = store.clean(limit: 8000)
        #expect(deleted == ["tcgplayer-cdn.tcgplayer.com-product-4_200w.jpg",
                            "tcgplayer-cdn.tcgplayer.com-product-1_in_1000x1000.jpg"])
        let left = try fm.contentsOfDirectory(atPath: pictures.path).sorted()
        #expect(left == [".hidden.jpg", "images.ygoprodeck.com-cards-3.jpg", "notes.txt", "sub",
                         "tcgplayer-cdn.tcgplayer.com-product-2_in_1000x1000.jpg"])
        #expect(fm.fileExists(atPath: pictures.appending(path: "sub/deep.jpg").path))
        #expect(fm.fileExists(atPath: archives.appending(path: "prices-2026-11-13.ppmd.7z").path))
        // A second cleaning finds nothing to do; a folder that is not there is no error.
        #expect(store.clean(limit: 8000).isEmpty)
        #expect(PictureStore(directory: caches.appending(path: "missing"), fetcher: FakeFetcher(body: Data())).clean(limit: 1).isEmpty)
    }

    /// "Used" is the file's modification date: a picture read from disk for a caller gets now, once per file per run, so
    /// scrolling does not write dates over and over. A new run (a new store) sets it again.
    @Test func aReadMarksThePictureUsedOncePerRun() async throws {
        let fm = FileManager.default
        let directory = tempDir()
        let url = URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/7_in_1000x1000.jpg")!
        let first = PictureStore(directory: directory, fetcher: FakeFetcher(body: Data(repeating: 7, count: 5000)))
        #expect(await first.data(for: url) != nil)                                       // downloaded: now already
        let file = directory.appending(path: first.fileName(for: url))
        let old = Self.at(-1000)
        func used() throws -> Date { try #require(fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) }
        func age() throws { try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path) }

        try age()
        #expect(await first.data(for: url) != nil)                                       // downloaded in this run: not set again
        #expect(try used() == old)

        let second = PictureStore(directory: directory, fetcher: FakeFetcher(body: Data()))   // the next launch
        #expect(await second.data(for: url) != nil)
        #expect(try abs(used().timeIntervalSinceNow) < 60)
        try age()
        #expect(await second.data(for: url) != nil)                                      // once per file per run
        #expect(try used() == old)
    }
}
