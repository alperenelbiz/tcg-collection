import Foundation

/// Phase 6B (A62): the files of the user folder that iCloud keeps only in the cloud. iCloud Drive on the iPhone does not
/// download a folder's files by itself: each is a placeholder `.<name>.icloud` until it is asked for. At a load (the
/// launch, a folder switch) the iPhone asks once for every placeholder of a known file; the watcher reports each file
/// when it arrives, and the library reads it then. Until then the game is refused ("not downloaded") and never written.
nonisolated enum ICloudFiles {
    /// The names of the folder's known files: each game's `<game>.json` and `<game>.prices.json`, and `settings.json`.
    static let known: Set<String> = Set(Games.all.flatMap { ["\($0.id).json", HistoryFiles.name(game: $0.id)] })
        .union([UserFiles.settingsName])

    /// The real names of the placeholders in `names` (a folder's listing) whose file is in `known`, in listing order.
    static func placeholders(in names: [String], known: Set<String>) -> [String] {
        names.compactMap { name in
            guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
            let real = String(name.dropFirst().dropLast(".icloud".count))
            return known.contains(real) ? real : nil
        }
    }

    /// The names in `folder`, hidden ones included; none when it cannot be listed.
    static func listing(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// Asks `download` once for each known placeholder of `names`, by the file's real URL in `folder`. Returns the names
    /// asked for.
    @discardableResult
    static func request(folder: URL, names: [String], download: (URL) -> Void) -> [String] {
        let asked = placeholders(in: names, known: known)
        for name in asked { download(folder.appending(path: name)) }
        return asked
    }
}
