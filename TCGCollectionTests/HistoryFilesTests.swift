import Foundation
import Testing
@testable import TCGCollection2

/// The history file on disk (A34, H1, H3, H4; Review Focus 1, 2), in a temporary folder. The conflict path itself
/// (`NSFileVersion` conflict versions) needs two devices and iCloud: only its decision is tested here.
struct HistoryFilesTests {
    private let sample = PriceHistory(days: ["2026-01-02", "2026-01-03"],
                                      products: [7: ["Normal": [ShownPrice(amount: 1.5, isLow: false), nil],
                                                     "Foil": [nil, ShownPrice(amount: 9.5, isLow: true)]]])

    // MARK: Names (H1)

    @Test func theFileNameOfAGame() {
        #expect(HistoryFiles.name(game: "riftbound") == "riftbound.prices.json")
        #expect(HistoryFiles.name(game: "magic-the-gathering") == "magic-the-gathering.prices.json")
    }

    /// Only `<game id>.prices.json` of a known game is a history file: a game file, an unknown game, a conflict backup, a
    /// hidden file or a placeholder is not.
    @Test func whichFilesAreHistoryFiles() {
        #expect(HistoryFiles.gameID(ofFileNamed: "riftbound.prices.json") == "riftbound")
        #expect(HistoryFiles.gameID(ofFileNamed: "yu-gi-oh.prices.json") == "yu-gi-oh")
        for name in ["riftbound.json", "x.prices.json", "pokemon.prices.json", "riftbound.conflict-2026-11-12-101500.json",
                     "riftbound.prices.conflict-2026-11-12-101500.json", ".riftbound.prices.json",
                     ".riftbound.prices.json.icloud", "riftbound.prices.json.tmp", "settings.json", "prices.json",
                     ".prices.json", "riftbound.PRICES.json"] {
            #expect(HistoryFiles.gameID(ofFileNamed: name) == nil, "\(name)")
        }
    }

    // MARK: Reading (H3)

    @Test func aReadOfNoFileIsNone() throws {
        #expect(try HistoryFiles.read(game: "riftbound", in: tempDir()) == HistoryFiles.Read.none)
    }

    /// A file iCloud has not downloaded is not missing: it is never read as empty (and never written, below).
    @Test func aPlaceholderIsNotDownloaded() throws {
        let dir = tempDir()
        try Data().write(to: dir.appending(path: ".riftbound.prices.json.icloud"))
        #expect(try HistoryFiles.read(game: "riftbound", in: dir) == .notDownloaded)
    }

    @Test func aMalformedFileReadsAsMalformed() throws {
        let dir = tempDir()
        for text in ["not json", "", "[1]", #"{"version":1}"#, #"{"version":"1","days":[],"products":{}}"#] {
            try Data(text.utf8).write(to: dir.appending(path: "riftbound.prices.json"))
            #expect(try HistoryFiles.read(game: "riftbound", in: dir) == .malformed, "\(text)")
        }
    }

    @Test func aNewerFileReadsAsNewerVersion() throws {
        let dir = tempDir()
        try Data(#"{"version":2,"days":[],"products":{}}"#.utf8).write(to: dir.appending(path: "riftbound.prices.json"))
        #expect(try HistoryFiles.read(game: "riftbound", in: dir) == .newerVersion)
    }

    /// A creating write then a read give the history back; the folder holds only that file (no backup, nothing else).
    @Test func aWrittenHistoryReadsBack() throws {
        let dir = tempDir()
        try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: true)
        #expect(try HistoryFiles.read(game: "riftbound", in: dir) == .history(sample))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["riftbound.prices.json"])
        #expect(try Data(contentsOf: dir.appending(path: "riftbound.prices.json")) == sample.data())
    }

    // MARK: Writing (the create rule, H3)

