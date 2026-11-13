import Foundation
import PDFKit
import Testing
@testable import TCGCollection2

/// C11 and Review Focus 5: the export collects the pictures through `PictureStore` (the cache first, each address once,
/// 4 at a time; a failure is the grey block), reports `done / total`, can be cancelled, and then draws the PDF.
@MainActor
struct PDFExportTests {
    private static func urls(_ count: Int) -> [URL] {
        (1...count).map { URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\($0)_200w.jpg")! }
    }

    private static func job(_ pictures: [URL?]) -> PDFJob {
        PDFJob(title: "Riftbound — For Sale — 13 November 2026", fileName: "riftbound-for-sale-2026-11-13.pdf",
               items: pictures.enumerated().map { PDFSource(name: "Card \($0.offset + 1)", count: 1, price: nil, picture: $0.element) })
    }

    /// A store whose disk cache already holds the pictures of `cached` (fetched once by a store of their own).
    private func store(fetcher: PictureFetcher, cached: [URL]) async throws -> PictureStore {
        let directory = tempDir()
        let warm = PictureStore(directory: directory, fetcher: FakeFetcher(body: try fixture("picture.jpg")))
        for url in cached { #expect(await warm.data(for: url) != nil) }
        return PictureStore(directory: directory, fetcher: fetcher)
    }

    private func until(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < end else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func names(_ data: Data) throws -> String {
        try #require(PDFDocument(data: data)?.page(at: 0)?.string)
    }

    @Test func tenItemsWithThreeCachedFetchSevenFourAtATime() async throws {
        let urls = Self.urls(10)
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"))
        let pictures = try await store(fetcher: fetcher, cached: Array(urls.prefix(3)))
        let export = PDFExport()
        let data = try #require(await export.make(Self.job(urls), pictures: pictures))
        #expect(await fetcher.calls.values.reduce(0, +) == 7)
        #expect(Set(await fetcher.calls.keys) == Set(urls.dropFirst(3)))
        #expect(await fetcher.calls.values.allSatisfy { $0 == 1 })        // none twice
        #expect(await fetcher.mostAtOnce == 4)                            // four at a time, never more
        let page = try names(data)
        for index in 1...10 { #expect(page.contains("Card \(index)")) }
        #expect(export.progress == nil)
    }

    /// Two items of one picture (two finishes of one printing) need it once.
    @Test func aPictureOfTwoItemsIsFetchedOnce() async throws {
        let url = Self.urls(1)[0]
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"))
        let pictures = try await store(fetcher: fetcher, cached: [])
        _ = try #require(await PDFExport().make(Self.job([url, url, nil]), pictures: pictures))
        #expect(await fetcher.calls == [url: 1])
    }

    /// The progress counts the items whose picture is settled: those without a picture and the cached ones at once, the
    /// others as their fetch ends. The label is the button's while it runs.
    @Test func itReportsDoneOfTotal() async throws {
        let urls = Self.urls(9)
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"), gated: true)
        let pictures = try await store(fetcher: fetcher, cached: Array(urls.prefix(3)))
        let export = PDFExport()
        let task = try #require(export.start(Self.job(urls + [nil]), pictures: pictures))
        #expect(export.progress == PDFProgress(done: 0, total: 10))      // at once, before any picture
        #expect(export.isRunning)
        try await until { await fetcher.waiting == 4 }
        #expect(export.progress == PDFProgress(done: 4, total: 10))      // 3 cached, 1 without a picture
        #expect(export.progress?.label == "Making PDF… 4 / 10")
        await fetcher.open()
        await task.value
        #expect(export.progress == nil)
        #expect(!export.isRunning)
        #expect(export.made?.fileName == "riftbound-for-sale-2026-11-13.pdf")
        #expect(try names(try #require(export.made?.data)).contains("Card 10"))
        #expect(await fetcher.calls.values.reduce(0, +) == 6)
    }

    /// A cancel stops the fetches that have not started, and nothing is written or kept.
    @Test func aCancelStopsAndWritesNothing() async throws {
        let urls = Self.urls(10)
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"), gated: true)
        let pictures = try await store(fetcher: fetcher, cached: [])
        let file = tempDir().appending(path: "out.pdf")
        let export = PDFExport()
        let task = try #require(export.start(Self.job(urls), pictures: pictures, writingTo: file))
        try await until { await fetcher.waiting == 4 }
        export.cancel()
        #expect(export.progress == nil)
        #expect(!export.isRunning)
        await fetcher.open()
        await task.value
        #expect(await fetcher.calls.values.reduce(0, +) == 4)            // no fetch after the cancel
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(export.made == nil)
        #expect(export.progress == nil)
    }

    /// While one export runs, a second one does not start; after a cancel a new one can.
    @Test func aSecondExportCannotStartWhileOneRuns() async throws {
        let fetcher = PictureFetcher(body: try fixture("picture.jpg"), gated: true)
        let pictures = try await store(fetcher: fetcher, cached: [])
        let export = PDFExport()
        let first = try #require(export.start(Self.job(Self.urls(2)), pictures: pictures))
        #expect(export.start(Self.job(Self.urls(5)), pictures: pictures) == nil)
        #expect(export.progress == PDFProgress(done: 0, total: 2))
        export.cancel()
        await fetcher.open()
        await first.value
        let second = try #require(export.start(Self.job(Self.urls(3)), pictures: pictures))
        await second.value
        #expect(export.made != nil)
        #expect(export.progress == nil)
        export.cancel()                                                   // the screen went away: nothing is kept
        #expect(export.made == nil)
    }

    /// The save panel's end: a save or a cancel says nothing; any other failure is said in the status line.
    @Test func aFailedSaveIsSaidAndASaveOrACancelIsNot() {
        #expect(PDFExport.saveNotice(.success(URL(fileURLWithPath: "/tmp/riftbound-for-sale-2026-11-13.pdf"))) == nil)
        #expect(PDFExport.saveNotice(.failure(CocoaError(.userCancelled))) == nil)
        #expect(PDFExport.saveNotice(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))) == nil)
        let error = CocoaError(.fileWriteNoPermission)
        #expect(PDFExport.saveNotice(.failure(error)) == "The PDF could not be saved: \(error.localizedDescription)")
        let other = URLError(.cannotWriteToFile)
        #expect(PDFExport.saveNotice(.failure(other)) == "The PDF could not be saved: \(other.localizedDescription)")
    }

    /// `-exportPDF` writes once the list is read by a join made on a settled catalog with the game's prices.
    @Test func theLaunchExportWaitsForASettledCatalogAndPrices() {
        func joined(settled: Bool, day: String?) -> CollectionJoin {
            CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 2, priceDay: day, catalogSettled: settled)
        }
        #expect(PDFExport.launchReady(listRead: true, joined: joined(settled: true, day: "2026-11-12")))
        #expect(!PDFExport.launchReady(listRead: false, joined: joined(settled: true, day: "2026-11-12")))
        #expect(!PDFExport.launchReady(listRead: true, joined: joined(settled: false, day: "2026-11-12")))
        #expect(!PDFExport.launchReady(listRead: true, joined: joined(settled: true, day: nil)))
        #expect(!PDFExport.launchReady(listRead: true, joined: nil))
    }

    /// Every picture fails (a bad answer, or offline): a PDF with the names and grey blocks, each address asked once.
    @Test func allPicturesFailingGivesAPDFWithNamesOnly() async throws {
        let urls = Self.urls(10)
        let fetcher = PictureFetcher(body: Data("not found".utf8), status: 404)
        let pictures = try await store(fetcher: fetcher, cached: [])
        let file = tempDir().appending(path: "out.pdf")
        let export = PDFExport()
        await export.start(Self.job(urls), pictures: pictures, writingTo: file)?.value
        let data = try Data(contentsOf: file)
        #expect(data.starts(with: Data("%PDF".utf8)))
        #expect(export.made == nil)                                       // written to the file, no save panel
        let page = try names(data)
        for index in 1...10 { #expect(page.contains("Card \(index)")) }
        let picture = try PagePicture(data)
        for slot in 0..<10 {
            #expect(picture.color(at: ListPDF.pictureRect(slot: slot, firstPage: true).center) == RGB(r: 0xE6, g: 0xE6, b: 0xE6))
        }
        let calls = await fetcher.calls
        #expect(calls.count == 10 && calls.values.allSatisfy { $0 == 1 })
    }

    // MARK: What the lists give the PDF

    /// For Sale: the printing's product name, ` · <finish>` for a finish other than Normal, the for-sale count, the
    /// printing's own price, the small picture of the product. A printing the catalog lacks: its saved name, no picture.
    @Test func forSaleItemsAreThePrintings() throws {
        let game = try #require(Games.game("riftbound"))
        let dockside = product(id: 721334, name: "Dockside Lock-Up")
        func entry(_ id: Int, finish: String, count: Int, name: String, product: ProductRecord?, price: ShownPrice?) -> CollectionEntry {
            CollectionEntry(row: CollectionRow(productID: id, finish: finish, count: count, condition: "", name: name),
                            product: product, setName: "", price: price, copiesOfCard: count)
        }
        let price = ShownPrice(amount: 5.12, isLow: false)
        let items = PDFSource.forSale([entry(721334, finish: "Normal", count: 2, name: "Dockside Lock-Up", product: dockside, price: price),
                                       entry(721334, finish: "Foil", count: 1, name: "Dockside Lock-Up", product: dockside, price: nil),
                                       entry(9, finish: "normal", count: 1, name: "Gone Card", product: nil, price: nil)],
                                      game: game, ygo: nil)
        let picture = URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/721334_200w.jpg")
        #expect(items == [PDFSource(name: "Dockside Lock-Up", count: 2, price: price, picture: picture),
                          PDFSource(name: "Dockside Lock-Up · Foil", count: 1, price: nil, picture: picture),
                          PDFSource(name: "Gone Card", count: 1, price: nil, picture: nil)])
    }

    /// Wanted: the card's name, the wanted count, the card's price as the screen shows it, the picture of the shown
    /// printing. A card without a printing: its saved name, no picture.
    @Test func wantedItemsAreTheCards() throws {
        let game = try #require(Games.game("riftbound"))
        let shown = product(id: 721334, name: "Dockside Lock-Up")
        let price = ShownPrice(amount: 3, isLow: true)
        let cards = [WantedCard(entry: WantedEntry(cardKey: "dockside lock up", name: "Dockside Lock-Up", count: 3), shown: shown,
                                price: price, owned: 1),
                     WantedCard(entry: WantedEntry(cardKey: "gone", name: "Gone Card", count: 1), shown: nil, price: nil, owned: 0)]
        #expect(PDFSource.wanted(cards, game: game, ygo: nil)
                == [PDFSource(name: "Dockside Lock-Up", count: 3, price: price,
                              picture: URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/721334_200w.jpg")),
                    PDFSource(name: "Gone Card", count: 1, price: nil, picture: nil)])
    }

    /// A job's title and file name take the given day.
    @Test func aJobNamesItsListAndDay() throws {
        let game = try #require(Games.game("riftbound"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        let noon = Date(timeIntervalSince1970: 1_794_571_200)              // 2026-11-13 12:00 UTC
        let job = PDFJob(list: .wanted, game: game, items: [], date: noon, timeZone: utc)
        #expect(job.title == "Riftbound — Wanted — 13 November 2026")
        #expect(job.fileName == "riftbound-wanted-2026-11-13.pdf")
    }
}
