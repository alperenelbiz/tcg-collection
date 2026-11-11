import Foundation

nonisolated protocol ArchiveFetching: Sendable {
    /// Downloads the archive of `day` to `file`. Returns false when the server has no such archive (404).
    func download(day: String, to file: URL) async throws -> Bool
}

nonisolated struct ArchiveClient: ArchiveFetching {
    var session: URLSession = .shared

    func download(day: String, to file: URL) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://tcgcsv.com/archive/tcgplayer/prices-\(day).ppmd.7z")!)
        request.setValue("TCGCollection/0.1", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            if status == 404 { return false }
            throw TCGCSVClientError(status: status)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: temporary, to: file)
        return true
    }
}

/// Which day's archive to ask for (decision D8): the archive of day D appears at about 20:05 UTC of D.
nonisolated enum PriceDay {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func format(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Yesterday's (UTC) archive until 20:30 UTC, then today's.
    static func wanted(now: Date) -> String {
        let parts = utc.dateComponents([.hour, .minute], from: now)
        let afterPublish = parts.hour! * 60 + parts.minute! >= 20 * 60 + 30
        return afterPublish ? format(now) : format(now.addingTimeInterval(-86_400))
    }

    static func before(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return day }
        return format(date.addingTimeInterval(-86_400))
    }
}

actor PriceSync {
    private let paths: AppPaths
    private let client: any ArchiveFetching

    init(paths: AppPaths, client: any ArchiveFetching) {
        self.paths = paths
        self.client = client
    }

    /// Prices of every game in `games` from the wanted day's archive. Returns nil when `haveDay` is
    /// already that day or newer, or when neither the wanted day nor the day before exists.
    ///
    /// An archive already on disk is never downloaded again. If reading a file that was just
    /// downloaded (or found on disk) throws, `run` rethrows and leaves the file where it is:
    /// a new day brings a new file, so the rule stays true.
    func run(games: [GameDefinition], now: Date, haveDay: String?) async throws -> [String: GamePrices]? {
        let wanted = PriceDay.wanted(now: now)
        for day in [wanted, PriceDay.before(wanted)] {
            if let haveDay, haveDay >= day { return nil }
            let file = paths.archives.appending(path: "prices-\(day).ppmd.7z")
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
                guard try await client.download(day: day, to: file) else { continue }
            }
            return try Self.build(file: file, games: games, day: day)
        }
        return nil
    }

    /// Reads one archive into a `GamePrices` per game id. A game with no rows gets empty rows.
    nonisolated static func build(file: URL, games: [GameDefinition], day: String) throws -> [String: GamePrices] {
        var result: [String: GamePrices] = [:]
        var indexes: [String: [String: Int]] = [:]
        var gameOf: [Int: String] = [:]
        for game in games {
            result[game.id] = GamePrices(day: day, finishes: [], rows: [:])
            gameOf[game.categoryID] = game.id
        }
        try PriceArchive.read(file, categories: Set(gameOf.keys)) { category, _, rows in
            guard let id = gameOf[category] else { return }
            for row in rows {
                var finishIndexes = indexes[id, default: [:]]
                let index: Int
                if let known = finishIndexes[row.finish] {
                    index = known
                } else {
                    index = result[id]!.finishes.count
                    result[id]!.finishes.append(row.finish)
                    finishIndexes[row.finish] = index
                    indexes[id] = finishIndexes
                }
                result[id]!.rows[row.productID, default: [:]][index] = row.price
            }
        }
        return result
    }
}
