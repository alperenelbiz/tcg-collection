import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One cell of a list's PDF before its picture is read: the texts and the address of the small picture (nil: none, the
/// grey block).
nonisolated struct PDFSource: Sendable, Equatable {
    let name: String
    let count: Int
    let price: ShownPrice?
    let picture: URL?

    /// For Sale's whole list (C3, C10): per printing the product name, with ` · <finish>` for a finish other than Normal
    /// (as the cell's `×3 · Foil` tells two finishes apart), the for-sale count, the printing's own price and the product's
    /// small picture. A printing the catalog lacks has its saved name and no picture.
    static func forSale(_ entries: [CollectionEntry], game: GameDefinition, ygo: YGOPictureIndex?) -> [PDFSource] {
        entries.map { entry in
            let finish = entry.row.finish
            let name = finish.caseInsensitiveCompare("Normal") == .orderedSame ? entry.name : "\(entry.name) · \(finish)"
            return PDFSource(name: name, count: entry.row.count, price: entry.price,
                             picture: entry.product.flatMap { PictureSource.url(for: $0, game: game, size: .small, ygo: ygo) })
        }
    }

    /// Wanted's whole list (C2, C12): per card its name, the wanted count, its price as the screen shows it (the pinned
    /// printing's, else the cheapest) and the small picture of the shown printing. A card without a printing has its saved
    /// name and no picture.
    static func wanted(_ cards: [WantedCard], game: GameDefinition, ygo: YGOPictureIndex?) -> [PDFSource] {
        cards.map { card in
            PDFSource(name: card.name, count: card.entry.count, price: card.price,
                      picture: card.shown.flatMap { PictureSource.url(for: $0, game: game, size: .small, ygo: ygo) })
        }
    }
}

/// What one export makes: the PDF's title, the file name the save panel suggests, and the cells.
nonisolated struct PDFJob: Sendable, Equatable {
    let title: String
    let fileName: String
    let items: [PDFSource]

    init(title: String, fileName: String, items: [PDFSource]) {
        self.title = title
        self.fileName = fileName
        self.items = items
    }

    /// "<Game> — <list> — 13 November 2026" and `<game id>-<list>-2026-11-13.pdf`, of the day of `date` in `timeZone`
    /// (the device's: the caller reads the clock, `ListPDF` never does).
    init(list: PDFList, game: GameDefinition, items: [PDFSource], date: Date, timeZone: TimeZone) {
        self.init(title: ListPDF.title(game: game.name, list: list, date: date, timeZone: timeZone),
                  fileName: ListPDF.fileName(gameID: game.id, list: list, date: date, timeZone: timeZone), items: items)
    }
}

/// How far an export is: the items whose picture is settled (read, fetched, or failed), of all items.
nonisolated struct PDFProgress: Sendable, Equatable {
    let done: Int
    let total: Int

    /// The toolbar button's label while the export runs.
    var label: String { "Making PDF… \(done) / \(total)" }
}

/// A PDF that was made, waiting for the save panel.
nonisolated struct PDFMade: Sendable, Equatable {
    let data: Data
    let fileName: String
}

/// The "Make PDF…" export of one list screen (C11). It collects the pictures through `PictureStore` (the disk cache first;
/// a missing picture is downloaded once, and `PictureStore` runs at most 4 downloads at a time over the whole app; one
/// that cannot be had is nil, the grey block), counts `done / total`, can be cancelled, then draws the PDF
/// (`ListPDF.data`) off the main thread. The PDF goes to the save panel (`made`), or to a file (`-exportPDF`). One export
/// at a time; a cancelled one changes nothing more. The screen's state keeps it, so a card page opened on the screen's
/// stack does not stop it; the stack going away (another screen, another game, the window closing) cancels it.
@Observable
final class PDFExport {
    /// While an export runs: how far it is. Nil otherwise.
    private(set) var progress: PDFProgress?
    /// The PDF the last export made, for the save panel; the panel's end clears it.
    var made: PDFMade?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The pictures one export asks `PictureStore` for at a time. `PictureStore` holds the app's limit of 4 downloads;
    /// this window keeps an export of hundreds of items from putting all of them in its line at once, ahead of the
    /// pictures a gallery asks for meanwhile.
    nonisolated static let picturesAtOnce = 4

    #if DEBUG
    /// Test seam: an export runs.
    var isRunning: Bool { task != nil }
    #endif

    /// What the status line says when an export ends with no PDF drawn: `ListPDF.data` gave none (no PDF context).
    nonisolated static let notMade = "The PDF could not be made."
    /// What the status line says when the list was left before the save panel of its made PDF opened.
    nonisolated static let leftTheList = "The PDF was not saved: you left the list."

    /// The status line's sentence when an export's drawing ended: "The PDF could not be made." when no PDF was drawn;
    /// nothing when one was, or when the export was cancelled (it changes nothing more, and says nothing).
    nonisolated static func endNotice(drawn: Data?, cancelled: Bool) -> String? {
        drawn == nil && !cancelled ? notMade : nil
    }

