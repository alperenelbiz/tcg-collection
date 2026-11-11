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
            support = URL.applicationSupportDirectory.appending(path: "TCGCollection2", directoryHint: .isDirectory)
            caches = URL.cachesDirectory.appending(path: "TCGCollection2", directoryHint: .isDirectory)
        }
        for dir in [support, caches] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var catalogStore: URL { support.appending(path: "catalog.store") }
    func prices(_ gameID: String) -> URL { support.appending(path: "prices-\(gameID).json") }
    var ygoIndex: URL { support.appending(path: "ygo-index.json") }
    var archives: URL { caches.appending(path: "archives", directoryHint: .isDirectory) }
    var pictures: URL { caches.appending(path: "pictures", directoryHint: .isDirectory) }
}
