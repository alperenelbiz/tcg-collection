import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// One history pass (A37, H5, H8) over a temporary `archives` folder that holds the fixture archive under several day
/// names. The fixture's Riftbound product 721334 has Normal (market 5.12) and Foil (low 9.5 only).
struct HistoryPassTests {
    private static let window = "2025-12-01"..."2026-01-10"
    private static let riftbound = 89
    private static let card = 721334

    /// A folder with the fixture archive under each day's name, and `not-an-archive.7z` under each of `broken`.
    private func archives(_ days: [String], broken: [String] = []) throws -> URL {
        let dir = tempDir()
        for day in days {
            try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: dir.appending(path: "prices-\(day).ppmd.7z"))
        }
        for day in broken {
            try FileManager.default.copyItem(at: fixtureURL("not-an-archive.7z"), to: dir.appending(path: "prices-\(day).ppmd.7z"))
        }
        return dir
    }

    private func game(_ history: PriceHistory? = nil, tracked: Set<Int> = [card]) -> HistoryPass.Game {
        HistoryPass.Game(id: "riftbound", categoryID: Self.riftbound, history: history, tracked: tracked)
    }

    /// Counts the archives read, then reads them as the app does.
    private final class Reads: Sendable {
        private let files = Mutex<[String]>([])
        var names: [String] { files.withLock { $0 } }
        func read(_ url: URL, _ categories: Set<Int>, _ each: (Int, Int, [PriceRow]) -> Void) throws {
            files.withLock { $0.append(url.lastPathComponent) }
            try PriceArchive.read(url, categories: categories, each: each)
        }
    }

    @Test func aPassFillsATrackedProductFromEveryArchiveOnDisk() async throws {
        let dir = try archives(["2026-01-02", "2026-01-04", "2026-01-05"])
        let result = await HistoryPass.run(games: [game()], archives: dir, window: Self.window, failedDays: [])
        let history = try #require(result.histories["riftbound"])
        #expect(history.days == ["2026-01-02", "2026-01-04", "2026-01-05"])
        #expect(history.points(productID: Self.card, finish: "Normal").map(\.amount) == [5.12, 5.12, 5.12])
        #expect(history.products.keys.sorted() == [Self.card])
        #expect(result.failedDays.isEmpty)
    }

    /// The archive's day is the file name's day (the path inside the fixture says 2026-01-02 for every copy).
    @Test func theDayIsTheFileNamesDay() async throws {
        let dir = try archives(["2026-01-07"])
        let result = await HistoryPass.run(games: [game()], archives: dir, window: Self.window, failedDays: [])
        #expect(result.histories["riftbound"]?.days == ["2026-01-07"])
    }

    /// H8: a second pass with the first one's history and no new archive opens no archive; a new day's archive is the only
    /// one read; a newly tracked product is read from every archive.
    @Test func aSecondPassWithNothingNewReadsNoArchive() async throws {
        let dir = try archives(["2026-01-02", "2026-01-03"])
        let first = Reads()
        let one = await HistoryPass.run(games: [game()], archives: dir, window: Self.window, failedDays: [], read: first.read)
        #expect(first.names.count == 2)
        let history = try #require(one.histories["riftbound"])

        let second = Reads()
        let two = await HistoryPass.run(games: [game(history)], archives: dir, window: Self.window, failedDays: [], read: second.read)
        #expect(second.names.isEmpty)
        #expect(two.histories["riftbound"] == history)

        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: dir.appending(path: "prices-2026-01-06.ppmd.7z"))
        let third = Reads()
        let three = await HistoryPass.run(games: [game(history)], archives: dir, window: Self.window, failedDays: [], read: third.read)
        #expect(third.names == ["prices-2026-01-06.ppmd.7z"])
        #expect(three.histories["riftbound"]?.days == ["2026-01-02", "2026-01-03", "2026-01-06"])

        let fourth = Reads()
        let newlyTracked = game(three.histories["riftbound"], tracked: [Self.card, 711362])
        let four = await HistoryPass.run(games: [newlyTracked], archives: dir, window: Self.window, failedDays: [], read: fourth.read)
        #expect(fourth.names.count == 3)
        #expect(four.histories["riftbound"]?.has(productID: 711362) == true)
    }

    /// H8: an archive that cannot be read is skipped and named failed; its day is not added; the other days are filled. A
    /// day already failed in this run is not tried again.
    @Test func aFileThatIsNotAnArchiveIsSkippedAndNamedFailed() async throws {
        let dir = try archives(["2026-01-02", "2026-01-04"], broken: ["2026-01-03"])
        let result = await HistoryPass.run(games: [game()], archives: dir, window: Self.window, failedDays: [])
        #expect(result.failedDays == ["2026-01-03"])
        #expect(result.histories["riftbound"]?.days == ["2026-01-02", "2026-01-04"])

        let again = Reads()
        let second = await HistoryPass.run(games: [game(result.histories["riftbound"])], archives: dir, window: Self.window,
                                           failedDays: result.failedDays, read: again.read)
        #expect(again.names.isEmpty)
        #expect(second.failedDays == ["2026-01-03"])
    }

    /// A37: a day with only a low price is stored marked.
    @Test func aLowPriceIsStoredMarked() async throws {
        let dir = try archives(["2026-01-02"])
        let result = await HistoryPass.run(games: [game()], archives: dir, window: Self.window, failedDays: [])
        let history = try #require(result.histories["riftbound"])
        #expect(history.points(productID: Self.card, finish: "Foil") == [HistoryPoint(day: "2026-01-02", amount: 9.5, isLow: true)])
        #expect(history.points(productID: Self.card, finish: "Normal") == [HistoryPoint(day: "2026-01-02", amount: 5.12, isLow: false)])
    }

    /// A price of 0 is no price (`Price.shown`): a market of 0 falls to the low price, both 0 is no price. A product with
    /// no price still counts as read. Rows of products not planned and of other categories are not taken.
    @Test func aPriceOfZeroIsNoPrice() async throws {
        let dir = try archives(["2026-01-02"])
        let rows = [PriceRow(productID: 1, finish: "Normal", price: Price(market: 0, low: 0, mid: nil, high: nil)),
                    PriceRow(productID: 2, finish: "Normal", price: Price(market: 0, low: 2, mid: nil, high: nil)),
                    PriceRow(productID: 3, finish: "Normal", price: Price(market: 4, low: 1, mid: nil, high: nil))]
        let fake: @Sendable (URL, Set<Int>, (Int, Int, [PriceRow]) -> Void) throws -> Void = { _, categories, each in
            #expect(categories == [Self.riftbound])
            each(Self.riftbound, 1, rows)
        }
        let result = await HistoryPass.run(games: [game(tracked: [1, 2])], archives: dir, window: Self.window, failedDays: [], read: fake)
        let history = try #require(result.histories["riftbound"])
        #expect(history.has(productID: 1)); #expect(history.products[1] == [:])
        #expect(history.points(productID: 2, finish: "Normal") == [HistoryPoint(day: "2026-01-02", amount: 2, isLow: true)])
        #expect(!history.has(productID: 3))
    }

    /// The pass stops between archives when its task is cancelled; it returns what it read, and a day it did not read is
    /// not named failed.
    @Test func aCancelledPassStopsBetweenArchives() async throws {
        let dir = try archives(["2026-01-02", "2026-01-03", "2026-01-04"])
        let reads = Reads()
        let cancelling: @Sendable (URL, Set<Int>, (Int, Int, [PriceRow]) -> Void) throws -> Void = { url, categories, each in
            withUnsafeCurrentTask { $0?.cancel() }
            try reads.read(url, categories, each)
        }
        let result = await Task {
            await HistoryPass.run(games: [game()], archives: dir, window: Self.window, failedDays: [], read: cancelling)
        }.value
        #expect(reads.names == ["prices-2026-01-02.ppmd.7z"])
        #expect(result.histories["riftbound"]?.days == ["2026-01-02"])
        #expect(result.failedDays.isEmpty)
    }

    /// Only `prices-YYYY-MM-DD.ppmd.7z` of a real day names an archive day.
    @Test func fileNamesThatAreNotArchiveDaysAreIgnored() throws {
        let dir = try archives(["2026-01-02"])
        for name in ["prices-2026-1-3.ppmd.7z", "prices-2026-13-40.ppmd.7z", "prices-2026-02-30.ppmd.7z",
                     ".prices-2026-01-05.ppmd.7z", "prices-2026-01-06.ppmd.7z.part", "prices-2026-01-07.7z",
                     "prices-2026-01-08.ppmd.7z.tmp", "notes.txt", "Prices-2026-01-09.ppmd.7z", "xprices-2026-01-04.ppmd.7z"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        try FileManager.default.createDirectory(at: dir.appending(path: "prices-2026-01-03.ppmd.7z"), withIntermediateDirectories: false)
        #expect(HistoryPass.archiveDays(in: dir) == ["2026-01-02"])
        #expect(HistoryPass.archiveDays(in: dir.appending(path: "not-there")).isEmpty)
    }

    /// H5: an archive outside the window is not read; after the reads a game whose plan had something is trimmed to the
    /// window and its tracked printings. A game with nothing planned comes back exactly as it went in (untrimmed), and a
    /// game with no history and nothing planned gets none.
    @Test func aPassTrimsOnlyTheGamesItRead() async throws {
        let dir = try archives(["2026-01-02", "2025-11-01"])
        let stale = PriceHistory(days: ["2025-11-30"], products: [99: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        let reads = Reads()
        let cyberpunkOld = PriceHistory(days: ["2025-11-30", "2026-01-02"],
                                        products: [5: ["Normal": [ShownPrice(amount: 3, isLow: false), nil]]])
        let games = [game(stale),
                     HistoryPass.Game(id: "cyberpunk", categoryID: 92, history: cyberpunkOld, tracked: [5]),
                     HistoryPass.Game(id: "yu-gi-oh", categoryID: 2, history: nil, tracked: [])]
        let result = await HistoryPass.run(games: games, archives: dir, window: Self.window, failedDays: [], read: reads.read)
        #expect(reads.names == ["prices-2026-01-02.ppmd.7z"])
        let history = try #require(result.histories["riftbound"])
        #expect(history.days == ["2026-01-02"])
        #expect(history.products.keys.sorted() == [Self.card])
        #expect(result.histories["cyberpunk"] == cyberpunkOld)
        #expect(result.histories["yu-gi-oh"] == nil)
    }

    /// One archive is opened once for every game that needs it, with their categories together.
    @Test func oneArchiveIsReadOnceForAllGames() async throws {
        let dir = try archives(["2026-01-02"])
        let categories = Mutex<[Set<Int>]>([])
        let reader: @Sendable (URL, Set<Int>, (Int, Int, [PriceRow]) -> Void) throws -> Void = { url, asked, each in
            categories.withLock { $0.append(asked) }
            try PriceArchive.read(url, categories: asked, each: each)
        }
        let games = [game(), HistoryPass.Game(id: "cyberpunk", categoryID: 92, history: nil, tracked: [1])]
        let result = await HistoryPass.run(games: games, archives: dir, window: Self.window, failedDays: [], read: reader)
        #expect(categories.withLock { $0 } == [[89, 92]])
        #expect(result.histories["cyberpunk"]?.days == ["2026-01-02"])
        #expect(result.histories["cyberpunk"]?.has(productID: 1) == true)
    }

    /// A new product (the input history lacks it) stays in the result only when every day planned for it was attempted:
    /// a pass cancelled part-way leaves it out, so the next pass plans it again from every archive. A product the history
    /// had keeps its old days and gains only the days read.
    @Test func aCancelledPassLeavesOutANewProductItDidNotFinish() async throws {
        let dir = try archives(["2026-01-03", "2026-01-04", "2026-01-05"])
        let old = PriceHistory(days: ["2026-01-02"], products: [Self.card: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        let reads = Reads()
        let cancelling: @Sendable (URL, Set<Int>, (Int, Int, [PriceRow]) -> Void) throws -> Void = { url, categories, each in
            withUnsafeCurrentTask { $0?.cancel() }
            try reads.read(url, categories, each)
        }
        let result = await Task {
            await HistoryPass.run(games: [game(old, tracked: [Self.card, 711362])], archives: dir, window: Self.window,
                                  failedDays: [], read: cancelling)
        }.value
        #expect(reads.names == ["prices-2026-01-03.ppmd.7z"])
        let history = try #require(result.histories["riftbound"])
        #expect(!history.has(productID: 711362))
        #expect(history.days == ["2026-01-02", "2026-01-03"])
        #expect(history.points(productID: Self.card, finish: "Normal").map(\.amount) == [1, 5.12])
    }

    /// A day whose archive failed counts as attempted: a new product is kept with the readable days (else an archive
    /// that is corrupt for good would make every pass read every archive again).
    @Test func aFailedDayDoesNotDropANewProduct() async throws {
        let dir = try archives(["2026-01-02", "2026-01-04"], broken: ["2026-01-03"])
        let result = await HistoryPass.run(games: [game(tracked: [711362])], archives: dir, window: Self.window, failedDays: [])
        let history = try #require(result.histories["riftbound"])
        #expect(history.has(productID: 711362))
        #expect(history.days == ["2026-01-02", "2026-01-04"])
        #expect(result.failedDays == ["2026-01-03"])
    }
}
