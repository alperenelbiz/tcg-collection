import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// One history pass (A37, H5, H8; phase 5B task 3, K5) over a temporary `price-days` folder that holds the fixture
/// archive's day file under several day names. The fixture's Riftbound product 721334 has Normal (market 5.12) and Foil
/// (low 9.5 only).
struct HistoryPassTests {
    private static let window = "2025-12-01"..."2026-01-10"
    private static let riftbound = 89
    private static let card = 721334

    /// The fixture archive decoded once through the gate (the app's only archive read), as rows per category.
    private static func fixtureRows() async throws -> [Int: [PriceDayRow]] {
        let paths = AppPaths(root: tempRoot())
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                         to: paths.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-02")))
        _ = try await ArchiveGate(paths: paths).decode(day: "2026-01-02", games: Games.all)
        let reader = try PriceDayReader(url: paths.priceDay("2026-01-02"))
        return Dictionary(uniqueKeysWithValues: reader.categories.map { ($0, reader.rows(category: $0)) })
    }

    /// A folder with the fixture's day file under each day's name (its header says that day), and a file that is no day
    /// file under each of `broken`.
    private func dayFiles(_ days: [String], broken: [String] = []) async throws -> URL {
        let dir = tempDir()
        let rows = try await Self.fixtureRows()
        for day in days { try place(day, rows: rows, in: dir) }
        for day in broken { try Data("not a day file".utf8).write(to: dir.appending(path: PriceDayFile.fileName(day: day))) }
        return dir
    }

    private func place(_ day: String, rows: [Int: [PriceDayRow]], in dir: URL) throws {
        try PriceDayFile.write(PriceDayFile.data(day: day, rows: rows), to: dir.appending(path: PriceDayFile.fileName(day: day)))
    }

    private func game(_ history: PriceHistory? = nil, tracked: Set<Int> = [card]) -> HistoryPass.Game {
        HistoryPass.Game(id: "riftbound", categoryID: Self.riftbound, history: history, tracked: tracked)
    }

    /// The pass over the day files of `dir` as the app runs it.
    private func pass(_ games: [HistoryPass.Game], _ dir: URL, failedDays: Set<String> = [],
                      read: HistoryPass.Reader? = nil) async -> HistoryPass.Result {
        await HistoryPass.run(games: games, days: PriceDayFile.days(in: dir), window: Self.window, failedDays: failedDays,
                              read: read ?? HistoryPass.dayFileReader(in: dir))
    }

    /// Counts the day files opened, then opens them as the app does.
    private final class Reads: Sendable {
        let dir: URL
        private let days = Mutex<[String]>([])
        init(_ dir: URL) { self.dir = dir }
        var names: [String] { days.withLock { $0 } }
        var reader: HistoryPass.Reader {
            { [self] day in
                days.withLock { $0.append(day) }
                return try HistoryPass.dayFileReader(in: dir)(day)
            }
        }
    }

    @Test func aPassFillsATrackedProductFromEveryDayFile() async throws {
        let dir = try await dayFiles(["2026-01-02", "2026-01-04", "2026-01-05"])
        let result = await pass([game()], dir)
        let history = try #require(result.histories["riftbound"])
        #expect(history.days == ["2026-01-02", "2026-01-04", "2026-01-05"])
        #expect(history.points(productID: Self.card, finish: "Normal").map(\.amount) == [5.12, 5.12, 5.12])
        #expect(history.products.keys.sorted() == [Self.card])
        #expect(result.failedDays.isEmpty)
    }

    /// The history's day is the day file's day. A file whose header names another day than its name is not that day's:
    /// it is failed (the gate's rule for a day file).
    @Test func theDayIsTheDayFilesDay() async throws {
        let dir = try await dayFiles(["2026-01-07"])
        let result = await pass([game()], dir)
        #expect(result.histories["riftbound"]?.days == ["2026-01-07"])

        try FileManager.default.copyItem(at: dir.appending(path: PriceDayFile.fileName(day: "2026-01-07")),
                                         to: dir.appending(path: PriceDayFile.fileName(day: "2026-01-08")))
        let second = await pass([game()], dir)
        #expect(second.histories["riftbound"]?.days == ["2026-01-07"])
        #expect(second.failedDays == ["2026-01-08"])
    }

