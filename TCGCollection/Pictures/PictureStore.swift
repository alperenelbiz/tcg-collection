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

/// One picture file of the cache as the cleaning sees it: its name, its size and when it was last used (its modification
/// date: `PictureStore` sets it when it reads the file for a caller, once per run).
nonisolated struct CachedPicture: Sendable, Equatable {
    let name: String
    let bytes: Int
    let used: Date
}

/// Downloads each picture once and reads it from disk after that. At most `downloadsAtOnce` downloads run at a time over
/// every caller (the galleries' cells, the card pages, a PDF export); a picture on disk never waits for one.
/// The folder holds at most `cacheLimit` bytes of pictures after a cleaning (`clean`, once per launch).
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
    private var slotsTaken = 0
    /// The callers waiting for a slot, first come first served.
    private var queue: [(id: Int, resume: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter = 0

    /// The files read from disk for a caller in this run, whose modification date is set already (`markUsed`).
    private var usedThisRun: Set<String> = []

    #if DEBUG
    /// Test seam: the download slots taken now.
    var downloadsRunning: Int { slotsTaken }
    /// Test seam: the callers waiting for a download slot.
    var downloadsWaiting: Int { queue.count }
    #endif

    init(directory: URL, fetcher: any DataFetching) {
        self.directory = directory
        self.fetcher = fetcher
    }

    /// The picture at `url`: from disk, else downloaded once (a download already running for it is joined). Nil for a bad
    /// answer (not asked again in this run), no network, or a caller cancelled while it waited for a download slot.
    func data(for url: URL) async -> Data? {
        let file = fileURL(for: url)
        if let cached = try? Data(contentsOf: file) {
            markUsed(file)
            return cached
        }
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
            if body == nil { failed.insert(url) } else { usedThisRun.insert(file.lastPathComponent) }  // written now
            return body
        case .failure:
            return nil
        }
    }

    /// Takes a download slot, waiting in line for one when all are taken. False when the calling task is cancelled before
    /// it got one: it leaves the line and holds no slot.
    private func takeSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if slotsTaken < Self.downloadsAtOnce {
            slotsTaken += 1
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
            slotsTaken -= 1
        } else {
            queue.removeFirst().resume.resume(returning: true)
        }
    }

    private func freeSlot(returning data: Data?) -> Data? {
        freeSlot()
        return data
    }

    /// A picture read from disk for a caller was used now: its modification date says so, for the cleaning of a later
    /// launch. Once per file per run, so scrolling a gallery does not write dates over and over.
    private func markUsed(_ file: URL) {
        guard usedThisRun.insert(file.lastPathComponent).inserted else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
    }

    private func fileURL(for url: URL) -> URL {
        directory.appending(path: fileName(for: url))
    }

    /// `<host>-<last two path components>`, so `cards_small/1.jpg` and `cards/1.jpg` differ.
    nonisolated func fileName(for url: URL) -> String {
        let tail = url.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "-")
        return "\(url.host() ?? "unknown")-\(tail)"
    }

    // MARK: The cache limit

    /// At most this many bytes of pictures stay in the folder after a cleaning: 3 GB.
    static let cacheLimit = 3 * 1024 * 1024 * 1024
    /// A cleaning over the limit deletes until the pictures take at most this share of it.
    static let cleanedShare = 0.9

    /// A picture file of this store: a `.jpg` (every picture address ends so) that is not hidden. Anything else in the
    /// folder (a temporary file of an atomic write, a file put there by hand) is never listed, so never deleted.
    static func isPicture(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(".jpg")
    }

    /// A small picture of a build before feedback 1 (TCGplayer `<id>_200w.jpg`, YGOPRODeck `cards_small/<id>.jpg`, named
    /// as `fileName(for:)` names them). No build asks for them any more.
    static func isOldSmallPicture(_ name: String) -> Bool {
        (name.hasPrefix("tcgplayer-cdn.tcgplayer.com-product-") && name.hasSuffix("_200w.jpg"))
            || (name.hasPrefix("images.ygoprodeck.com-cards_small-") && name.hasSuffix(".jpg"))
    }

    /// What a cleaning deletes, in this order: every old small picture (by name), whatever the folder's size; then, when
    /// the other pictures take more than `limit` bytes, the least recently used of them (equal dates by name) until they
    /// take at most 90 % of it.
    static func filesToDelete(_ files: [CachedPicture], limit: Int) -> [String] {
        let old = files.filter { isOldSmallPicture($0.name) }.map(\.name).sorted()
        let kept = files.filter { !isOldSmallPicture($0.name) }
        var total = kept.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return old }
        let target = Int(Double(limit) * cleanedShare)
        var deleted: [String] = []
        for file in kept.sorted(by: { ($0.used, $0.name) < ($1.used, $1.name) }) where total > target {
            deleted.append(file.name)
            total -= file.bytes
        }
        return old + deleted
    }

    /// Lists the picture files of this store's folder (`isPicture`; not its subfolders, nothing outside it), deletes what
    /// `filesToDelete` names, and returns those names. Synchronous file work: the caller runs it off the main thread and
    /// off this actor, so no picture load waits for it. A picture deleted here is downloaded again when a cell asks for it.
    nonisolated func clean(limit: Int = PictureStore.cacheLimit) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }
        let files = urls.compactMap { url -> CachedPicture? in
            let name = url.lastPathComponent
            guard Self.isPicture(name), let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return CachedPicture(name: name, bytes: values.fileSize ?? 0, used: values.contentModificationDate ?? .distantPast)
        }
        return Self.filesToDelete(files, limit: limit).filter { name in
            (try? fm.removeItem(at: directory.appending(path: name))) != nil
        }
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
