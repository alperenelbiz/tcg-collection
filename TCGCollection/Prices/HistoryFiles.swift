import Foundation

/// The price history files of the user folder (A34, H1–H4): `<game id>.prices.json`, one per game, beside the game files.
/// Every read and write is coordinated, as the game files' (`UserFiles`). A build before phase 5 knows a game file only
/// by `<game id>.json` (`UserFiles.gameID(ofFileNamed:)`), so it never reads, rewrites or counts these files.
///
/// `write` writes only what it is told: the caller decides `creating` from what it read (no file: a creating write, which
/// never replaces a file or an iCloud placeholder that arrived after the read). A file of a newer version or a placeholder
/// is never rewritten; a malformed file is (H3: everything in it can be read again from the archives).
nonisolated enum HistoryFiles {
    private static let suffix = ".prices.json"

    /// `riftbound.prices.json`.
    static func name(game: String) -> String { game + suffix }

    /// The game whose history file this is: `<game id>.prices.json` of a known game, nothing else (a game file, a
    /// conflict backup, a hidden file or a placeholder is not).
    static func gameID(ofFileNamed name: String) -> String? {
        guard name.hasSuffix(suffix) else { return nil }
        let id = String(name.dropLast(suffix.count))
        return Games.game(id) != nil ? id : nil
    }

    enum Read: Equatable, Sendable {
        /// No file and no placeholder.
        case none
        case history(PriceHistory)
        /// Not a history file: the next write replaces it (H3).
        case malformed
        /// Written by a newer version of the app: never rewritten (H3).
        case newerVersion
        /// iCloud keeps it as `.<name>.icloud` and has not downloaded it: never rewritten (a download was asked for).
        case notDownloaded
    }

    /// Settles the file's conflict versions first (H4: the newest by date wins, the others are removed with no backup and
    /// no notice; a current file of a newer version is left with all its versions), then reads it. Throws only for an
    /// IO error (a failed read, a conflict that could not be settled).
    /// A67: a file `cloudOnly` says is only in iCloud reads as `notDownloaded` before any coordination.
    static func read(game: String, in folder: URL, cloudOnly: (URL) -> Bool = ICloudFiles.isCloudOnly) throws -> Read {
        let url = folder.appending(path: name(game: game))
        let data: Data?
        do {
            try UserFiles.refuseIfCloudOnly(url, cloudOnly: cloudOnly)
            _ = try UserFiles.settleConflicts(of: url, plan: conflictPlan, backupsAt: nil)
            data = try UserFiles.read(url, cloudOnly: cloudOnly)
        } catch UserFilesError.notDownloaded {
            return .notDownloaded
        }
        guard let data else { return .none }
        do {
            return .history(try PriceHistory(data: data))
        } catch PriceHistoryError.newerVersion {
            return .newerVersion
        } catch {
            return .malformed
        }
    }

    /// Replaces the game's history file, atomically, in one coordinated write that first looks at the file on disk:
    /// `creating` and any file or placeholder there throws `UserFilesError.appeared`; a file of a newer version throws
    /// `notRewritable(newerVersion: true)`; a placeholder throws `notDownloaded`. Nothing is written then. It never makes
    /// a folder.
    static func write(_ history: PriceHistory, game: String, in folder: URL, creating: Bool,
                      cloudOnly: (URL) -> Bool = ICloudFiles.isCloudOnly) throws {
        try UserFiles.writeChecked(history.data(), to: folder.appending(path: name(game: game)), creating: creating,
                                   refusal: refusal, cloudOnly: cloudOnly)
    }

    /// Why a history file with these bytes must not be replaced: only a newer version (H3). Nil when it may be.
    static func refusal(_ onDisk: Data) -> UserFilesError? {
        do {
            _ = try PriceHistory(data: onDisk)
            return nil
        } catch PriceHistoryError.newerVersion {
            return .notRewritable(newerVersion: true)
        } catch {
            return nil
        }
    }

    /// The conflict decision (H4), pure. `versions[0]` is the current file: when it is of a newer version, everything is
    /// left. Else the newest by date wins, whatever it holds (a tie keeps the current one). Only a CURRENT file of a newer
    /// version is protected: an older-dated conflict version written by a newer build loses and is removed.
    static func conflictPlan(_ versions: [(date: Date, data: Data)]) -> ConflictPlan {
        guard let current = versions.first, refusal(current.data) == nil else { return .leave }
        return .settle(winner: UserFiles.newest(of: versions))
    }
}
