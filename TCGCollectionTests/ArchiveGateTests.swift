import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// The archive gate (phase 5B task 2: A47, K3, K10, K11): every archive is decoded once, into the price tables and the
/// day file; the day file is read back before the archive goes.
struct ArchiveGateTests {
    let paths = AppPaths(root: tempRoot())

    /// Counts the archive reads and the reads running at once (the most seen), then reads as the app does.
    final class Reads: Sendable {
        private let state = Mutex<(files: [String], running: Int, most: Int)>(([], 0, 0))
        let pause: Double
        init(pause: Double = 0) { self.pause = pause }
        var files: [String] { state.withLock { $0.files } }
        var count: Int { files.count }
        var most: Int { state.withLock { $0.most } }
        func read(_ url: URL, _ categories: Set<Int>, _ each: (Int, Int, [PriceRow]) -> Void) throws {
            state.withLock {
                $0.files.append(url.lastPathComponent)
                $0.running += 1
                $0.most = max($0.most, $0.running)
            }
            defer { state.withLock { $0.running -= 1 } }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            try PriceArchive.read(url, categories: categories, each: each)
        }
    }

    private func archive(_ day: String) -> URL { paths.archives.appending(path: ArchiveGate.archiveName(day: day)) }

    private func place(_ days: [String], from name: String = "prices-2026-01-02.ppmd.7z") throws {
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        for day in days { try FileManager.default.copyItem(at: fixtureURL(name), to: archive(day)) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aDecodeWritesTheDayFileThenDeletesTheArchive() async throws {
        try place(["2026-01-02"])
        let reads = Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        let tables = try await gate.decode(day: "2026-01-02", games: Games.all)
        #expect(reads.count == 1)
        #expect(tables["cyberpunk"]?.rows.count == 18)
        #expect(tables["riftbound"]?.day == "2026-01-02")
        #expect(!exists(archive("2026-01-02")))
        let reader = try PriceDayReader(url: paths.priceDay("2026-01-02"))
        #expect(reader.day == "2026-01-02")
        // Every shown price of the table is in the day file.
        let riftbound = Games.game("riftbound")!
        for (productID, _) in tables["riftbound"]!.rows {
            let fromTable = Dictionary(uniqueKeysWithValues: tables["riftbound"]!.prices(productID: productID)
                .compactMap { price in price.price.shown.map { (price.finish, $0) } })
            #expect(reader.prices(category: riftbound.categoryID, productID: productID) == fromTable)
        }
        #expect(await gate.dayFiles() == ["2026-01-02"])
        #expect(await gate.writtenCount == 1)
    }

    @Test func aDayFileThatDoesNotReadBackKeepsTheArchive() async throws {
        try place(["2026-01-02"])
        // A writer that drops the last row's last byte and fixes nothing else: the file does not read.
        let truncating: ArchiveGate.Writer = { data, url in try PriceDayFile.write(data.dropLast(), to: url) }
        let gate = ArchiveGate(paths: paths, write: truncating)
        await #expect(throws: (any Error).self) { try await gate.decode(day: "2026-01-02", games: Games.all) }
        #expect(exists(archive("2026-01-02")))
        #expect(!exists(paths.priceDay("2026-01-02")))
        #expect(await gate.failedDays == ["2026-01-02"])

        // A writer whose file reads but holds another price: the rows do not compare.
        let root2 = AppPaths(root: tempRoot())
        try FileManager.default.createDirectory(at: root2.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"),
                                         to: root2.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-02")))
        let lying: ArchiveGate.Writer = { _, url in
            let rows = [Games.game("riftbound")!.categoryID: [PriceDayRow(productID: 1, finish: "Normal",
                                                                         price: ShownPrice(amount: 1, isLow: false))]]
            try PriceDayFile.write(PriceDayFile.data(day: "2026-01-02", rows: rows), to: url)
        }
        let gate2 = ArchiveGate(paths: root2, write: lying)
        await #expect(throws: ArchiveGateError.readBackMismatch("2026-01-02")) {
            try await gate2.decode(day: "2026-01-02", games: Games.all)
        }
        #expect(exists(root2.archives.appending(path: ArchiveGate.archiveName(day: "2026-01-02"))))
        #expect(!exists(root2.priceDay("2026-01-02")))
        #expect(await gate2.writtenCount == 0)
    }

    @Test func aFailedDecodeKeepsTheArchiveAndNamesTheDayFailed() async throws {
        try place(["2026-01-03"], from: "not-an-archive.7z")
        let reads = Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        await #expect(throws: PriceArchiveError.self) { try await gate.decode(day: "2026-01-03", games: Games.all) }
        #expect(exists(archive("2026-01-03")))
        #expect(!exists(paths.priceDay("2026-01-03")))
        #expect(await gate.failedDays == ["2026-01-03"])
        // Not decoded again in this run.
        await #expect(throws: ArchiveGateError.failedBefore("2026-01-03")) {
            try await gate.decode(day: "2026-01-03", games: Games.all)
        }
        #expect(reads.count == 1)
    }

    /// The price step, a game turned on and a migration started together: one decode at a time.
    @Test func twoDecodesNeverRunAtOnce() async throws {
        try place(["2025-12-30", "2025-12-31"])
        let reads = Reads(pause: 0.05)
        let gate = ArchiveGate(paths: paths, read: reads.read)
        let fake = FakeArchive()
        let sync = PriceSync(paths: paths, client: fake, gate: gate)
        let now = TCGDate.date("2026-01-03T10:00:00")!
        let window = PriceDay.window(endingOn: "2026-01-02")
        async let step = sync.run(games: Games.all, now: now, haveDay: nil)
        async let turnedOn = sync.run(games: [Games.game("yu-gi-oh")!], now: now, haveDay: nil, download: false)
        async let migration: Void = gate.migrate(window: window, games: Games.all) { _, _ in }
        let (a, b, _) = try await (step, turnedOn, migration)
        #expect(a?["riftbound"]?.day == "2026-01-02")
        _ = b
        #expect(reads.count == 3)
        #expect(reads.most == 1)
        #expect(await gate.dayFiles() == ["2025-12-30", "2025-12-31", "2026-01-02"])
    }

    /// Review 1, item 1: the day is written under `<day>.prices.tmp` and gets its name only once it is verified; while
    /// the writer runs there is no `.prices` and the archive is there.
    @Test func theDayFileGetsItsNameOnlyOnceVerified() async throws {
        try place(["2026-01-02"])
        let dayFile = paths.priceDay("2026-01-02"), archiveFile = archive("2026-01-02")
        let seen = Mutex<[String]>([])
        let watching: ArchiveGate.Writer = { data, url in
            seen.withLock { $0.append(url.lastPathComponent) }
            #expect(!FileManager.default.fileExists(atPath: dayFile.path))
            #expect(FileManager.default.fileExists(atPath: archiveFile.path))
            try PriceDayFile.write(data, to: url)
        }
        let gate = ArchiveGate(paths: paths, write: watching)
        _ = try await gate.decode(day: "2026-01-02", games: Games.all)
        #expect(seen.withLock { $0 } == ["2026-01-02.prices.tmp"])
        #expect(exists(dayFile) && !exists(archiveFile))
        #expect(!exists(paths.priceDays.appending(path: "2026-01-02.prices.tmp")))
    }

    /// A kill after the temporary write (the `.tmp` is there, no `.prices`): the next decode reads the archive again.
    @Test func aKillAfterTheTemporaryWriteDecodesAgain() async throws {
        try place(["2026-01-02"])
        try FileManager.default.createDirectory(at: paths.priceDays, withIntermediateDirectories: true)
        let stale = paths.priceDays.appending(path: "2026-01-02.prices.tmp")
        try Data([1, 2, 3]).write(to: stale)
        let reads = Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        let tables = try await gate.decode(day: "2026-01-02", games: Games.all)
        #expect(reads.count == 1)
        #expect(tables["cyberpunk"]?.rows.count == 18)
        #expect(try PriceDayReader(url: paths.priceDay("2026-01-02")).day == "2026-01-02")
        #expect(!exists(stale) && !exists(archive("2026-01-02")))
    }

    /// A `.prices` whose header names another day is not this day's file: the archive is kept.
    @Test func aDayFileOfAnotherDayKeepsTheArchive() async throws {
        try place(["2026-01-02"])
        try PriceDayFile.write(PriceDayFile.data(day: "2026-01-01", rows: [:]), to: paths.priceDay("2026-01-02"))
        let reads = Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        await #expect(throws: ArchiveGateError.unreadableDayFile("2026-01-02")) {
            try await gate.decode(day: "2026-01-02", games: Games.all)
        }
        #expect(exists(archive("2026-01-02")))
        #expect(reads.count == 0)
    }