    /// `-exportPDF` writes once the screen's list is read (`listRead`) by a join made on a settled catalog
    /// (`catalogSettled`) that had the game's prices (`priceDay`): then the PDF has the pictures and prices a person sees.
    /// Offline no price step ever runs, so the PDF does not wait for a price day (without one its prices are "—").
    nonisolated static func launchReady(listRead: Bool, joined: CollectionJoin?, offline: Bool = false) -> Bool {
        guard listRead, let joined else { return false }
        return joined.catalogSettled && (offline || joined.priceDay != nil)
    }

    /// What the status line says when the save panel ends: nothing after a save or a cancel; else "The PDF could not be
    /// saved: <why>".
    nonisolated static func saveNotice(_ result: Result<URL, any Error>) -> String? {
        guard case .failure(let error) = result else { return nil }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError { return nil }
        return "The PDF could not be saved: \(error.localizedDescription)"
    }

    /// Starts an export of `job` and returns its task, or nil while another export runs. Its PDF is written to `file` when
    /// one is given (`-exportPDF`), else kept in `made` for the save panel. No PDF drawn is said through `notice`
    /// (`endNotice`). After `cancel()` the task changes nothing and says nothing.
    @discardableResult
    func start(_ job: PDFJob, pictures: PictureStore, writingTo file: URL? = nil,
               notice: @escaping @MainActor (String) -> Void = { _ in }) -> Task<Void, Never>? {
        guard task == nil else { return nil }
        made = nil
        progress = PDFProgress(done: 0, total: job.items.count)
        let task = Task {
            let data = await make(job, pictures: pictures)
            if let text = Self.endNotice(drawn: data, cancelled: Task.isCancelled) { notice(text) }
            guard !Task.isCancelled else { return }
            self.task = nil
            guard let data else { return }
            if let file {
                await Self.write(data, to: file)
            } else {
                made = PDFMade(data: data, fileName: job.fileName)
            }
        }
        self.task = task
        return task
    }

    /// Stops the running export: no picture is asked for after this, and nothing is written or kept (a made PDF not yet
    /// saved is dropped too). A download already running ends on its own (`PictureStore` keeps its picture).
    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        made = nil
    }

    /// The list's stack went away (another screen, another game, the window closing): `cancel()`. Returns "The PDF was
    /// not saved: you left the list." when that dropped a made PDF whose save panel had not opened yet (it waited for
    /// Back from a card page); nil otherwise (a running export, as a click on "Making PDF…", says nothing).
    func leave() -> String? {
        let dropped = made != nil
        cancel()
        return dropped ? Self.leftTheList : nil
    }

    /// Collects the pictures of `job` and draws its PDF; nil when the task was cancelled or no PDF could be drawn. Every
    /// change of `progress` is made only while the task is not cancelled, so a cancelled export never shows again.
    func make(_ job: PDFJob, pictures: PictureStore) async -> Data? {
        let total = job.items.count
        // The items of each address: two finishes of one printing share their picture, which is asked for once.
        var itemsOf: [URL: Int] = [:]
        var addresses: [URL] = []
        for url in job.items.compactMap(\.picture) {
            if itemsOf[url] == nil { addresses.append(url) }
            itemsOf[url, default: 0] += 1
        }
        var done = total - itemsOf.values.reduce(0, +)
        if !Task.isCancelled { progress = PDFProgress(done: done, total: total) }
        var found: [URL: Data] = [:]
        await withTaskGroup(of: (URL, Data?).self) { group in
            var waiting = addresses.makeIterator()
            for _ in 0..<Self.picturesAtOnce {
                guard let url = waiting.next() else { break }
                group.addTask { (url, await pictures.data(for: url)) }
            }
            for await (url, data) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                found[url] = data
                done += itemsOf[url] ?? 0
                progress = PDFProgress(done: done, total: total)
                if let next = waiting.next() {
                    group.addTask { (next, await pictures.data(for: next)) }
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        let items = job.items.map { PDFItem(name: $0.name, count: $0.count, price: $0.price, picture: $0.picture.flatMap { found[$0] }) }
        let data = await Self.draw(title: job.title, items: items)
        guard !Task.isCancelled else { return nil }
        progress = nil
        return data
    }

    /// Off the main thread: 500 cells take a moment.
    @concurrent private nonisolated static func draw(title: String, items: [PDFItem]) async -> Data? {
        ListPDF.data(title: title, items: items)
    }

    /// `-exportPDF`: the file, written at once (no partial file). A Debug run says where in one line.
    @concurrent private nonisolated static func write(_ data: Data, to file: URL) async {
        do {
            try data.write(to: file, options: .atomic)
            #if DEBUG
            FileHandle.standardOutput.write(Data("pdf written: \(file.path), \(data.count) bytes\n".utf8))
            #endif
        } catch {
            #if DEBUG
            FileHandle.standardOutput.write(Data("pdf not written: \(file.path): \(error.localizedDescription)\n".utf8))
            #endif
        }
    }
}

/// The made PDF as the save panel's document (`fileExporter`). Never opened by the app.
nonisolated struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