    /// H8: a second pass with the first one's history and no new day file opens none; a new day's file is the only one
    /// read; a newly tracked product is read from every day file.
    @Test func aSecondPassWithNothingNewReadsNoDayFile() async throws {
        let dir = try await dayFiles(["2026-01-02", "2026-01-03"])
        let first = Reads(dir)
        let one = await pass([game()], dir, read: first.reader)
        #expect(first.names.count == 2)
        let history = try #require(one.histories["riftbound"])

        let second = Reads(dir)
        let two = await pass([game(history)], dir, read: second.reader)
        #expect(second.names.isEmpty)
        #expect(two.histories["riftbound"] == history)

        try place("2026-01-06", rows: try await Self.fixtureRows(), in: dir)
        let third = Reads(dir)
        let three = await pass([game(history)], dir, read: third.reader)
        #expect(third.names == ["2026-01-06"])
        #expect(three.histories["riftbound"]?.days == ["2026-01-02", "2026-01-03", "2026-01-06"])

        let fourth = Reads(dir)
        let newlyTracked = game(three.histories["riftbound"], tracked: [Self.card, 711362])
        let four = await pass([newlyTracked], dir, read: fourth.reader)
        #expect(fourth.names.count == 3)
        #expect(four.histories["riftbound"]?.has(productID: 711362) == true)
    }

    /// H8: a day file that does not read is skipped and named failed; its day is not added; the other days are filled. A
    /// day already failed in this run is not tried again.
    @Test func aFileThatIsNotADayFileIsSkippedAndNamedFailed() async throws {
        let dir = try await dayFiles(["2026-01-02", "2026-01-04"], broken: ["2026-01-03"])
        let result = await pass([game()], dir)
        #expect(result.failedDays == ["2026-01-03"])
        #expect(result.histories["riftbound"]?.days == ["2026-01-02", "2026-01-04"])

        let again = Reads(dir)
        let second = await pass([game(result.histories["riftbound"])], dir, failedDays: result.failedDays, read: again.reader)
        #expect(again.names.isEmpty)
        #expect(second.failedDays == ["2026-01-03"])
    }

    /// An IO error (the file went away between the listing and the read) is a failed day too.
    @Test func aDayFileThatCannotBeOpenedIsNamedFailed() async throws {
        let dir = try await dayFiles(["2026-01-02"])
        let gone: HistoryPass.Reader = { day in
            try HistoryPass.dayFileReader(in: dir.appending(path: "not-there"))(day)
        }
        let result = await pass([game()], dir, read: gone)
        #expect(result.failedDays == ["2026-01-02"])
        #expect(result.histories["riftbound"] == nil)
    }

    /// A37: a day with only a low price is stored marked.
    @Test func aLowPriceIsStoredMarked() async throws {
        let dir = try await dayFiles(["2026-01-02"])
        let result = await pass([game()], dir)
        let history = try #require(result.histories["riftbound"])
        #expect(history.points(productID: Self.card, finish: "Foil") == [HistoryPoint(day: "2026-01-02", amount: 9.5, isLow: true)])
        #expect(history.points(productID: Self.card, finish: "Normal") == [HistoryPoint(day: "2026-01-02", amount: 5.12, isLow: false)])
    }

