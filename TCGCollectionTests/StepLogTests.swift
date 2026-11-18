import Foundation
import Testing
@testable import TCGCollection2

/// Phase 6B (A65, Review Focus 4): one stdout line per step, prefix `tcg: `, game ids, day strings, counts of sets and
/// days and durations only. No name, path or count of copies can fit a line.
struct StepLogTests {
    /// The pattern of an allowed line: a step word, then `key=value` pairs whose values have no space, slash or quote.
    private static func isAllowed(_ line: String) -> Bool {
        line.wholeMatch(of: /^tcg: [a-z-]+( [a-z-]+=[A-Za-z0-9.:-]+)*$/) != nil
    }

    /// One value of every case. `sampleCovers` is an exhaustive switch: a new case does not compile until it has a sample.
    private static let samples: [StepLogEvent] = [
        .launch(platform: .iphone, build: .release),
        .folderRead(games: 4, notDownloaded: 1, seconds: 0.25),
        .folderMissing,
        .fileNotDownloaded(file: .game("riftbound")),
        .fileArrived(file: .history("yu-gi-oh")),
        .fileArrived(file: .settings),
        .catalogStart(games: ["magic-the-gathering", "yu-gi-oh"]),
        .catalogEnd(games: ["riftbound"], sets: 12, failed: 1, listsFailed: 1, cut: false, seconds: 34.5),
        .priceStart,
        .priceEnd(day: "2026-11-17", result: .failed, seconds: 3.2),
        .migrationStart(archives: 3),
        .migrationEnd(days: 3, seconds: 11),
        .backfillStart(days: 90),
        .backfillProgress(done: 10, total: 90),
        .backfillEnd(done: 42, total: 90, result: .cut),
        .backgroundSaveStart,
        .backgroundSaveExpired,
        .backgroundSaveEnd(seconds: 0.04),
        .background(syncCut: true, backfillCut: false),
        .resume,
    ]

    private static func sampleCovers(_ event: StepLogEvent) -> Bool {
        switch event {
        case .launch, .folderRead, .folderMissing, .fileNotDownloaded, .fileArrived, .catalogStart, .catalogEnd,
             .priceStart, .priceEnd, .migrationStart, .migrationEnd, .backfillStart, .backfillProgress, .backfillEnd,
             .backgroundSaveStart, .backgroundSaveExpired, .backgroundSaveEnd, .background, .resume:
            true
        }
    }

    @Test func everyLineHasThePrefixAndAllowedTokensOnly() {
        for event in Self.samples {
            #expect(Self.sampleCovers(event))
            let line = StepLog.line(event)
            #expect(line.hasPrefix("tcg: "), "\(line)")
            #expect(Self.isAllowed(line), "\(line)")
            #expect(!line.contains("/"), "\(line)")
        }
    }

