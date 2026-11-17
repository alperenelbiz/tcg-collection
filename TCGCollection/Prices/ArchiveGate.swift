import Foundation

nonisolated enum ArchiveGateError: Error, Equatable {
    /// The day has neither a day file nor an archive on disk.
    case noArchive(String)
    /// The day failed earlier in this run (its archive did not read, or its day file did not read back): not again.
    case failedBefore(String)
    /// The day file of the day is there and does not read (K1: it is not deleted and not replaced).
    case unreadableDayFile(String)
    /// The day file written did not read back with every row that went in: it was removed, the archive kept.
    case readBackMismatch(String)
}

/// The archive gate (phase 5B, K3, A47): every daily price archive is decoded here, once, into the price tables of the
/// games and the day file (`PriceDayFile`); the day file is read back and compared, and only then is the archive deleted.
///
/// One decode at a time in the whole app (an archive read holds about 117 MB): the price step, a game turned on, the
/// migration (K11) and the backfill all come through this actor. A decode runs on the actor's own executor without a
/// suspension, so it is serial; a call such as `dayFiles()` waits behind a running decode. Never on the main actor.
actor ArchiveGate {
    /// Reads one archive: calls the closure for each `(category, group, rows)` of the asked categories.
    typealias Reader = @Sendable (URL, Set<Int>, (Int, Int, [PriceRow]) -> Void) throws -> Void
    /// Writes one day file's bytes to its place (atomically).
    typealias Writer = @Sendable (Data, URL) throws -> Void

    struct Decoded: Sendable {
        let tables: [String: GamePrices]
        /// True when this decode wrote the day file (false: the day file was there already).
        let wroteDayFile: Bool
    }

    nonisolated let paths: AppPaths
    private let read: Reader
    private let write: Writer
    /// The days that failed in this run (K3): their archive is kept and not decoded again in this run.
    private(set) var failedDays: Set<String> = []
    /// The day files written in this run (`AppModel.priceDaysVersion` follows it).
    private(set) var writtenCount = 0

    init(paths: AppPaths, read: @escaping Reader = PriceArchive.read, write: @escaping Writer = PriceDayFile.write) {
        self.paths = paths
        self.read = read
        self.write = write
    }

    private func archive(_ day: String) -> URL { paths.archives.appending(path: HistoryPass.archiveName(day: day)) }

    /// The tables of `games` for `day`. See `decodeDay`.
    func decode(day: String, games: [GameDefinition]) throws -> [String: GamePrices] {
        try decodeDay(day: day, games: games).tables
    }

    /// The tables of `games` for `day`:
    /// - a day file of the day is there: the tables come from it, and the archive (when there is one) is deleted without
    ///   a decode; a day file that does not read throws `unreadableDayFile` and touches nothing;
    /// - else the archive is read once, for every game's category (K1: the day file keeps all four games), the day file
    ///   written, read back and compared, then the archive deleted. A read or a write that fails, or a day file that
    ///   does not read back, keeps the archive and names the day failed for the run.
    func decodeDay(day: String, games: [GameDefinition]) throws -> Decoded {
        let fm = FileManager.default
        let dayFile = paths.priceDay(day)
        let archive = archive(day)
        if fm.fileExists(atPath: dayFile.path) {
            let reader: PriceDayReader
            do { reader = try PriceDayReader(url: dayFile) } catch { throw ArchiveGateError.unreadableDayFile(day) }
            try? fm.removeItem(at: archive)
            return Decoded(tables: Self.tables(of: reader, day: day, games: games), wroteDayFile: false)
        }
        guard !failedDays.contains(day) else { throw ArchiveGateError.failedBefore(day) }
        guard fm.fileExists(atPath: archive.path) else { throw ArchiveGateError.noArchive(day) }

        let all = Games.all
        let gameOf = Dictionary(all.map { ($0.categoryID, $0.id) }, uniquingKeysWith: { first, _ in first })
        var tables: [String: GamePrices] = [:]
        var indexes: [String: [String: Int]] = [:]
        for game in all { tables[game.id] = GamePrices(day: day, finishes: [], rows: [:]) }
        var rows: [Int: [PriceDayRow]] = [:]
        do {
            try read(archive, Set(gameOf.keys)) { category, _, archiveRows in
                guard let id = gameOf[category] else { return }
                for row in archiveRows {
                    var finishIndexes = indexes[id, default: [:]]
                    let index: Int
                    if let known = finishIndexes[row.finish] {
                        index = known
                    } else {
                        index = tables[id]!.finishes.count
                        tables[id]!.finishes.append(row.finish)
                        finishIndexes[row.finish] = index
                        indexes[id] = finishIndexes
                    }
                    tables[id]!.rows[row.productID, default: [:]][index] = row.price
                    if let shown = row.price.shown {
                        rows[category, default: []].append(PriceDayRow(productID: row.productID, finish: row.finish, price: shown))
                    }
                }
            }
        } catch {
            failedDays.insert(day)
            throw error
        }
        // Every game's category has a section, also one without a row: the file says the category was read.
        for game in all where rows[game.categoryID] == nil { rows[game.categoryID] = [] }

        do {
            try write(PriceDayFile.data(day: day, rows: rows), dayFile)
        } catch {
            failedDays.insert(day)
            try? fm.removeItem(at: dayFile)
            throw error
        }
        guard Self.readsBack(dayFile, day: day, rows: rows) else {
            failedDays.insert(day)
            try? fm.removeItem(at: dayFile)
            throw ArchiveGateError.readBackMismatch(day)
        }
        writtenCount += 1
        try? fm.removeItem(at: archive)
        let asked = Set(games.map(\.id))
        return Decoded(tables: tables.filter { asked.contains($0.key) }, wroteDayFile: true)
    }

    /// The days of the day files in `support/price-days`.
    func dayFiles() -> Set<String> { PriceDayFile.days(in: paths.priceDays) }

    /// The days of the archives on disk inside `window`, newest first.
    func archiveDays(in window: ClosedRange<String>) -> [String] {
        HistoryPass.archiveDays(in: paths.archives).filter { window.contains($0) }.sorted(by: >)
    }

    /// K11: every archive on disk whose day is in `window`, newest first, through the gate (a day file there: the archive
    /// is deleted without a decode). `each` gets every day decoded; a day that fails is left (its archive stays).
    func migrate(window: ClosedRange<String>, games: [GameDefinition],
                 each: @Sendable (String, Decoded) async -> Void) async {
        for day in archiveDays(in: window) {
            guard let decoded = try? decodeDay(day: day, games: games) else { continue }
            await each(day, decoded)
        }
    }

    /// K10, once per launch: deletes the day files of days before `window`, the archives of days before `window`
    /// (without a decode), and in the archives folder every regular file that is not exactly `prices-YYYY-MM-DD.ppmd.7z`
    /// and was last changed before `olderThan` (a download cut short). A day file inside the window (or after it) is
    /// never deleted; a file in `price-days` that is not a day file is not the clean-up's.
    func cleanUp(window: ClosedRange<String>, olderThan: Date) {
        let fm = FileManager.default
        for day in PriceDayFile.days(in: paths.priceDays) where day < window.lowerBound {
            try? fm.removeItem(at: paths.priceDay(day))
        }
        let archives = HistoryPass.archiveDays(in: paths.archives)
        for day in archives where day < window.lowerBound { try? fm.removeItem(at: archive(day)) }
        guard let urls = try? fm.contentsOfDirectory(at: paths.archives,
                                                     includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        else { return }
        for url in urls {
            let name = url.lastPathComponent
            if let match = name.wholeMatch(of: /prices-(\d{4}-\d{2}-\d{2})\.ppmd\.7z/), archives.contains(String(match.1)) { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate, date < olderThan else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// The tables of `games` from a day file: each row's shown price as a `Price` (market, or low when marked low).
    nonisolated static func tables(of reader: PriceDayReader, day: String, games: [GameDefinition]) -> [String: GamePrices] {
        var result: [String: GamePrices] = [:]
        for game in games {
            var prices = GamePrices(day: day, finishes: [], rows: [:])
            var index: [String: Int] = [:]
            for row in reader.rows(category: game.categoryID) {
                let i: Int
                if let known = index[row.finish] {
                    i = known
                } else {
                    i = prices.finishes.count
                    prices.finishes.append(row.finish)
                    index[row.finish] = i
                }
                prices.rows[row.productID, default: [:]][i] = PriceDayFile.price(row.price)
            }
            result[game.id] = prices
        }
        return result
    }

    /// True when the day file reads, is of `day`, and holds every row that went in with its price, as the writer stores
    /// it (`PriceDayFile.data`: the first row of a product and finish, the stored rows only).
    nonisolated static func readsBack(_ url: URL, day: String, rows: [Int: [PriceDayRow]]) -> Bool {
        guard let reader = try? PriceDayReader(url: url), reader.day == day else { return false }
        for (category, list) in rows {
            guard category >= 0, category <= Int(UInt32.max) else { continue }
            let names = Set(Array(Set(list.map(\.finish)).filter { $0.utf8.count <= 255 }.sorted().prefix(255)))
            var expected: [Int: [String: ShownPrice]] = [:]
            for row in list {
                guard row.productID >= 0, row.productID <= Int(UInt32.max), names.contains(row.finish),
                      let cents = PriceDayFile.cents(row.price), expected[row.productID]?[row.finish] == nil else { continue }
                expected[row.productID, default: [:]][row.finish] = ShownPrice(amount: Double(cents) / 100, isLow: row.price.isLow)
            }
            for (productID, prices) in expected {
                let found = reader.prices(category: category, productID: productID)
                for (finish, price) in prices where found[finish] != price { return false }
            }
        }
        return true
    }
}