    /// A price of 0 is no price (`Price.shown`, applied by the gate's decode): a market of 0 falls to the low price, both
    /// 0 is no price. A product with no price still counts as read. Rows of products not planned and of other categories
    /// are not taken.
    @Test func aPriceOfZeroIsNoPrice() async throws {
        let paths = AppPaths(root: tempRoot())
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try Data("archive".utf8).write(to: paths.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-02")))
        let rows = [PriceRow(productID: 1, finish: "Normal", price: Price(market: 0, low: 0, mid: nil, high: nil)),
                    PriceRow(productID: 2, finish: "Normal", price: Price(market: 0, low: 2, mid: nil, high: nil)),
                    PriceRow(productID: 3, finish: "Normal", price: Price(market: 4, low: 1, mid: nil, high: nil))]
        let other = [PriceRow(productID: 1, finish: "Normal", price: Price(market: 7, low: nil, mid: nil, high: nil))]
        let fake: ArchiveGate.Reader = { _, _, each in
            each(Self.riftbound, 1, rows)
            each(92, 1, other)
        }
        _ = try await ArchiveGate(paths: paths, read: fake).decode(day: "2026-01-02", games: Games.all)
        let result = await pass([game(tracked: [1, 2])], paths.priceDays)
        let history = try #require(result.histories["riftbound"])
        #expect(history.has(productID: 1)); #expect(history.products[1] == [:])
        #expect(history.points(productID: 2, finish: "Normal") == [HistoryPoint(day: "2026-01-02", amount: 2, isLow: true)])
        #expect(!history.has(productID: 3))
    }

    /// The pass stops between day files when its task is cancelled; it returns what it read, and a day it did not read is
    /// not named failed.
    @Test func aCancelledPassStopsBetweenDayFiles() async throws {
        let dir = try await dayFiles(["2026-01-02", "2026-01-03", "2026-01-04"])
        let reads = Reads(dir)
        let cancelling: HistoryPass.Reader = { day in
            withUnsafeCurrentTask { $0?.cancel() }
            return try reads.reader(day)
        }
        let result = await Task { await pass([game()], dir, read: cancelling) }.value
        #expect(reads.names == ["2026-01-02"])
        #expect(result.histories["riftbound"]?.days == ["2026-01-02"])
        #expect(result.failedDays.isEmpty)
    }

    /// Only `yyyy-MM-dd.prices` of a real day names a day file; the pass reads no other file.
    @Test func fileNamesThatAreNotDayFilesAreIgnored() async throws {
        let dir = try await dayFiles(["2026-01-02"])
        for name in ["2026-1-3.prices", "2026-13-40.prices", "2026-02-30.prices", ".2026-01-05.prices",
                     "2026-01-06.prices.tmp", "2026-01-07.price", "prices-2026-01-08.ppmd.7z", "notes.txt",
                     "x2026-01-04.prices"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        try FileManager.default.createDirectory(at: dir.appending(path: "2026-01-03.prices"), withIntermediateDirectories: false)
        #expect(PriceDayFile.days(in: dir) == ["2026-01-02"])
        #expect(PriceDayFile.days(in: dir.appending(path: "not-there")).isEmpty)
        let reads = Reads(dir)
        let result = await pass([game()], dir, read: reads.reader)
        #expect(reads.names == ["2026-01-02"])
        #expect(result.failedDays.isEmpty)
    }

    /// H5: a day file outside the window is not read; after the reads a game whose plan had something is trimmed to the
    /// window and its tracked printings. A game with nothing planned comes back exactly as it went in (untrimmed), and a
    /// game with no history and nothing planned gets none.
    @Test func aPassTrimsOnlyTheGamesItRead() async throws {
        let dir = try await dayFiles(["2026-01-02", "2025-11-01"])
        let stale = PriceHistory(days: ["2025-11-30"], products: [99: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        let reads = Reads(dir)
        let cyberpunkOld = PriceHistory(days: ["2025-11-30", "2026-01-02"],
                                        products: [5: ["Normal": [ShownPrice(amount: 3, isLow: false), nil]]])
        let games = [game(stale),
                     HistoryPass.Game(id: "cyberpunk", categoryID: 92, history: cyberpunkOld, tracked: [5]),
                     HistoryPass.Game(id: "yu-gi-oh", categoryID: 2, history: nil, tracked: [])]
        let result = await pass(games, dir, read: reads.reader)
        #expect(reads.names == ["2026-01-02"])
        let history = try #require(result.histories["riftbound"])
        #expect(history.days == ["2026-01-02"])
        #expect(history.products.keys.sorted() == [Self.card])
        #expect(result.histories["cyberpunk"] == cyberpunkOld)
        #expect(result.histories["yu-gi-oh"] == nil)
    }

    /// One day file is opened once for every game that needs it.
    @Test func oneDayFileIsReadOnceForAllGames() async throws {
        let dir = try await dayFiles(["2026-01-02"])
        let reads = Reads(dir)
        let games = [game(), HistoryPass.Game(id: "cyberpunk", categoryID: 92, history: nil, tracked: [1])]
        let result = await pass(games, dir, read: reads.reader)
        #expect(reads.names == ["2026-01-02"])
        #expect(result.histories["riftbound"]?.has(productID: Self.card) == true)
        #expect(result.histories["cyberpunk"]?.days == ["2026-01-02"])
        #expect(result.histories["cyberpunk"]?.has(productID: 1) == true)
    }

    /// A new product (the input history lacks it) stays in the result only when every day planned for it was attempted:
    /// a pass cancelled part-way leaves it out, so the next pass plans it again from every day file. A product the history
    /// had keeps its old days and gains only the days read.
    @Test func aCancelledPassLeavesOutANewProductItDidNotFinish() async throws {
        let dir = try await dayFiles(["2026-01-03", "2026-01-04", "2026-01-05"])
        let old = PriceHistory(days: ["2026-01-02"], products: [Self.card: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        let reads = Reads(dir)
        let cancelling: HistoryPass.Reader = { day in
            withUnsafeCurrentTask { $0?.cancel() }
            return try reads.reader(day)
        }
        let result = await Task { await pass([game(old, tracked: [Self.card, 711362])], dir, read: cancelling) }.value
        #expect(reads.names == ["2026-01-03"])
        let history = try #require(result.histories["riftbound"])
        #expect(!history.has(productID: 711362))
        #expect(history.days == ["2026-01-02", "2026-01-03"])
        #expect(history.points(productID: Self.card, finish: "Normal").map(\.amount) == [1, 5.12])
    }

    /// A42, M1: a pass that adds a product and no day keeps every product the history had, tracked or not (two devices
    /// with other catalogs must not drop each other's printings); days out of the window still go. Its new product makes
    /// it a write (H9).
    @Test func aPassThatOnlyAddsAProductKeepsUntrackedProducts() async throws {
        let dir = try await dayFiles(["2026-01-02"])
        let old = PriceHistory(days: ["2025-11-30", "2026-01-02"],
                               products: [Self.card: ["Normal": [nil, ShownPrice(amount: 5.12, isLow: false)]],
                                          99: ["Normal": [ShownPrice(amount: 1, isLow: false), ShownPrice(amount: 2, isLow: false)]]])
        let reads = Reads(dir)
        let result = await pass([game(old, tracked: [Self.card, 711362])], dir, read: reads.reader)
        #expect(reads.names == ["2026-01-02"])
        let history = try #require(result.histories["riftbound"])
        #expect(history.days == ["2026-01-02"])
        #expect(history.products.keys.sorted() == [99, 711362, Self.card])
        #expect(history.points(productID: 99, finish: "Normal") == [HistoryPoint(day: "2026-01-02", amount: 2, isLow: false)])
        #expect(HistoryPlan.writes(old: old, new: history))
    }

    /// A42: a pass that adds a day to the game's `days` drops the products that are not tracked (and the days out of the
    /// window).
    @Test func aPassThatAddsADayDropsUntrackedProducts() async throws {
        let dir = try await dayFiles(["2026-01-02", "2026-01-03"])
        let old = PriceHistory(days: ["2025-11-30", "2026-01-02"],
                               products: [Self.card: ["Normal": [nil, ShownPrice(amount: 5.12, isLow: false)]],
                                          99: ["Normal": [ShownPrice(amount: 1, isLow: false), ShownPrice(amount: 2, isLow: false)]]])
        let result = await pass([game(old)], dir)
        let history = try #require(result.histories["riftbound"])
        #expect(history.days == ["2026-01-02", "2026-01-03"])
        #expect(history.products.keys.sorted() == [Self.card])
        #expect(history.points(productID: Self.card, finish: "Normal").map(\.amount) == [5.12, 5.12])
        #expect(HistoryPlan.writes(old: old, new: history))
    }

    /// A day whose day file failed counts as attempted: a new product is kept with the readable days (else a day file
    /// that is corrupt for good would make every pass read every day file again).
    @Test func aFailedDayDoesNotDropANewProduct() async throws {
        let dir = try await dayFiles(["2026-01-02", "2026-01-04"], broken: ["2026-01-03"])
        let result = await pass([game(tracked: [711362])], dir)
        let history = try #require(result.histories["riftbound"])
        #expect(history.has(productID: 711362))
        #expect(history.days == ["2026-01-02", "2026-01-04"])
        #expect(result.failedDays == ["2026-01-03"])
    }

    /// R2: one day file of 230,000 made-up rows in the real proportions of the four games, read under 90 day names (90
    /// opens and lookups): a card newly tracked in a history of 90 days is filled in under a second (Debug build).
    @Test func aNewlyTrackedCardOf90DaysIsFilledInUnderASecond() async throws {
        let counts = [1: 165_600, 2: 61_500, 89: 2_400, 92: 500]     // 230,000 rows
        var rows: [Int: [PriceDayRow]] = [:]
        for (category, count) in counts {
            rows[category] = (0..<count).map { i in
                PriceDayRow(productID: category * 1_000_000 + i / 2, finish: i % 2 == 0 ? "Normal" : "Foil",
                            price: ShownPrice(amount: Double(i % 5_000 + 1) / 100, isLow: i % 7 == 0))
            }
        }
        let file = tempDir().appending(path: "2026-01-02.prices")
        try PriceDayFile.write(PriceDayFile.data(day: "2026-01-02", rows: rows), to: file)
        let written = try PriceDayReader(url: file)
        #expect(written.categories.reduce(0) { $0 + written.rowCount(category: $1) } == 230_000)

        let window = PriceDay.window(endingOn: "2026-01-02")
        let days = PriceDay.days(in: window)
        #expect(days.count == 90)
        // The history already has the 90 days and other printings; the new card has 12 printings.
        let known = Set((0..<200).map { 1_000_000 + $0 })
        var history = PriceHistory()
        for day in days {
            history.setDay(day, rows: Dictionary(uniqueKeysWithValues: known.map { ($0, ["Normal": ShownPrice(amount: 1, isLow: false)]) }),
                           for: known)
        }
        let card = Set((0..<12).map { 1_000_000 + 40_000 + $0 * 997 })
        let opens = Mutex(0)
        let reader: HistoryPass.Reader = { _ in
            opens.withLock { $0 += 1 }
            return try PriceDayReader(url: file)
        }
        let game = HistoryPass.Game(id: "magic-the-gathering", categoryID: 1, history: history, tracked: known.union(card))

        let start = ContinuousClock.now
        let result = await HistoryPass.run(games: [game], days: Set(days), window: window, failedDays: [], read: reader)
        let took = ContinuousClock.now - start
        print("aNewlyTrackedCardOf90DaysIsFilledInUnderASecond: 90 day files of 230,000 rows, 12 new printings: "
              + String(format: "%.3f s", took / .seconds(1)))

        #expect(opens.withLock { $0 } == 90)
        let filled = try #require(result.histories["magic-the-gathering"])
        for productID in card {
            #expect(filled.points(productID: productID, finish: "Normal").count == 90)
            #expect(filled.points(productID: productID, finish: "Foil").count == 90)
        }
        #expect(took < .seconds(1))
    }
}
