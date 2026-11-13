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

/// Downloads each picture once and reads it from disk after that. At most `downloadsAtOnce` downloads run at a time over
/// every caller (the galleries' cells, the card pages, a PDF export); a picture on disk never waits for one.
actor PictureStore {
    nonisolated let directory: URL
    private let fetcher: any DataFetching
    /// A task's value is nil for a bad HTTP answer; it throws when no answer came (no network).
    private var inFlight: [URL: Task<Data?, any Error>] = [:]
    /// URLs with a bad HTTP answer: not asked again in this run. A thrown error is not remembered.
    private var failed: Set<URL> = []

    /// Constraints: at most 4 picture downloads at a time.
    static let downloadsAtOnce = 4
    /// The download slots taken now.
    private(set) var downloadsRunning = 0
    /// The callers waiting for a slot, first come first served.
    private var queue: [(id: Int, resume: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter = 0

    /// The callers waiting for a download slot.
    var downloadsWaiting: Int { queue.count }

    init(directory: URL, fetcher: any DataFetching) {
        self.directory = directory
        self.fetcher = fetcher
    }

    /// The picture at `url`: from disk, else downloaded once (a download already running for it is joined). Nil for a bad
    /// answer (not asked again in this run), no network, or a caller cancelled while it waited for a download slot.
    func data(for url: URL) async -> Data? {
        let file = fileURL(for: url)
        if let cached = try? Data(contentsOf: file) { return cached }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return try? await running.value }
        guard await takeSlot() else { return nil }
        // While this caller waited, another one may have downloaded the picture, or started to.
        if let cached = try? Data(contentsOf: file) { return freeSlot(returning: cached) }
        if failed.contains(url) { return freeSlot(returning: nil) }
        if let running = inFlight[url] {
            freeSlot()
            return try? await running.value
        }
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
        // The slot is held until the download has ended, also when this caller is cancelled meanwhile: the download goes
        // on (other callers may be waiting for it), and its picture is kept on disk.
        let result = await task.result
        inFlight[url] = nil
        freeSlot()
        switch result {
        case .success(let body):
            if body == nil { failed.insert(url) }
            return body
        case .failure:
            return nil
        }
    }

    /// Takes a download slot, waiting in line for one when all are taken. False when the calling task is cancelled before
    /// it got one: it leaves the line and holds no slot.
    private func takeSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if downloadsRunning < Self.downloadsAtOnce {
            downloadsRunning += 1
            return true
        }
        let id = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            // Runs on this actor before it waits; a cancel's `leaveLine` is a later job on the actor, so it finds the
            // caller in the line.
            await withCheckedContinuation { queue.append((id, $0)) }
        } onCancel: {
            Task { await self.leaveLine(id) }
        }
    }

    /// A cancelled caller leaves the line without a slot. Nothing happens when it got one already (it frees it itself).
    private func leaveLine(_ id: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).resume.resume(returning: false)
    }

    /// The slot goes to the first caller in line, or back to the free ones.
    private func freeSlot() {
        if queue.isEmpty {
            downloadsRunning -= 1
        } else {
            queue.removeFirst().resume.resume(returning: true)
        }
    }

    private func freeSlot(returning data: Data?) -> Data? {
        freeSlot()
        return data
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
