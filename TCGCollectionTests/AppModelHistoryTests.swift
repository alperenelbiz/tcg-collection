import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// The model's price history (phase 5A task 4: A41, A42, H6, H7, H9–H11; Review Focus 1–3). Most tests launch offline on
/// a store root whose catalog holds the Riftbound and Cyberpunk fixture products and whose `caches/archives` holds the
/// fixture archive under three day names. On `day1` (2026-01-03, morning UTC) the window ends on 2026-01-02. The fixture's
/// Riftbound product 721334 (Dockside Lock-Up) has Normal (market 5.12) and Foil (low 9.5).
@MainActor
struct AppModelHistoryTests {
    static let day1 = TCGDate.date("2026-01-03T10:00:00")!
    static let day2 = TCGDate.date("2026-01-04T10:00:00")!
    static let archiveDays = ["2025-12-30", "2025-12-31", "2026-01-02"]
    static let dockside = 721334, kaisa = 721337, pack = 711362, rune = 722282
    /// A product id no day file has a row of (and no catalog knows).
    static let unpriced = 999_999
    static let docksideKey = "dockside lock up"

    /// Counts the day files the passes open (phase 5B task 3: a pass reads day files only; the launch turns the archives
    /// on disk into day files first), then opens them as the app does.
    final class Reads: Sendable {
        private let files = Mutex<[String]>([])
        var count: Int { files.withLock { $0.count } }
        func reader(_ folder: URL) -> HistoryPass.Reader {
            { [self] day in
                files.withLock { $0.append(day) }
                return try HistoryPass.dayFileReader(in: folder)(day)
            }
        }
    }

    /// Counts the history file reads (every read goes through `historyFileReader`), then reads as the app does.
    /// `during` runs inside the read, after the file was read and before the read returns (off the main actor).
    final class FileReads: Sendable {
        private let reads = Mutex<[String]>([])
        private let hook = Mutex<(@Sendable (String) -> Void)?>(nil)
        var count: Int { reads.withLock { $0.count } }
        var games: [String] { reads.withLock { $0 } }
        func during(_ action: (@Sendable (String) -> Void)?) { hook.withLock { $0 = action } }
        func read(_ game: String, _ folder: URL) throws -> HistoryFiles.Read {
            reads.withLock { $0.append(game) }
            let result = try HistoryFiles.read(game: game, in: folder)
            if let action = hook.withLock({ $0 }) { action(game) }
            return result
        }
    }

