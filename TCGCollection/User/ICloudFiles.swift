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

    /// A67: whether iCloud keeps the file under its real name with no content on this device (a "dataless" file: its
    /// downloading status is not downloaded). A coordinated read of such a file waits for the download, with no end
    /// when there is no connection, so it is treated as a placeholder. Any error, or a file that is not ubiquitous, is
    /// false. The Mac's iCloud Drive downloads by itself: there it is always false, with no lookup.
    @Sendable static func isCloudOnly(_ url: URL) -> Bool {
        #if os(iOS)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
        #else
        false
        #endif
    }

    /// Asks `download` once for each known file of `names` that is not on this device: a placeholder (by its real name),
    /// or a real name `cloudOnly` says is only in iCloud (A67). By the file's real URL in `folder`, in listing order, each
    /// name once. Returns the names asked for.
    @discardableResult
    static func request(folder: URL, names: [String], download: (URL) -> Void,
                        cloudOnly: (URL) -> Bool = isCloudOnly) -> [String] {
        var asked: [String] = []
        for name in names {
            let real: String
            if let placeholder = placeholders(in: [name], known: known).first {
                real = placeholder
            } else if known.contains(name), cloudOnly(folder.appending(path: name)) {
                real = name
            } else {
                continue
            }
            guard !asked.contains(real) else { continue }
            asked.append(real)
            download(folder.appending(path: real))
        }
        return asked
    }
}