    /// A creating write (the app read no file) never replaces a file or a placeholder that arrived after the read.
    @Test func aCreatingWriteNeverReplacesAFileOrAPlaceholder() throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.prices.json")
        let other = Data(#"{"days":[],"products":{},"version":1}"#.utf8)
        try other.write(to: file)
        #expect(throws: UserFilesError.appeared) { try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: true) }
        #expect(try Data(contentsOf: file) == other)

        let placeholderDir = tempDir()
        try Data("p".utf8).write(to: placeholderDir.appending(path: ".riftbound.prices.json.icloud"))
        #expect(throws: UserFilesError.appeared) {
            try HistoryFiles.write(sample, game: "riftbound", in: placeholderDir, creating: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: placeholderDir.path) == [".riftbound.prices.json.icloud"])
    }

    /// A write over a file the app read: a file of a newer version and a placeholder are never replaced; a malformed
    /// file is (H3: everything in it can be read again from the archives); a file of this version is.
    @Test func whatAWriteMayReplace() throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.prices.json")
        let newer = Data(#"{"version":2,"days":[],"products":{}}"#.utf8)
        try newer.write(to: file)
        #expect(throws: UserFilesError.notRewritable(newerVersion: true)) {
            try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: false)
        }
        #expect(try Data(contentsOf: file) == newer)

        try Data("not json".utf8).write(to: file)
        try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: false)
        #expect(try Data(contentsOf: file) == sample.data())

        try HistoryFiles.write(PriceHistory(), game: "riftbound", in: dir, creating: false)
        #expect(try Data(contentsOf: file) == PriceHistory().data())

        let placeholderDir = tempDir()
        try Data("p".utf8).write(to: placeholderDir.appending(path: ".riftbound.prices.json.icloud"))
        #expect(throws: UserFilesError.notDownloaded) {
            try HistoryFiles.write(sample, game: "riftbound", in: placeholderDir, creating: false)
        }
        #expect(!FileManager.default.fileExists(atPath: placeholderDir.appending(path: "riftbound.prices.json").path))
    }

    /// A write never makes a folder: a folder that is gone stays gone.
    @Test func aWriteNeverMakesAFolder() throws {
        let gone = tempDir().appending(path: "not-there")
        for creating in [true, false] {
            #expect(throws: (any Error).self) { try HistoryFiles.write(sample, game: "riftbound", in: gone, creating: creating) }
        }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    /// A history write leaves the game file beside it byte-equal.
    @Test func aHistoryWriteLeavesTheGameFileAlone() throws {
        let dir = tempDir(), gameFile = dir.appending(path: "riftbound.json")
        let bytes = Data(#"{"version":1,"collection":[]}"#.utf8)
        try bytes.write(to: gameFile)
        try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: true)
        #expect(try Data(contentsOf: gameFile) == bytes)
    }

    // MARK: Conflicts (H4)

    /// The decision of `read`'s conflict step: the newest version by date wins (a tie keeps the current one), whatever it
    /// holds; the others are removed without a backup (`HistoryFiles` settles with no backup). A current file of a newer
    /// version is left with all its versions. A malformed current file is settled like any other (H3).
    @Test func conflictsKeepTheNewestAndLeaveNoBackup() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: TimeInterval, _ text: String) -> (date: Date, data: Data) { (t.addingTimeInterval(seconds), Data(text.utf8)) }
        let mine = #"{"days":["2026-01-02"],"products":{},"version":1}"#
        let empty = #"{"days":[],"products":{},"version":1}"#
        let newer = #"{"version":2,"days":[],"products":{}}"#
        #expect(HistoryFiles.conflictPlan([at(60, mine), at(30, empty), at(10, mine)]) == .settle(winner: 0))
        #expect(HistoryFiles.conflictPlan([at(0, mine), at(30, empty), at(90, mine)]) == .settle(winner: 2))
        #expect(HistoryFiles.conflictPlan([at(5, mine), at(5, empty)]) == .settle(winner: 0))
        // An empty history is not kept apart (it is derived data: the game file's rule does not apply).
        #expect(HistoryFiles.conflictPlan([at(0, mine), at(30, empty)]) == .settle(winner: 1))
        // A malformed current file is replaced by the newest one; a malformed newest one wins and is replaced later (H3).
        #expect(HistoryFiles.conflictPlan([at(0, "not json"), at(30, mine)]) == .settle(winner: 1))
        #expect(HistoryFiles.conflictPlan([at(30, "not json"), at(0, mine)]) == .settle(winner: 0))
        // A newer conflict version may win; a current file of a newer version is left alone.
        #expect(HistoryFiles.conflictPlan([at(0, mine), at(30, newer)]) == .settle(winner: 1))
        #expect(HistoryFiles.conflictPlan([at(0, newer), at(30, mine)]) == .leave)
        #expect(HistoryFiles.conflictPlan([at(0, mine)]) == .settle(winner: 0))
    }

    /// A local file has no conflict versions: a read changes nothing and makes no backup.
    @Test func aReadMakesNoBackup() throws {
        let dir = tempDir()
        try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: true)
        _ = try HistoryFiles.read(game: "riftbound", in: dir)
        _ = try HistoryFiles.read(game: "cyberpunk", in: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["riftbound.prices.json"])
    }

    /// A67: a history file with no content on the device reads as not downloaded, and a write leaves it as it is.
    @Test(.timeLimit(.minutes(1))) func aCloudOnlyHistoryFileReadsAsNotDownloaded() throws {
        let dir = tempDir(), file = dir.appending(path: "riftbound.prices.json")
        try HistoryFiles.write(sample, game: "riftbound", in: dir, creating: true)
        let bytes = try Data(contentsOf: file)
        let cloudOnly = CloudOnlyMarks(["riftbound.prices.json"]).check
        #expect(try HistoryFiles.read(game: "riftbound", in: dir, cloudOnly: cloudOnly) == .notDownloaded)
        #expect(throws: UserFilesError.notDownloaded) {
            try HistoryFiles.write(PriceHistory(days: [], products: [:]), game: "riftbound", in: dir, creating: false,
                                   cloudOnly: cloudOnly)
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try HistoryFiles.read(game: "riftbound", in: dir) == .history(sample))
    }
}
