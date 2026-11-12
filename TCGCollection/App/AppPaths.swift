import Foundation

/// Every on-disk location, derived from one root. With no root the app uses the system folders.
nonisolated struct AppPaths: Sendable {
    let support: URL
    let caches: URL

    init(root: URL?) {
        let fm = FileManager.default
        if let root {
            support = root.appending(path: "support", directoryHint: .isDirectory)
            caches = root.appending(path: "caches", directoryHint: .isDirectory)
        } else {
            (support, caches) = Self.systemFolders()
        }
        for dir in [support, caches] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The folders used with no root. A Debug build has its own, so a Debug run without `-store` never opens
    /// the installed app's store.
    static func systemFolders() -> (support: URL, caches: URL) {
        #if DEBUG
        let name = debugFolderName
        #else
        let name = "TCGCollection2"
        #endif
        return (URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory),
                URL.cachesDirectory.appending(path: name, directoryHint: .isDirectory))
    }

    /// The Debug build's folder name under Application Support and Caches.
    static let debugFolderName = "TCGCollection2-Debug"

    /// The user folder of a `-store <root>` run: `<root>/user`. Such a run never keeps user files anywhere else.
    static func userTestRoot(_ root: URL) -> URL { root.appending(path: "user") }

    var catalogStore: URL { support.appending(path: "catalog.store") }

    /// Where a catalog store that cannot be opened is moved: `unreadable-yyyy-MM-dd-HHmmss` (local time).
    func unreadable(at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return support.appending(path: "unreadable-\(formatter.string(from: date))", directoryHint: .isDirectory)
    }
    func prices(_ gameID: String) -> URL { support.appending(path: "prices-\(gameID).json") }
    func facets(_ gameID: String) -> URL { support.appending(path: "facets-\(gameID).json") }
    var ygoIndex: URL { support.appending(path: "ygo-index.json") }
    var archives: URL { caches.appending(path: "archives", directoryHint: .isDirectory) }
    var pictures: URL { caches.appending(path: "pictures", directoryHint: .isDirectory) }
}