    @Test func theLinesSayTheirSteps() {
        #expect(StepLog.line(.launch(platform: .mac, build: .debug)) == "tcg: launch platform=mac build=debug")
        #expect(StepLog.line(.folderRead(games: 4, notDownloaded: 0, seconds: 0.123))
                == "tcg: folder-read games=4 not-downloaded=0 seconds=0.12")
        #expect(StepLog.line(.fileNotDownloaded(file: .game("riftbound")))
                == "tcg: file-not-downloaded game=riftbound file=game")
        #expect(StepLog.line(.fileArrived(file: .settings)) == "tcg: file-arrived file=settings")
        #expect(StepLog.line(.catalogStart(games: ["riftbound", "cyberpunk"])) == "tcg: catalog-start games=riftbound:cyberpunk")
        #expect(StepLog.line(.catalogEnd(games: ["riftbound"], sets: 12, failed: 0, listsFailed: 0, cut: false, seconds: 2))
                == "tcg: catalog-end games=riftbound sets=12 failed=0 lists-failed=0 cut=no seconds=2.00")
        #expect(StepLog.line(.priceEnd(day: "2026-11-17", result: .ok, seconds: 1.5))
                == "tcg: price-end day=2026-11-17 result=ok seconds=1.50")
        #expect(StepLog.line(.priceEnd(day: nil, result: .cut, seconds: 0)) == "tcg: price-end day=none result=cut seconds=0.00")
        #expect(StepLog.line(.backfillProgress(done: 20, total: 90)) == "tcg: backfill-progress done=20 total=90")
        #expect(StepLog.line(.backfillEnd(done: 90, total: 90, result: .done)) == "tcg: backfill-end done=90 total=90 result=done")
        #expect(StepLog.line(.background(syncCut: true, backfillCut: false)) == "tcg: background sync=cut backfill=idle")
    }

    /// Review Focus 4: a value that is not a known game id or a day string is never printed.
    @Test func aGameIDIsTheOnlyNameAllowed() {
        for game in Games.all {
            #expect(StepLog.line(.fileArrived(file: .game(game.id))) == "tcg: file-arrived game=\(game.id) file=game")
        }
        #expect(StepLog.line(.fileArrived(file: .game("My Deck"))) == "tcg: file-arrived game=unknown file=game")
        #expect(StepLog.line(.fileNotDownloaded(file: .history("/Users/x/riftbound")))
                == "tcg: file-not-downloaded game=unknown file=history")
        #expect(StepLog.line(.catalogStart(games: ["riftbound", "Lightning Bolt"])) == "tcg: catalog-start games=riftbound:unknown")
        #expect(StepLog.line(.catalogStart(games: [])) == "tcg: catalog-start games=none")
        #expect(StepLog.line(.priceEnd(day: "17 Nov 2026", result: .ok, seconds: 1))
                == "tcg: price-end day=unknown result=ok seconds=1.00")
        #expect(StepLog.line(.priceEnd(day: "2026-11-17/../x", result: .ok, seconds: 1))
                == "tcg: price-end day=unknown result=ok seconds=1.00")
    }

    @Test func aDurationIsNeverNegativeOrNotANumber() {
        #expect(StepLog.line(.migrationEnd(days: 1, seconds: -3)) == "tcg: migration-end days=1 seconds=0.00")
        #expect(StepLog.line(.migrationEnd(days: 1, seconds: .nan)) == "tcg: migration-end days=1 seconds=0.00")
        #expect(StepLog.line(.migrationEnd(days: -2, seconds: .infinity)) == "tcg: migration-end days=0 seconds=0.00")
    }

    @Test func aFileOfTheFolderIsNamedByItsKind() {
        #expect(StepLogFile(named: "riftbound.json") == .game("riftbound"))
        #expect(StepLogFile(named: "yu-gi-oh.prices.json") == .history("yu-gi-oh"))
        #expect(StepLogFile(named: "settings.json") == .settings)
        #expect(StepLogFile(named: "notes.txt") == nil)
    }

    /// Fix round 1: a write to a pipe whose reader is gone (the console detached) throws EPIPE; SIGPIPE is ignored and
    /// the error is dropped, so the app is not killed.
    @Test func aWriteToAClosedPipeDoesNotCrash() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        StepLog.write(StepLog.line(.resume), to: pipe.fileHandleForWriting)
        StepLog.write(StepLog.line(.resume), to: pipe.fileHandleForWriting)
    }

    /// Fix round 1: a write to a closed handle throws (the throwing API), and the error is dropped.
    @Test func aWriteToAClosedHandleDoesNotCrash() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        try writer.close()
        StepLog.write(StepLog.line(.resume), to: writer)
    }

    /// Fix round 1, ruling G5 (2): a line is written only on the iPhone; the Mac's stdout stays as before.
    @Test func onlyTheIPhonePrints() {
        #if os(iOS)
        #expect(StepLog.prints)
        #else
        #expect(!StepLog.prints)
        #endif
    }
}