    /// Review 1, item 5: a file with a row more than went in does not read back.
    @Test func aDayFileWithAnExtraRowDoesNotReadBack() async throws {
        try place(["2026-01-02"])
        let category = Games.game("magic-the-gathering")!.categoryID
        let extra: ArchiveGate.Writer = { data, url in
            // The real rows plus one Magic row (the fixture has none): every row that went in is still found.
            let reader = try PriceDayReader(data: data)
            var rows: [Int: [PriceDayRow]] = [:]
            for c in reader.categories { rows[c] = reader.rows(category: c) }
            rows[category, default: []].append(PriceDayRow(productID: 5, finish: "Normal", price: ShownPrice(amount: 1, isLow: false)))
            try PriceDayFile.write(PriceDayFile.data(day: reader.day, rows: rows), to: url)
        }
        let gate = ArchiveGate(paths: paths, write: extra)
        await #expect(throws: ArchiveGateError.readBackMismatch("2026-01-02")) {
            try await gate.decode(day: "2026-01-02", games: Games.all)
        }
        #expect(exists(archive("2026-01-02")) && !exists(paths.priceDay("2026-01-02")))
    }

    @Test func anArchiveWhoseDayFileExistsIsDeletedWithoutADecode() async throws {
        try place(["2026-01-02"])
        let first = ArchiveGate(paths: paths)
        _ = try await first.decode(day: "2026-01-02", games: Games.all)
        try place(["2026-01-02"])                                       // the archive again (an old build, a copy)
        let reads = Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        let tables = try await gate.decode(day: "2026-01-02", games: Games.all)
        #expect(reads.count == 0)
        #expect(!exists(archive("2026-01-02")))
        #expect(tables["riftbound"]?.day == "2026-01-02")
        #expect(tables["cyberpunk"]?.rows.count == 18)                  // the table comes from the day file
        #expect(await gate.writtenCount == 0)
    }

    @Test func theMigrationDecodesTheArchivesOnDiskNewestFirst() async throws {
        try place(["2025-12-30", "2026-01-02", "2025-12-31", "2025-09-01"])   // the last is before the window
        let reads = Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        let seen = Mutex<[String]>([])
        await gate.migrate(window: PriceDay.window(endingOn: "2026-01-02"), games: Games.all) { day, decoded in
            seen.withLock { $0.append(day) }
            #expect(decoded.wroteDayFile)
        }
        #expect(reads.files == ["prices-2026-01-02.ppmd.7z", "prices-2025-12-31.ppmd.7z", "prices-2025-12-30.ppmd.7z"])
        #expect(seen.withLock { $0 } == ["2026-01-02", "2025-12-31", "2025-12-30"])
        #expect(await gate.dayFiles() == ["2025-12-30", "2025-12-31", "2026-01-02"])
        for day in ["2025-12-30", "2025-12-31", "2026-01-02"] { #expect(!exists(archive(day))) }
        #expect(exists(archive("2025-09-01")))                           // the clean-up's, not the migration's
    }

    @Test func theCleanUpDeletesDaysAndArchivesBeforeTheWindowAndTemporaryFiles() async throws {
        let fm = FileManager.default
        let window = PriceDay.window(endingOn: "2026-01-02")             // 2025-10-05 ... 2026-01-02
        try fm.createDirectory(at: paths.priceDays, withIntermediateDirectories: true)
        for day in ["2025-10-04", "2025-10-05", "2025-12-01", "2026-01-02", "2026-01-05"] {
            try Data([1]).write(to: paths.priceDay(day))
        }
        let other = paths.priceDays.appending(path: "notes.txt")
        try Data([1]).write(to: other)
        let staleTemporary = paths.priceDays.appending(path: "2025-12-01.prices.tmp")
        try Data([1]).write(to: staleTemporary)
        try place(["2025-09-30", "2025-12-02"])
        let launch = Date()
        let old = launch.addingTimeInterval(-3600)
        let partial = paths.archives.appending(path: "prices-2025-12-03.ppmd.7z.download")
        let temporary = paths.archives.appending(path: "CFNetworkDownload_ab12.tmp")
        let fresh = paths.archives.appending(path: "prices-2025-12-04.part")
        for file in [partial, temporary, fresh] { try Data([1]).write(to: file) }
        for file in [partial, temporary] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path) }
        try fm.setAttributes([.modificationDate: launch.addingTimeInterval(60)], ofItemAtPath: fresh.path)

        let gate = ArchiveGate(paths: paths)
        await gate.cleanUp(window: window, olderThan: launch)
        #expect(await gate.dayFiles() == ["2025-10-05", "2025-12-01", "2026-01-02", "2026-01-05"])
        #expect(exists(other))                                           // not a day file: not the clean-up's
        #expect(!exists(staleTemporary))                                 // a day file a kill left unverified
        #expect(!exists(archive("2025-09-30")))
        #expect(exists(archive("2025-12-02")))
        #expect(!exists(partial) && !exists(temporary))
        #expect(exists(fresh))                                           // newer than the launch: a download of this run
    }

    /// Only `prices-YYYY-MM-DD.ppmd.7z` of a real day names an archive day (moved from 5A's `HistoryPass` in phase 5B
    /// task 3: archives are the gate's alone).
    @Test func fileNamesThatAreNotArchiveDaysAreIgnored() throws {
        let dir = tempDir()
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: dir.appending(path: "prices-2026-01-02.ppmd.7z"))
        for name in ["prices-2026-1-3.ppmd.7z", "prices-2026-13-40.ppmd.7z", "prices-2026-02-30.ppmd.7z",
                     ".prices-2026-01-05.ppmd.7z", "prices-2026-01-06.ppmd.7z.part", "prices-2026-01-07.7z",
                     "prices-2026-01-08.ppmd.7z.tmp", "notes.txt", "Prices-2026-01-09.ppmd.7z", "xprices-2026-01-04.ppmd.7z"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        try FileManager.default.createDirectory(at: dir.appending(path: "prices-2026-01-03.ppmd.7z"), withIntermediateDirectories: false)
        #expect(ArchiveGate.archiveDays(in: dir) == ["2026-01-02"])
        #expect(ArchiveGate.archiveDays(in: dir.appending(path: "not-there")).isEmpty)
    }
}