    /// Runs `body` on the main actor from a thread off it, and waits for it (the main actor is free while a read is
    /// awaited).
    nonisolated static func onMain(_ body: @MainActor () -> Void) {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    // MARK: Helpers

    private static func row(_ productID: Int, count: Int = 1) -> String {
        #"{"productID":\#(productID),"finish":"Normal","count":\#(count),"name":"Card \#(productID)"}"#
    }

    private static func gameFile(rows: [Int] = [], extra: String = "") -> String {
        #"{"version":1,"collection":[\#(rows.map { row($0) }.joined(separator: ","))]\#(extra)}"#
    }

    private func user(_ root: URL) -> URL { AppPaths.userTestRoot(root) }

    private func historyURL(_ root: URL, _ game: String = "riftbound") -> URL {
        user(root).appending(path: HistoryFiles.name(game: game))
    }

    /// Writes the user files (game id or file name → text) into `<root>/user` before a launch.
    private func write(_ root: URL, _ files: [String: String]) throws {
        try FileManager.default.createDirectory(at: user(root), withIntermediateDirectories: true)
        for (name, text) in files {
            let file = name.hasSuffix(".json") || name.hasPrefix(".") ? name : "\(name).json"
            try Data(text.utf8).write(to: user(root).appending(path: file))
        }
    }

    /// Every file of `<root>/user` with its bytes.
    private func snapshot(_ root: URL) -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: user(root).path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            (try? Data(contentsOf: user(root).appending(path: name))).map { (name, $0) }
        })
    }

    /// An offline model on `root` with the fixture catalog of Riftbound and Cyberpunk and the archives of `days` on disk.
    /// Not started.
    private func offlineModel(_ root: URL, days: [String] = Self.archiveDays, reads: Reads? = nil,
                              extra: [String] = [], now: @escaping () -> Date = { Self.day1 }) async throws -> AppModel {
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path, "-offline", "YES", "-game", "riftbound"] + extra),
                             catalogClient: NoNetwork(), archiveClient: NoNetwork(), fetcher: NoNetwork(), now: now)
        model.historyQuietTime = .zero
        if let reads { model.historyDayReader = reads.reader }
        try await fillCatalog(model)
        try placeArchives(model, days)
        return model
    }

    private func fillCatalog(_ model: AppModel) async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for (file, game, group) in [("products-89.json", "riftbound", 24819), ("products-92.json", "cyberpunk", 24884)] {
            let (cards, _) = try ProductParser.products(fixture(file), game: Games.game(game)!)
            try await model.store.replaceProducts(of: group, with: cards, at: date)
        }
    }

    private func placeArchives(_ model: AppModel, _ days: [String]) throws {
        try FileManager.default.createDirectory(at: model.paths.archives, withIntermediateDirectories: true)
        for day in days {
            let file = model.paths.archives.appending(path: ArchiveGate.archiveName(day: day))
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: file)
            }
        }
    }

    /// Day files of `days` in the model's `price-days` folder, as the gate writes them (the fixture archive decoded once,
    /// on a root of its own): a day that comes while the app runs (the price step, phase 5B's download) is a day file.
    private func placeDayFiles(_ model: AppModel, _ days: [String]) async throws {
        let scratch = AppPaths(root: tempRoot())
        try FileManager.default.createDirectory(at: scratch.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                         to: scratch.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-02")))
        _ = try await ArchiveGate(paths: scratch).decode(day: "2026-01-02", games: Games.all)
        let reader = try PriceDayReader(url: scratch.priceDay("2026-01-02"))
        let rows = Dictionary(uniqueKeysWithValues: reader.categories.map { ($0, reader.rows(category: $0)) })
        for day in days where !exists(model.paths.priceDay(day)) {
            try PriceDayFile.write(PriceDayFile.data(day: day, rows: rows), to: model.paths.priceDay(day))
        }
    }

    /// The history file of a game as read from disk.
    private func stored(_ root: URL, _ game: String = "riftbound") throws -> PriceHistory {
        guard case .history(let history) = try HistoryFiles.read(game: game, in: user(root)) else {
            throw StoredHistoryMissing()
        }
        return history
    }

    struct StoredHistoryMissing: Error {}

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < end else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    struct Timeout: Error {}

    /// The block's state once the printing's points are read (phase 5B task 4: `.reading` until then).
    private func state(_ model: AppModel, _ productID: Int, game: String = "riftbound") async -> HistoryState {
        _ = await model.points(game: game, productID: productID)
        return model.historyState(game: game, productID: productID)
    }

    // MARK: The first pass (Review Focus 1)

    /// A game with a tracked printing gets its file with every archive day of the window; the game files and
    /// `settings.json` keep their bytes, and only `<game>.prices.json` appears.
    @Test(.timeLimit(.minutes(1))) func theFirstPassWritesAFileForAGameWithATrackedPrinting() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "cyberpunk": Self.gameFile()])
        let model = try await offlineModel(root)
        let before = snapshot(root)
        await model.start()
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.days == Self.archiveDays)
        #expect(history.products.keys.sorted() == [Self.dockside])
        #expect(history.points(productID: Self.dockside, finish: "Normal").map(\.amount) == [5.12, 5.12, 5.12])
        #expect(model.history(game: "riftbound") == history)
        #expect(model.historyVersions["riftbound", default: 0] > 0)
        #expect(await state(model, Self.dockside) == .ready)
        let after = snapshot(root)
        for (name, data) in before { #expect(after[name] == data, "\(name)") }
        #expect(Set(after.keys).subtracting(before.keys) == ["riftbound.prices.json"])
    }

    /// A followed game with products and a game file but no tracked printing gets no file; nor does a game without a game
    /// file. The game files and `settings.json` keep their bytes.
    @Test(.timeLimit(.minutes(1))) func theFirstPassWritesNoFileForAGameWithNone() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "cyberpunk": Self.gameFile()])
        let model = try await offlineModel(root)
        let before = snapshot(root)
        await model.start()
        await model.waitForHistory()
        #expect(!exists(historyURL(root, "cyberpunk")))
        #expect(!exists(historyURL(root, "magic-the-gathering")))
        #expect(model.history(game: "cyberpunk") == nil)
        #expect(await state(model, 719684, game: "cyberpunk") == .ready)  // phase 5B: every printing has its block
        let after = snapshot(root)
        for (name, data) in before { #expect(after[name] == data, "\(name)") }
    }

    /// A42: a second launch on the same day reads no archive and does not write the file (its bytes and its date).
    @Test(.timeLimit(.minutes(1))) func aSecondLaunchOnTheSameDayWritesNothing() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let first = try await offlineModel(root)
        await first.start()
        await first.waitForHistory()
        let bytes = try Data(contentsOf: historyURL(root))
        let written = try sizeAndDate(historyURL(root))
        try await Task.sleep(for: .milliseconds(20))
        let reads = Reads()
        let second = try await offlineModel(root, reads: reads)
        await second.start()
        await second.waitForHistory()
        #expect(reads.count == 0)
        #expect(try Data(contentsOf: historyURL(root)) == bytes)
        #expect(try sizeAndDate(historyURL(root)).date == written.date)
        #expect(await state(second, Self.dockside) == .ready)
    }

    // MARK: Tracking (A41, A42, H6, H9)

    /// A41: a card put on Wanted is filled into the history file from every day on disk, one point per day.
    @Test(.timeLimit(.minutes(1))) func aCardAddedToWantedIsFilledFromTheArchivesOnDisk() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.kaisa])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) == false)
        model.library.setWanted(1, game: "riftbound", cardKey: Self.docksideKey, name: "Dockside Lock-Up")
        await model.waitForHistory()
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) == true)
        #expect(model.history(game: "riftbound")?.points(productID: Self.dockside, finish: "Normal").count == 3)
        #expect(try stored(root).has(productID: Self.dockside))
    }

    /// H9, A42: a printing no longer tracked stays in memory and in the file (no write for a removal alone), stays through
    /// a write that adds only a product (final fix M1), and leaves at the next write that adds a day.
    @Test(.timeLimit(.minutes(1))) func aPrintingNoLongerTrackedStaysUntilAWriteAddsADay() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside, Self.kaisa])])
        var now = Self.day1
        let model = try await offlineModel(root, now: { now })
        await model.start()
        await model.waitForHistory()
        let bytes = try Data(contentsOf: historyURL(root))
        model.library.setCount(0, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "")
        await model.waitForHistory()
        #expect(try Data(contentsOf: historyURL(root)) == bytes)
        #expect(model.history(game: "riftbound")?.has(productID: Self.kaisa) == true)
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.pack, finish: "Normal"), name: "Pack")
        await model.waitForHistory()
        var history = try stored(root)
        #expect(history.products.keys.sorted() == [Self.pack, Self.dockside, Self.kaisa])
        #expect(model.history(game: "riftbound") == history)
        now = Self.day2
        try await placeDayFiles(model, ["2026-01-03"])
        model.library.setCount(2, game: "riftbound", key: PrintingKey(productID: Self.pack, finish: "Normal"), name: "Pack")
        await model.waitForHistory()
        history = try stored(root)
        #expect(history.days.last == "2026-01-03")
        #expect(history.products.keys.sorted() == [Self.pack, Self.dockside])
        #expect(model.history(game: "riftbound")?.has(productID: Self.kaisa) == false)
        #expect(model.history(game: "riftbound") == history)
    }

    // MARK: Bursts (H10, Review Focus 3)

    /// Five changes within the quiet time make one pass: each archive is opened once.
    @Test(.timeLimit(.minutes(1))) func fiveFastChangesMakeOnePass() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile()])
        let reads = Reads()
        let model = try await offlineModel(root, reads: reads)
        await model.start()
        await model.waitForHistory()
        #expect(reads.count == 0)
        model.historyQuietTime = .milliseconds(300)
        let passes = model.historyPassCount
        for (i, id) in [Self.dockside, Self.kaisa, Self.pack, Self.rune, Self.dockside].enumerated() {
            model.library.setCount(i == 4 ? 2 : 1, game: "riftbound", key: PrintingKey(productID: id, finish: "Normal"), name: "C")
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.waitForHistory()
        #expect(reads.count == Self.archiveDays.count)
        #expect(model.historyPassCount == passes + 1)
        #expect(try stored(root).products.count == 4)
    }

    /// An import of 500 rows (one library change) makes one pass.
    @Test(.timeLimit(.minutes(1))) func anImportOfManyRowsMakesOnePass() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile()])
        let reads = Reads()
        let model = try await offlineModel(root, reads: reads)
        await model.start()
        await model.waitForHistory()
        let passes = model.historyPassCount
        let rows = (1...500).map { CollectionRow(productID: $0, finish: "Normal", count: 1, condition: "", name: "C\($0)") }
            + [CollectionRow(productID: Self.dockside, finish: "Normal", count: 1, condition: "", name: "D")]
        model.library.replace(game: "riftbound", rows: rows)
        await model.waitForHistory()
        #expect(reads.count == Self.archiveDays.count)
        #expect(model.historyPassCount == passes + 1)
        #expect(try stored(root).products.count == 501)
    }

    // MARK: Every printing's chart (phase 5B task 4: A45, K6)

    /// A printing in no list has its points from the day files on disk (one per day), `.ready`; the history file does not
    /// get it.
    @Test(.timeLimit(.minutes(1))) func aPrintingNobodyTracksHasItsDays() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.kaisa])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .reading)    // not read yet
        #expect(model.dayPoints(game: "riftbound", productID: Self.dockside, finish: "Normal") == nil)
        let points = await model.points(game: "riftbound", productID: Self.dockside)
        #expect(points["Normal"]?.map(\.day) == Self.archiveDays)
        #expect(points["Normal"]?.map(\.amount) == [5.12, 5.12, 5.12])
        #expect(points["Foil"]?.count == 3 && points["Foil"]?.allSatisfy(\.isLow) == true)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
        #expect(model.dayPoints(game: "riftbound", productID: Self.dockside, finish: "Normal") == points["Normal"])
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) == false)
        // A product no day file has a row of: ready with no point ("No price in the last 90 days.").
        #expect(await state(model, Self.unpriced) == .ready)
        #expect(model.dayPoints(game: "riftbound", productID: Self.unpriced, finish: "Normal") == [])
    }

    /// Review Focus 5: a day in both the day files and the iCloud history file is shown once, with the day file's price;
    /// a day only in the history file (another device read it) is kept.
    @Test(.timeLimit(.minutes(1))) func aDayInBothTheDayFilesAndTheHistoryFileIsShownOnce() async throws {
        let root = tempRoot()
        let other = PriceHistory(days: ["2025-12-01", "2026-01-02"],
                                 products: [Self.dockside: ["Normal": [ShownPrice(amount: 4, isLow: false),
                                                                       ShownPrice(amount: 9, isLow: false)]]])
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        try other.data().write(to: historyURL(root))
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        let points = await model.points(game: "riftbound", productID: Self.dockside)
        #expect(points["Normal"]?.map(\.day) == ["2025-12-01"] + Self.archiveDays)
        #expect(points["Normal"]?.map(\.amount) == [4, 5.12, 5.12, 5.12])
    }

    @Test(.timeLimit(.minutes(1))) func aGameNotFollowedShowsNothing() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside], extra: #","profile":{"followed":false}"#),
                         "cyberpunk": Self.gameFile()])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(await model.points(game: "riftbound", productID: Self.dockside).isEmpty)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .unknown)
        #expect(model.dayPoints(game: "riftbound", productID: Self.dockside, finish: "Normal") == nil)
    }

    /// One lookup per day file of the window for one product, then none until a day file is added (the gate writes one):
    /// a Magic basic land's page costs the same, since the block reads the shown printing's days, not the card's printings.
    @Test(.timeLimit(.minutes(1))) func theLookupIsCachedUntilADayFileIsAdded() async throws {
        let root = tempRoot()
        let reads = Reads()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.kaisa])])
        let model = try await offlineModel(root, reads: reads)
        await model.start()
        await model.waitForHistory()
        let before = reads.count
        _ = await model.points(game: "riftbound", productID: Self.dockside)
        #expect(reads.count == before + Self.archiveDays.count)
        _ = await model.points(game: "riftbound", productID: Self.dockside)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
        #expect(reads.count == before + Self.archiveDays.count)
        try placeArchives(model, ["2025-12-29"])
        _ = try await model.archiveGate.decode(day: "2025-12-29", games: Games.all)
        await model.notePriceDays()
        // Final fix wave, item 1: the last read stays shown while the new one runs.
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
        let points = await model.points(game: "riftbound", productID: Self.dockside)
        #expect(reads.count == before + 2 * Self.archiveDays.count + 1)
        #expect(points["Normal"]?.first?.day == "2025-12-29")
    }

    /// Holds the day-file reads it makes while `hold()` is on: the first read waits until `release()`.
    final class HeldReads: Sendable {
        private let held = Mutex(false)
        private let entered = Mutex(false)
        private let gate = DispatchSemaphore(value: 0)
        var isWaiting: Bool { entered.withLock { $0 } }
        func hold() { held.withLock { $0 = true } }
        func release() {
            held.withLock { $0 = false }
            gate.signal()
        }
        func reader(_ folder: URL) -> HistoryPass.Reader {
            { [self] day in
                if held.withLock({ $0 }) {
                    entered.withLock { $0 = true }
                    gate.wait()
                }
                return try HistoryPass.dayFileReader(in: folder)(day)
            }
        }
    }

    /// Final fix wave, item 1: a new day file (a `priceDaysVersion` bump) keeps the last read on screen: the block stays
    /// `.ready` with the old points while the new read runs, then shows the new points. No flash of "Reading…".
    @Test(.timeLimit(.minutes(1))) func aNewDayFileKeepsTheLastReadUntilTheNewReadLands() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.kaisa])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        _ = await model.points(game: "riftbound", productID: Self.dockside)
        #expect(model.dayPoints(game: "riftbound", productID: Self.dockside, finish: "Normal")?.map(\.day) == Self.archiveDays)
        try placeArchives(model, ["2025-12-29"])
        _ = try await model.archiveGate.decode(day: "2025-12-29", games: Games.all)
        let held = HeldReads()
        held.hold()
        model.historyDayReader = held.reader
        await model.notePriceDays()
        let reading = Task { await model.readDayPrices(game: "riftbound", productID: Self.dockside) }
        try await until { held.isWaiting }
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
        #expect(model.dayPoints(game: "riftbound", productID: Self.dockside, finish: "Normal")?.map(\.day) == Self.archiveDays)
        held.release()
        await reading.value
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
        #expect(model.dayPoints(game: "riftbound", productID: Self.dockside, finish: "Normal")?.map(\.day)
                    == ["2025-12-29"] + Self.archiveDays)
    }

    // MARK: Gates (Global Constraints, H7)

    /// With no folder chosen nothing is read or written and no pass runs; the state is unknown.
    @Test(.timeLimit(.minutes(1))) func noPassBeforeTheFolderIsRead() async throws {
        let root = tempRoot()
        let model = try await offlineModel(root, extra: ["-askUserFolder", "YES"])
        await model.start()
        model.requestHistory()
        await model.waitForHistory()
        #expect(model.historyPassCount == 0)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .unknown)
    }

    /// G11: while the first-run question is due no pass runs and the history file is not read; "Continue" lets it run.
    @Test(.timeLimit(.minutes(1))) func noPassWhileTheFirstRunQuestionIsDue() async throws {
        let root = tempRoot()
        let history = PriceHistory(days: ["2026-01-02"], products: [Self.dockside: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        try FileManager.default.createDirectory(at: user(root), withIntermediateDirectories: true)
        try history.data().write(to: historyURL(root))
        let model = try await offlineModel(root, extra: ["-onboarding", "YES"])
        await model.start()
        #expect(model.onboardingDue)
        model.requestHistory()
        await model.waitForHistory()
        #expect(model.historyPassCount == 0)
        #expect(model.history(game: "riftbound") == nil)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .unknown)
        await model.finishOnboarding(["riftbound": .all])
        await model.waitForHistory()
        #expect(model.historyPassCount >= 1)
        #expect(model.history(game: "riftbound") == history)
    }

    /// A missing folder: no pass, nothing written, the state unknown.
    @Test(.timeLimit(.minutes(1))) func noPassWithAMissingFolder() async throws {
        let root = tempRoot()
        let model = try await offlineModel(root)
        try FileManager.default.removeItem(at: user(root))
        await model.start()
        #expect(model.library.folderIsMissing)
        model.requestHistory()
        await model.waitForHistory()
        #expect(model.historyPassCount == 0)
        #expect(!exists(user(root)))
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .unknown)
    }

    /// G5: a game that is not followed tracks nothing, and its history file is left as it is (bytes and date).
    @Test(.timeLimit(.minutes(1))) func noPassForAGameThatIsNotFollowed() async throws {
        let root = tempRoot()
        let old = PriceHistory(days: ["2025-12-01"], products: [Self.kaisa: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside], extra: #","profile":{"followed":false}"#),
                         "cyberpunk": Self.gameFile(rows: [719684])])
        try old.data().write(to: historyURL(root))
        let written = try sizeAndDate(historyURL(root))
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(try Data(contentsOf: historyURL(root)) == old.data())
        #expect(try sizeAndDate(historyURL(root)).date == written.date)
        #expect(model.history(game: "riftbound") == nil)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .unknown)
        #expect(exists(historyURL(root, "cyberpunk")))                        // the followed game is passed
    }

    /// H7: while the game's catalog step is still to come or running, a pass neither reads nor writes its history (its
    /// printings are not all known); once the step has ended, the pass writes the file.
    @Test(.timeLimit(.minutes(1))) func noPassWhileTheGamesCatalogIsNotSettled() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile()])
        let network = HistoryNetwork()
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"]),
                             catalogClient: network, archiveClient: network, fetcher: network, now: { Self.day1 })
        model.historyQuietTime = .zero
        try placeArchives(model, Self.archiveDays)
        await model.start()
        await model.waitForHistory()
        #expect(!exists(historyURL(root)))                                    // nothing tracked yet
        await network.hold()
        let run = Task { await model.refresh(rebuild: false) }
        while await !network.isHolding { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!model.catalogSettled(game: "riftbound"))
        let passes = model.historyPassCount
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.dockside, finish: "Normal"), name: "D")
        await model.waitForHistory()
        #expect(model.historyPassCount > passes)
        #expect(!exists(historyURL(root)))
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) != true)
        await network.release()
        await run.value
        await model.waitForHistory()
        #expect(try stored(root).has(productID: Self.dockside))
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) == true)
    }

    /// A game whose game file is refused (a newer version) is not passed: its history file is untouched, the state unknown.
    @Test(.timeLimit(.minutes(1))) func noPassForAGameWhoseFileIsRefused() async throws {
        let root = tempRoot()
        let old = PriceHistory(days: ["2025-12-01"], products: [Self.dockside: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        try write(root, ["riftbound": #"{"version":99,"collection":[\#(Self.row(Self.kaisa))]}"#])
        try old.data().write(to: historyURL(root))
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(!model.library.canChange(game: "riftbound"))
        #expect(try Data(contentsOf: historyURL(root)) == old.data())
        #expect(model.history(game: "riftbound") == nil)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .unknown)
    }

    // MARK: Bad timing (Review Focus 3)

    /// A game turned off while a pass runs: the pass ends, and that game's result is neither kept nor written.
    @Test(.timeLimit(.minutes(1))) func aGameTurnedOffDuringAPassIsNotWritten() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        model.historyPassHook = { games in
            guard games.contains("riftbound") else { return }
            model.library.setProfile(GameProfile(followed: false), game: "riftbound")
            model.profilesChanged()
        }
        await model.start()
        await model.waitForHistory()
        #expect(model.historyPassCount >= 1)
        #expect(!exists(historyURL(root)))
        #expect(model.history(game: "riftbound") == nil)
    }

    /// G7, H6: without the player role the decks' cards are not tracked: the printing stays until a write that adds a day
    /// (a write that adds only a product keeps it: final fix M1) and leaves at it.
    @Test(.timeLimit(.minutes(1))) func thePlayerRoleOffStopsTrackingDeckCards() async throws {
        let root = tempRoot()
        let deck = #","decks":[{"id":"rb1","name":"Wind","format":"standard","active":true,"cards":[{"cardKey":"\#(Self.docksideKey)","name":"Dockside Lock-Up","section":"main","count":2}]}]"#
        try write(root, ["riftbound": Self.gameFile(extra: deck)])
        var now = Self.day1
        let model = try await offlineModel(root, now: { now })
        await model.start()
        await model.waitForHistory()
        #expect(try stored(root).has(productID: Self.dockside))
        model.library.setProfile(GameProfile(player: false), game: "riftbound")
        model.profilesChanged()
        await model.waitForHistory()
        #expect(try stored(root).has(productID: Self.dockside))               // a removal alone writes nothing
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "K")
        await model.waitForHistory()
        #expect(try stored(root).products.keys.sorted() == [Self.dockside, Self.kaisa])  // a new product alone keeps it
        now = Self.day2
        try await placeDayFiles(model, ["2026-01-03"])
        model.library.setCount(2, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "K")
        await model.waitForHistory()
        #expect(try stored(root).days.last == "2026-01-03")
        #expect(try stored(root).products.keys.sorted() == [Self.kaisa])
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) == false)
    }

    // MARK: Files that must not be replaced (H3, Review Focus 2)

    @Test(.timeLimit(.minutes(1))) func aNewerHistoryFileIsNeverRewritten() async throws {
        let root = tempRoot()
        let newer = Data(#"{"version":2,"days":[],"products":{}}"#.utf8)
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        try newer.write(to: historyURL(root))
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "K")
        await model.waitForHistory()
        #expect(try Data(contentsOf: historyURL(root)) == newer)
        // Phase 5B (K6): the blocked file's sentence only for a printing the day files give no point of.
        #expect(await state(model, Self.dockside) == .ready)
        #expect(await state(model, Self.unpriced) == .newerVersion)
        #expect(model.history(game: "riftbound") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aPlaceholderIsNeverReplaced() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), ".riftbound.prices.json.icloud": ""])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(!exists(historyURL(root)))
        #expect(exists(user(root).appending(path: ".riftbound.prices.json.icloud")))
        #expect(await state(model, Self.dockside) == .ready)
        #expect(await state(model, Self.unpriced) == .notDownloaded)
    }

    @Test(.timeLimit(.minutes(1))) func aMalformedHistoryFileIsReplacedByTheNextWrite() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "riftbound.prices.json": "not json"])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.days == Self.archiveDays)
        #expect(history.has(productID: Self.dockside))
        #expect(await state(model, Self.dockside) == .ready)
    }

    /// The create rule: a file that appears between the read (none) and the creating write is read, not replaced; the
    /// pass after it adds what it lacks.
    @Test(.timeLimit(.minutes(1))) func aFileThatAppearsBeforeACreatingWriteIsReadNotReplaced() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside, Self.kaisa])])
        let other = PriceHistory(days: ["2026-01-02"], products: [Self.kaisa: ["Normal": [ShownPrice(amount: 3, isLow: false)]]])
        let model = try await offlineModel(root)
        var passes = 0
        var onDiskAtSecondPass: Data?
        let file = historyURL(root)
        model.historyPassHook = { games in
            guard games.contains("riftbound") else { return }
            passes += 1
            if passes == 1 { try? other.data().write(to: file) }               // another device, after the read
            if passes == 2 { onDiskAtSecondPass = try? Data(contentsOf: file) }
        }
        await model.start()
        await model.waitForHistory()
        #expect(onDiskAtSecondPass == other.data())
        let history = try stored(root)
        #expect(history.days == Self.archiveDays)
        #expect(history.products.keys.sorted() == [Self.dockside, Self.kaisa])
        #expect(history.points(productID: Self.kaisa, finish: "Normal").last?.amount == 3)   // the other device's day
        #expect(model.history(game: "riftbound") == history)
    }

    // MARK: Another device, another folder (H11)

    @Test(.timeLimit(.minutes(1))) func aHistoryFileChangedOnDiskReplacesMemory() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        var changed = try stored(root)
        changed.setDay("2025-12-01", rows: [Self.dockside: ["Normal": ShownPrice(amount: 4, isLow: false)]], for: [Self.dockside])
        try UserFiles.write(changed.data(), to: historyURL(root))
        let version = model.historyVersions["riftbound", default: 0]
        await model.library.fileChanged(historyURL(root))?.value
        await model.waitForHistory()
        #expect(model.history(game: "riftbound") == changed)
        #expect(model.historyVersions["riftbound", default: 0] > version)
        #expect(try stored(root) == changed)                                  // nothing new: not written again
    }

    @Test(.timeLimit(.minutes(1))) func aFolderSwitchDropsTheHistoryInMemory() async throws {
        let root = tempRoot()
        let first = root.appending(path: "icloud").appending(path: "TCG Collection")
        let second = root.appending(path: "second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(Self.gameFile(rows: [Self.dockside]).utf8).write(to: first.appending(path: "riftbound.json"))
        let model = try await offlineModel(root, extra: ["-askUserFolder", "YES"])
        await model.start()
        try await model.useICloudDrive()
        await model.waitForHistory()
        #expect(model.history(game: "riftbound")?.has(productID: Self.dockside) == true)
        #expect(exists(first.appending(path: "riftbound.prices.json")))
        try await model.useFolder(second)
        #expect(model.history(game: "riftbound") == nil)
        await model.waitForHistory()
        #expect(model.history(game: "riftbound") == nil)
        #expect(!exists(second.appending(path: "riftbound.prices.json")))
    }

    // MARK: Review round 1

    /// Finding 1: a report of a history file while the first-run question is due reads nothing (a read settles conflict
    /// versions, which writes): the file keeps its bytes and its date.
    @Test(.timeLimit(.minutes(1))) func aReportedHistoryFileIsNotReadWhileTheFirstRunQuestionIsDue() async throws {
        let root = tempRoot()
        let history = PriceHistory(days: ["2026-01-02"], products: [Self.dockside: ["Normal": [ShownPrice(amount: 1, isLow: false)]]])
        try FileManager.default.createDirectory(at: user(root), withIntermediateDirectories: true)
        try history.data().write(to: historyURL(root))
        let written = try sizeAndDate(historyURL(root))
        let model = try await offlineModel(root, extra: ["-onboarding", "YES"])
        let reads = FileReads()
        model.historyFileReader = reads.read
        await model.start()
        #expect(model.onboardingDue)
        // As if a pass had read the file in this folder before the question became due: only the gates hold the read.
        model.historyFolder = model.library.folder
        model.historyOnDisk["riftbound"] = .file
        #expect(model.library.fileChanged(historyURL(root)) == nil)
        await model.waitForHistory()
        try await Task.sleep(for: .milliseconds(100))                         // a read outside the queue would be done
        #expect(reads.count == 0)
        #expect(model.historyOnDisk["riftbound"] == nil)                      // forgotten: read once the gate opens
        #expect(try Data(contentsOf: historyURL(root)) == history.data())
        #expect(try sizeAndDate(historyURL(root)).date == written.date)
    }

    /// Finding 1: a report for a game that is not followed reads nothing; once the game is followed again the next pass
    /// reads the file (memory forgot its read).
    @Test(.timeLimit(.minutes(1))) func aReportedHistoryFileOfAGameNotFollowedIsNotRead() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "cyberpunk": Self.gameFile()])
        let model = try await offlineModel(root)
        let fileReads = FileReads()
        model.historyFileReader = fileReads.read
        await model.start()
        await model.waitForHistory()
        model.library.setProfile(GameProfile(followed: false), game: "riftbound")
        model.profilesChanged()
        await model.waitForHistory()
        var changed = try stored(root)
        changed.setDay("2025-12-01", rows: [Self.dockside: ["Normal": ShownPrice(amount: 4, isLow: false)]], for: [Self.dockside])
        try changed.data().write(to: historyURL(root))
        let written = try sizeAndDate(historyURL(root))
        let reads = fileReads.count
        await model.library.fileChanged(historyURL(root))?.value
        await model.waitForHistory()
        try await Task.sleep(for: .milliseconds(100))                         // a read outside the queue would be done
        #expect(fileReads.count == reads)
        #expect(try sizeAndDate(historyURL(root)).date == written.date)
        model.library.setProfile(.all, game: "riftbound")
        model.profilesChanged()
        await model.waitForHistory()
        #expect(fileReads.count > reads)
        #expect(model.history(game: "riftbound") == changed)
    }

    /// Finding 2: a pass cancelled during one game's write sets and writes nothing for the games after it. The next pass
    /// does.
    @Test(.timeLimit(.minutes(1))) func aPassCancelledBetweenTwoGamesSetsAndWritesNothingMore() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "cyberpunk": Self.gameFile(rows: [719684])])
        let model = try await offlineModel(root)
        var cancelled = false
        model.historyWriteHook = { game in
            guard !cancelled, game == "riftbound" else { return }
            cancelled = true
            model.cancelHistoryPass()
        }
        await model.start()
        await model.waitForHistory()
        #expect(cancelled)
        #expect(exists(historyURL(root)))
        #expect(!exists(historyURL(root, "cyberpunk")))
        #expect(model.history(game: "cyberpunk") == nil)
        model.requestHistory()
        await model.waitForHistory()
        #expect(exists(historyURL(root, "cyberpunk")))
    }

    /// Findings 3, 4: a history file another device writes during a pass is read only after the pass (in the queue), and
    /// is not replaced by the pass's result: that result is dropped, the file is read, and a new pass adds what it lacks.
    @Test(.timeLimit(.minutes(1))) func aHistoryFileWrittenElsewhereDuringAPassIsNotReplaced() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "riftbound.prices.json": "not json"])
        let model = try await offlineModel(root)
        let fileReads = FileReads()
        model.historyFileReader = fileReads.read
        let other = PriceHistory(days: ["2025-12-01"], products: [Self.dockside: ["Normal": [ShownPrice(amount: 4, isLow: false)]]])
        let file = historyURL(root)
        var readsDuringPass: (before: Int, after: Int)?
        model.historyPassHook = { games in
            guard readsDuringPass == nil, games.contains("riftbound") else { return }
            let before = fileReads.count
            try? UserFiles.write(other.data(), to: file)                       // another device, during the pass
            model.library.fileChanged(file)
            try? await Task.sleep(for: .milliseconds(50))
            readsDuringPass = (before, fileReads.count)
        }
        await model.start()
        await model.waitForHistory()
        #expect(readsDuringPass?.before == readsDuringPass?.after)           // not read beside the running pass
        let history = try stored(root)
        #expect(history.days == ["2025-12-01"] + Self.archiveDays)
        #expect(history.points(productID: Self.dockside, finish: "Normal").first?.amount == 4)
        #expect(model.history(game: "riftbound") == history)
    }

    // Phase 5B task 4: 5A's "Finding 5" test (a card just put on Wanted read `.reading` at once) is gone with
    // `.notTracked`: every printing reads its points from the day files, tracked or not.

    // MARK: Review round 2

    /// A: a report while the folder is missing (after its load) makes memory forget the read; once the folder is back the
    /// next pass reads the file another device wrote and adds to it, never writes over it from stale memory.
    @Test(.timeLimit(.minutes(1))) func aReportWhileTheFolderIsMissingIsReadOnceTheFolderIsBack() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        let away = root.appending(path: "away")
        try FileManager.default.moveItem(at: user(root), to: away)
        await model.library.fileChanged(user(root).appending(path: "riftbound.json"))?.value
        #expect(model.library.folderIsMissing)
        // Another device writes the history while the folder is away, and it is reported.
        let otherHistory = PriceHistory(days: ["2025-12-01"], products: [Self.dockside: ["Normal": [ShownPrice(amount: 4, isLow: false)]]])
        try otherHistory.data().write(to: away.appending(path: "riftbound.prices.json"))
        #expect(model.library.fileChanged(historyURL(root)) == nil)
        try await placeDayFiles(model, ["2025-12-29"])                              // a new day, so the next pass writes
        try FileManager.default.moveItem(at: away, to: user(root))
        await model.library.fileChanged(user(root).appending(path: "riftbound.json"))?.value
        #expect(!model.library.folderIsMissing)
        model.requestHistory()
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.days == ["2025-12-01", "2025-12-29"] + Self.archiveDays)
        #expect(history.points(productID: Self.dockside, finish: "Normal").first?.amount == 4)
        #expect(model.history(game: "riftbound") == history)
    }

    // Phase 5B task 4: 5A's test "D" (a deck card's printing read `.reading` at once) is gone with `.notTracked`.

    // MARK: Review round 3: a read or a write counts only when no report followed it

    /// The other device's version of the Riftbound file: the file on disk now plus a day it read (2025-12-01, $4).
    private func otherDevice(_ root: URL) throws -> PriceHistory {
        var other = try stored(root)
        other.setDay("2025-12-01", rows: [Self.dockside: ["Normal": ShownPrice(amount: 4, isLow: false)]], for: [Self.dockside])
        return other
    }

    /// F: a reset (a pass cancel) while a reported file is read: the read is forgotten, read again, and the other device's
    /// day survives the next write.
    @Test(.timeLimit(.minutes(1))) func aResetDuringAStaleReadForgetsTheRead() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        let reads = FileReads()
        model.historyFileReader = reads.read
        await model.start()
        await model.waitForHistory()
        let other = try otherDevice(root)
        try UserFiles.write(other.data(), to: historyURL(root))
        reads.during { game in
            guard game == "riftbound" else { return }
            reads.during(nil)
            Self.onMain { model.requestCatalogReset() }
        }
        model.library.fileChanged(historyURL(root))
        await model.waitForHistory()
        try await placeDayFiles(model, ["2025-12-29"])
        model.requestHistory()
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.days == ["2025-12-01", "2025-12-29"] + Self.archiveDays)
        #expect(model.history(game: "riftbound") == history)
    }

    /// G: a report while a pass reads the file (the read returns the older content): the result is not taken, the file is
    /// read again before any write, and the newer content survives.
    @Test(.timeLimit(.minutes(1))) func aReportDuringAReadIsNotOverwrittenByTheReadsResult() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        let reads = FileReads()
        model.historyFileReader = reads.read
        await model.start()
        await model.waitForHistory()
        let other = try otherDevice(root)
        let file = historyURL(root)
        model.historyOnDisk["riftbound"] = nil                                // the next pass reads the file first
        reads.during { game in
            guard game == "riftbound" else { return }
            reads.during(nil)
            try? UserFiles.write(other.data(), to: file)                       // after this read read the file
            Self.onMain { _ = model.library.fileChanged(file) }
        }
        try await placeDayFiles(model, ["2025-12-29"])
        model.requestHistory()
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.days == ["2025-12-01", "2025-12-29"] + Self.archiveDays)
        #expect(model.history(game: "riftbound") == history)
    }

    /// H: a report during a pass's write (here under a closed game gate, which forgets the read): the write is not
    /// recorded, the file is read again, and the other device's day survives the next write.
    @Test(.timeLimit(.minutes(1))) func aReportDuringAWriteIsReadAgain() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        let file = historyURL(root)
        var fired = false
        model.historyWriteHook = { game in
            guard !fired, game == "riftbound" else { return }
            fired = true
            if let other = try? self.otherDevice(root) { try? UserFiles.write(other.data(), to: file) }
            model.library.setProfile(GameProfile(followed: false), game: "riftbound")
            _ = model.library.fileChanged(file)
            model.library.setProfile(.all, game: "riftbound")
        }
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "K")
        await model.waitForHistory()
        #expect(fired)
        try await placeDayFiles(model, ["2025-12-29"])
        model.requestHistory()
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.days == ["2025-12-01", "2025-12-29"] + Self.archiveDays)
        #expect(history.has(productID: Self.kaisa))
        #expect(model.history(game: "riftbound") == history)
    }

    /// The echo of the model's own write (a report of the file it just wrote): at most one more read, no write, no pass.
    @Test(.timeLimit(.minutes(1))) func theEchoOfOurOwnWriteCausesNoSecondWrite() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside])])
        let model = try await offlineModel(root)
        let reads = FileReads()
        model.historyFileReader = reads.read
        await model.start()
        await model.waitForHistory()
        let written = try sizeAndDate(historyURL(root))
        let (passes, before) = (model.historyPassCount, reads.count)
        model.library.fileChanged(historyURL(root))
        await model.waitForHistory()
        #expect(reads.count <= before + 1)
        #expect(model.historyPassCount == passes)
        #expect(try sizeAndDate(historyURL(root)).date == written.date)
        #expect(await state(model, Self.dockside) == .ready)
    }

    /// C: a game unfollowed while another game's file is read is not read by that pass.
    @Test(.timeLimit(.minutes(1))) func aGameUnfollowedDuringAnotherGamesReadIsNotRead() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside]), "cyberpunk": Self.gameFile(rows: [719684])])
        let model = try await offlineModel(root)
        let reads = FileReads()
        model.historyFileReader = reads.read
        reads.during { game in
            guard game == "riftbound" else { return }
            reads.during(nil)
            Self.onMain { model.library.setProfile(GameProfile(followed: false), game: "cyberpunk") }
        }
        await model.start()
        await model.waitForHistory()
        #expect(reads.games.contains("riftbound"))
        #expect(!reads.games.contains("cyberpunk"))
        #expect(!exists(historyURL(root, "cyberpunk")))
    }

    // MARK: Days (H10)

    /// A price step that brings a new day adds that day to every tracked product, from its archive alone.
    @Test(.timeLimit(.minutes(1))) func aNewPriceDayAddsOneDayToEveryTrackedProduct() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside, Self.kaisa])])
        let network = HistoryNetwork()
        var now = Self.day1
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"]),
                             catalogClient: network, archiveClient: network, fetcher: network, now: { now })
        model.historyQuietTime = .zero
        let reads = Reads()
        model.historyDayReader = reads.reader
        try placeArchives(model, ["2025-12-30", "2025-12-31"])
        await model.start()
        await model.waitForHistory()
        #expect(try stored(root).days == ["2025-12-30", "2025-12-31", "2026-01-02"])
        let before = reads.count
        now = Self.day2
        await model.refresh(rebuild: false)
        await model.waitForHistory()
        #expect(await network.archives.contains("2026-01-03"))
        #expect(reads.count == before + 1)
        let history = try stored(root)
        #expect(history.days == ["2025-12-30", "2025-12-31", "2026-01-02", "2026-01-03"])
        for id in [Self.dockside, Self.kaisa] { #expect(history.products[id]?.values.allSatisfy { $0.count == 4 } == true) }
        #expect(history.points(productID: Self.dockside, finish: "Normal").count == 4)
        #expect(model.history(game: "riftbound") == history)
    }
}

/// The network of the online tests: Riftbound's fixture set list and products (no set of any other game); any day's
/// archive is the fixture archive; no picture index. After `hold()`, Riftbound's next set list waits until `release()`.
private actor HistoryNetwork {
    private static let noSets = Data(#"{"success":true,"errors":[],"results":[],"totalItems":0}"#.utf8)
    private var held = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false
    private(set) var archives: [String] = []

    func hold() { held = true }

    func release() {
        held = false
        isHolding = false
        waiting?.resume()
        waiting = nil
    }

    func groups(category: Int) async throws -> Data {
        guard category == 89 else { return Self.noSets }
        if held {
            isHolding = true
            await withCheckedContinuation { waiting = $0 }
        }
        return try fixture("groups-89.json")
    }

    func products(category: Int, group: Int) async throws -> Data { try fixture("products-89.json") }

    func download(day: String, to file: URL) async throws -> Bool {
        archives.append(day)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: file)
        return true
    }

    func data(from url: URL) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}

extension HistoryNetwork: TCGCSVFetching, ArchiveFetching, DataFetching {}
