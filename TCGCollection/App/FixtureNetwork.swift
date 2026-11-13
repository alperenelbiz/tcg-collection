#if DEBUG
import Foundation

// `-fixtures <dir>`: the three network protocols served from the files of one folder, so a UI test (another
// process, where no fake can be injected) never uses the network. The fixture network is not a model of
// tcgcsv's calendar or of its errors.

/// tcgcsv from files: `groups-<category>.json` is the set list, and `products-<category>.json` answers every set
/// of that category. A missing file throws.
nonisolated struct FileCatalogClient: TCGCSVFetching {
    let directory: URL
    /// `-fixtureDelay`: each products answer waits this long first (a cancelled task stops waiting and throws).
    var productsDelay: Duration = .zero

    func groups(category: Int) async throws -> Data {
        try Data(contentsOf: directory.appending(path: "groups-\(category).json"))
    }

    func products(category: Int, group: Int) async throws -> Data {
        if productsDelay > .zero { try await Task.sleep(for: productsDelay) }
        return try Data(contentsOf: directory.appending(path: "products-\(category).json"))
    }
}

/// The daily price archive from files: the one `prices-*.ppmd.7z` in the folder answers every day.
nonisolated struct FileArchiveClient: ArchiveFetching {
    let directory: URL

    func download(day: String, to file: URL) async throws -> Bool {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("prices-") && $0.hasSuffix(".ppmd.7z") }
        guard names.count == 1 else { throw FixtureNetworkError.notOneArchive(found: names.count, in: directory) }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: file)
        try fm.copyItem(at: directory.appending(path: names[0]), to: file)
        return true
    }
}

/// Plain GET requests from files: `cardinfo.php` is `cardinfo-sample.json`; every other URL is `picture.jpg`.
nonisolated struct FileFetcher: DataFetching {
    let directory: URL
    /// `-pictureDelay`: each picture answer waits this long first.
    var picturesDelay: Duration = .zero

    func data(from url: URL) async throws -> (Data, Int) {
        let index = url.lastPathComponent == "cardinfo.php"
        if !index, picturesDelay > .zero { try await Task.sleep(for: picturesDelay) }
        return (try Data(contentsOf: directory.appending(path: index ? "cardinfo-sample.json" : "picture.jpg")), 200)
    }
}

nonisolated enum FixtureNetworkError: LocalizedError {
    case notOneArchive(found: Int, in: URL)

    var errorDescription: String? {
        switch self {
        case .notOneArchive(let found, let directory):
            "The fixture folder \(directory.path) has \(found) price archives; it needs exactly one."
        }
    }
}
#endif
