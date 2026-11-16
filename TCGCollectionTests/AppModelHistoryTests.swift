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
    static let docksideKey = "dockside lock up"

    /// Counts the archives the passes open, then reads them as the app does.
    final class Reads: Sendable {
        private let files = Mutex<[String]>([])
        var count: Int { files.withLock { $0.count } }
        func read(_ url: URL, _ categories: Set<Int>, _ each: (Int, Int, [PriceRow]) -> Void) throws {
            files.withLock { $0.append(url.lastPathComponent) }
            try PriceArchive.read(url, categories: categories, each: each)
        }
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
        if let reads { model.historyArchiveReader = reads.read }
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
            let file = model.paths.archives.appending(path: HistoryPass.archiveName(day: day))
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: file)
            }
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
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
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
        #expect(model.historyState(game: "cyberpunk", productID: 719684) == .notTracked)
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
        #expect(second.historyState(game: "riftbound", productID: Self.dockside) == .ready)
    }

    // MARK: Tracking (A41, A42, H6, H9)

    /// A41: a card put on Wanted is filled from every archive on disk: `.reading` once the pass knows it is tracked, then
    /// `.ready` with one point per archive day.
    @Test(.timeLimit(.minutes(1))) func aCardAddedToWantedIsFilledFromTheArchivesOnDisk() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.kaisa])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .notTracked)
        var seen: [HistoryState] = []
        model.historyPassHook = { _ in seen.append(model.historyState(game: "riftbound", productID: Self.dockside)) }
        model.library.setWanted(1, game: "riftbound", cardKey: Self.docksideKey, name: "Dockside Lock-Up")
        await model.waitForHistory()
        #expect(seen.first == .reading)
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
        #expect(model.history(game: "riftbound")?.points(productID: Self.dockside, finish: "Normal").count == 3)
        #expect(try stored(root).has(productID: Self.dockside))
    }

    /// H9, A42: a printing no longer tracked stays in memory and in the file (no write for a removal alone) and leaves at
    /// the next write.
    @Test(.timeLimit(.minutes(1))) func aPrintingNoLongerTrackedStaysUntilTheNextWrite() async throws {
        let root = tempRoot()
        try write(root, ["riftbound": Self.gameFile(rows: [Self.dockside, Self.kaisa])])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        let bytes = try Data(contentsOf: historyURL(root))
        model.library.setCount(0, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "")
        await model.waitForHistory()
        #expect(try Data(contentsOf: historyURL(root)) == bytes)
        #expect(model.historyState(game: "riftbound", productID: Self.kaisa) == .ready)
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.pack, finish: "Normal"), name: "Pack")
        await model.waitForHistory()
        let history = try stored(root)
        #expect(history.products.keys.sorted() == [Self.pack, Self.dockside])
        #expect(model.historyState(game: "riftbound", productID: Self.kaisa) == .notTracked)
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
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .reading)
        await network.release()
        await run.value
        await model.waitForHistory()
        #expect(try stored(root).has(productID: Self.dockside))
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
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

    /// G7, H6: without the player role the decks' cards are not tracked: the printing stays until the next write and
    /// leaves at it.
    @Test(.timeLimit(.minutes(1))) func thePlayerRoleOffStopsTrackingDeckCards() async throws {
        let root = tempRoot()
        let deck = #","decks":[{"id":"rb1","name":"Wind","format":"standard","active":true,"cards":[{"cardKey":"\#(Self.docksideKey)","name":"Dockside Lock-Up","section":"main","count":2}]}]"#
        try write(root, ["riftbound": Self.gameFile(extra: deck)])
        let model = try await offlineModel(root)
        await model.start()
        await model.waitForHistory()
        #expect(try stored(root).has(productID: Self.dockside))
        model.library.setProfile(GameProfile(player: false), game: "riftbound")
        model.profilesChanged()
        await model.waitForHistory()
        #expect(try stored(root).has(productID: Self.dockside))               // a removal alone writes nothing
        model.library.setCount(1, game: "riftbound", key: PrintingKey(productID: Self.kaisa, finish: "Normal"), name: "K")
        await model.waitForHistory()
        #expect(try stored(root).products.keys.sorted() == [Self.kaisa])
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .notTracked)
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
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .newerVersion)
        #expect(model.historyState(game: "riftbound", productID: Self.rune) == .newerVersion)
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
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .notDownloaded)
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
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .ready)
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
        #expect(model.historyState(game: "riftbound", productID: Self.dockside) == .notTracked)
        #expect(!exists(second.appending(path: "riftbound.prices.json")))
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
        model.historyArchiveReader = reads.read
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
