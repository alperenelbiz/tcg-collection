import Foundation

nonisolated protocol DataFetching: Sendable {
    /// The body and the HTTP status of a GET request.
    func data(from url: URL) async throws -> (Data, Int)
}

nonisolated struct URLSessionFetcher: DataFetching {
    var session: URLSession = .shared

    func data(from url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("TCGCollection/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Downloads each picture once and reads it from disk after that.
actor PictureStore {
    nonisolated let directory: URL
    private let fetcher: any DataFetching
    /// A task's value is nil for a bad HTTP answer; it throws when no answer came (no network).
    private var inFlight: [URL: Task<Data?, any Error>] = [:]
    /// URLs with a bad HTTP answer: not asked again in this run. A thrown error is not remembered.
    private var failed: Set<URL> = []

    init(directory: URL, fetcher: any DataFetching) {
        self.directory = directory
        self.fetcher = fetcher
    }

    func data(for url: URL) async -> Data? {
        let file = fileURL(for: url)
        if let cached = try? Data(contentsOf: file) { return cached }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return try? await running.value }
        let fetcher = fetcher
        let directory = directory
        let task = Task<Data?, any Error> {
            let (body, status) = try await fetcher.data(from: url)
            guard status == 200, body.count > 1_000 else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? body.write(to: file, options: .atomic)
            return body
        }
        inFlight[url] = task
        let result = await task.result
        inFlight[url] = nil
        switch result {
        case .success(let body):
            if body == nil { failed.insert(url) }
            return body
        case .failure:
            return nil
        }
    }

    /// `<host>-<last two path components>`, so `cards_small/1.jpg` and `cards/1.jpg` differ.
    private func fileURL(for url: URL) -> URL {
        let tail = url.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "-")
        return directory.appending(path: "\(url.host() ?? "unknown")-\(tail)")
    }
}

/// Keeps the small Yu-Gi-Oh! picture index. The 21 MB `cardinfo.php` body is never kept.
actor YGOIndexLoader {
    private let paths: AppPaths
    private let fetcher: any DataFetching
    private var cached: YGOPictureIndex?

    init(paths: AppPaths, fetcher: any DataFetching) {
        self.paths = paths
        self.fetcher = fetcher
    }

    func current() -> YGOPictureIndex? {
        if cached == nil, let data = try? Data(contentsOf: paths.ygoIndex) {
            cached = try? JSONDecoder().decode(YGOPictureIndex.self, from: data)
        }
        return cached
    }

    func refresh() async throws -> YGOPictureIndex {
        let url = URL(string: "https://db.ygoprodeck.com/api/v7/cardinfo.php")!
        let (body, status) = try await fetcher.data(from: url)
        guard status == 200 else { throw TCGCSVClientError(status: status) }
        let index = try YGOPictureIndex(cardinfo: body)
        try JSONEncoder().encode(index).write(to: paths.ygoIndex, options: .atomic)
        cached = index
        return index
    }
}
