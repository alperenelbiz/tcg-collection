import Foundation
import Testing
@testable import TCGCollection2

actor FakeArchive: ArchiveFetching {
    private(set) var calls: [String] = []
    func download(day: String, to file: URL) async throws -> Bool {
        calls.append(day)
        guard day == "2026-01-02" else { return false }
        try FileManager.default.copyItem(at: fixtureURL("prices-2026-01-02.ppmd.7z"), to: file)
        return true
    }
}

struct PriceSyncTests {
    let fake = FakeArchive()
    let paths = AppPaths(root: tempRoot())
    var sync: PriceSync { PriceSync(paths: paths, client: fake) }

    @Test func wantedDayFollowsThePublishTime() {
        #expect(PriceDay.wanted(now: TCGDate.date("2026-11-11T15:36:00")!) == "2026-11-10")
        #expect(PriceDay.wanted(now: TCGDate.date("2026-11-11T20:31:00")!) == "2026-11-11")
        #expect(PriceDay.before("2026-03-01") == "2026-02-28")
    }

    @Test func downloadsOnceAndFillsEveryGame() async throws {
        let sync = self.sync
        let out = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: nil)
        #expect(out?["cyberpunk"]?.rows.count == 18); #expect(out?["riftbound"]?.day == "2026-01-02")
        #expect(out?["magic-the-gathering"]?.rows.isEmpty == true)
        _ = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T11:00:00")!, haveDay: nil)
        #expect(await fake.calls == ["2026-01-02"])
    }

    @Test func skipsWhenTheDayIsAlreadyLoaded() async throws {
        #expect(try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: "2026-01-02") == nil)
        #expect(await fake.calls.isEmpty)
    }

    @Test func fallsBackOneDayOnA404() async throws {
        let out = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T21:00:00")!, haveDay: nil)
        #expect(out?["riftbound"]?.day == "2026-01-02"); #expect(await fake.calls == ["2026-01-03", "2026-01-02"])
    }

    @Test func returnsNilWhenNeitherDayExists() async throws {
        #expect(try await sync.run(games: Games.all, now: TCGDate.date("2026-02-10T10:00:00")!, haveDay: nil) == nil)
        #expect(await fake.calls == ["2026-02-09", "2026-02-08"])
    }

    @Test func aBrokenFileOnDiskIsRethrownAndKept() async throws {
        let file = paths.archives.appending(path: "prices-2026-01-02.ppmd.7z")
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("not-an-archive.7z"), to: file)
        await #expect(throws: PriceArchiveError.self) {
            try await self.sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: nil)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await fake.calls.isEmpty)
    }
}
