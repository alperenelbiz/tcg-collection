import Foundation

nonisolated enum UserFilesError: Error, Equatable {
    /// iCloud keeps the file as `.<name>.icloud`: it exists, but is not on this device yet. A download was asked for.
    case notDownloaded
}

/// The files of the user folder: `<game id>.json` per game and `settings.json`. Every read and write goes through
/// `NSFileCoordinator`, as the first version's `FolderAccess` does: on the iPhone that downloads a file iCloud has not
/// fetched yet, and it keeps the app from reading a file the sync is still writing.
nonisolated enum UserFiles {
    static let settingsName = "settings.json"

    /// The game whose file this is: `<game id>.json` of a known game, nothing else. A conflict backup
    /// (`riftbound.conflict-….json`), a hidden file, `settings.json` and any other file are not game files.
    static func gameID(ofFileNamed name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let id = String(name.dropLast(".json".count))
        return Games.game(id) != nil ? id : nil
    }

    // MARK: Reading and writing

    /// The file's contents; nil when there is no file.
    static func read(_ url: URL) throws -> Data? {
        let data = try coordinate(reading: url) { url -> Data? in
            do {
                return try Data(contentsOf: url)
            } catch where isNoSuchFile(error) {
                return nil
            }
        }
        if data == nil, FileManager.default.fileExists(atPath: placeholder(of: url).path) {
            // Not missing: reading it as empty and writing would replace the file on every device.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw UserFilesError.notDownloaded
        }
        return data
    }

    /// Replaces the whole file, atomically. It never makes a folder: when the folder is gone the write fails, so a file is
    /// never put where the owner did not choose (Review Focus 3). Only `makeFolder` makes one, from the sheet's choice.
    static func write(_ data: Data, to url: URL) throws {
        try coordinate(writing: url, options: .forReplacing) { url in try data.write(to: url, options: .atomic) }
    }

    /// Writes `settings.json` (`{"version": 1}`) into a folder that has none. The folder must exist; it is not made.
    static func writeSettingsIfMissing(in folder: URL) throws {
        let url = folder.appending(path: settingsName)
        guard try read(url) == nil else { return }
        var data = try JSONSerialization.data(withJSONObject: ["version": 1], options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try write(data, to: url)
    }

    /// Makes one folder whose parent exists (the parent is never made). Nothing happens when the folder is there.
    static func makeFolder(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]) }
            return
        }
        try coordinate(writing: url, options: []) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    // MARK: Conflict versions (Review Focus 1)

    /// Settles the conflict versions iCloud keeps when two devices changed the file offline. The newest of the current
    /// and the conflict versions (by modification date) becomes the file; every other version is first written beside it
    /// as `<name>.conflict-<yyyy-MM-dd-HHmmss>.json`. Only then are the conflict versions marked resolved and removed.
    /// Returns the first backup, or nil when there was no conflict. A version is never removed before its backup is written:
    /// when a backup fails, this throws and every version stays as it was.
    static func resolveConflicts(of url: URL, now: Date) throws -> URL? {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return nil }
        let coordinator = NSFileCoordinator()
        return try coordinate(writing: url, options: .forMerging, coordinator: coordinator) { url in
            let currentDate = NSFileVersion.currentVersionOfItem(at: url)?.modificationDate
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var versions: [(date: Date, data: Data)] = [(currentDate, try Data(contentsOf: url))]
            for version in conflicts {
                versions.append((version.modificationDate ?? .distantPast, try Data(contentsOf: version.url)))
            }
            let winner = newest(of: versions)
            var backups: [URL] = []
            for (index, version) in versions.enumerated() where index != winner {
                // Inside an accessor, a second file is coordinated with the same coordinator.
                let backup = freeConflictURL(for: url, at: now)
                try coordinate(writing: backup, options: .forReplacing, coordinator: coordinator) { backup in
                    try version.data.write(to: backup, options: .atomic)
                }
                backups.append(backup)
            }
            if winner != 0 { try versions[winner].data.write(to: url, options: .atomic) }
            for version in conflicts {
                version.isResolved = true
                // A resolved version that cannot be removed is no conflict any more; its contents are saved above.
                try? version.remove()
            }
            return backups.first
        }
    }

    /// The index of the newest version; a tie keeps the earlier one (index 0 is the current version).
    static func newest(of versions: [(date: Date, data: Data)]) -> Int {
        var best = 0
        for (index, version) in versions.enumerated() where version.date > versions[best].date { best = index }
        return best
    }

    /// `riftbound.conflict-2026-11-12-101500.json` for `riftbound.json` (local time, as the catalog's `unreadable-` folders).
    static func conflictName(for url: URL, at date: Date) -> String {
        conflictName(for: url, at: date, number: 1)
    }

    /// The first backup name beside `url` that is not taken: the plain name, then `-2`, `-3`, …
    static func freeConflictURL(for url: URL, at date: Date) -> URL {
        let folder = url.deletingLastPathComponent()
        var number = 1
        while true {
            let candidate = folder.appending(path: conflictName(for: url, at: date, number: number))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private static func conflictName(for url: URL, at date: Date, number: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = number > 1 ? "-\(number)" : ""
        return "\(url.deletingPathExtension().lastPathComponent).conflict-\(formatter.string(from: date))\(suffix).json"
    }

    // MARK: Coordination

    private static func coordinate<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { url in
            result = Result { try body(url) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func coordinate<T>(writing url: URL, options: NSFileCoordinator.WritingOptions,
                                      coordinator: NSFileCoordinator = NSFileCoordinator(),
                                      _ body: (URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var result: Result<T, any Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinatorError) { url in
            result = Result { try body(url) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    private static func isNoSuchFile(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain { return [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    /// Where iCloud keeps a file that is not downloaded: `.riftbound.json.icloud`.
    private static func placeholder(of url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }
}

// MARK: - Watching the folder

/// Reports files that changed or appeared in one folder. `changed` runs off the main actor and returns when the change
/// has been handled.
nonisolated protocol UserFileWatching: AnyObject, Sendable {
    func start(folder: URL, changed: @escaping @Sendable (URL) async -> Void)
    func stop()
}

/// An `NSFilePresenter` on the user folder: reports a changed, added or moved `*.json` directly in the folder (another
/// device's change arrives through iCloud as a coordinated write), and a file that gained a conflict version. Callbacks
/// arrive on its own serial queue; the library hops to the main actor itself.
nonisolated final class FolderPresenter: NSObject, NSFilePresenter, UserFileWatching, @unchecked Sendable {
    let presentedItemOperationQueue: OperationQueue
    private let lock = NSLock()
    private var folder: URL?
    private var changed: (@Sendable (URL) async -> Void)?
    private var registered = false

    override init() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "FolderPresenter"
        presentedItemOperationQueue = queue
        super.init()
    }

    var presentedItemURL: URL? { lock.withLock { folder } }

    func start(folder: URL, changed: @escaping @Sendable (URL) async -> Void) {
        stop()
        lock.withLock {
            self.folder = folder
            self.changed = changed
            registered = true
        }
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        let wasRegistered = lock.withLock {
            defer { registered = false; folder = nil; changed = nil }
            return registered
        }
        if wasRegistered { NSFileCoordinator.removeFilePresenter(self) }
    }

    func presentedSubitemDidChange(at url: URL) { report(url) }
    func presentedSubitemDidAppear(at url: URL) { report(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { report(oldURL); report(newURL) }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { report(url) }

    private func report(_ url: URL) {
        let (folder, changed) = lock.withLock { (self.folder, self.changed) }
        guard let folder, let changed, url.pathExtension == "json", !url.lastPathComponent.hasPrefix("."),
              UserFolder.isSameFolder(url.deletingLastPathComponent(), folder) else { return }
        Task { await changed(url) }
    }
}
