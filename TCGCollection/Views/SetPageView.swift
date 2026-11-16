import SwiftUI

/// One cell of a set's page: a target (A26) with the catalog's product of its printing.
nonisolated struct SetCell: Sendable, Equatable, Identifiable {
    let product: ProductRecord
    let finish: String
    var key: PrintingKey { PrintingKey(productID: product.productID, finish: finish) }
    var id: PrintingKey { key }
}

/// What a set page's products are read from: while none of it changes, the read is still right. The index version
/// (`AppModel.setIndexVersions`) changes when a new index of the game is stored, which can name products the last read
/// did not ask for.
nonisolated struct SetPageKey: Equatable, Sendable {
    let game: String
    let groupID: Int
    let catalogVersion: Int
    let setIndexVersion: Int

    /// What the products of the set are read from now.
    @MainActor static func of(game: String, groupID: Int, model: AppModel) -> SetPageKey {
        SetPageKey(game: game, groupID: groupID, catalogVersion: model.catalogVersion,
                   setIndexVersion: model.setIndexVersions[game] ?? 0)
    }
}

/// What a set page's cells are made from (final fix A9): while none of it changes, the cells, the numbers and the owned
/// lookup are still right. `readCount` goes up with every products read that succeeded.
nonisolated struct SetPageCellsKey: Equatable, Sendable {
    let readCount: Int
    let priceDay: String?
    let libraryVersion: Int
}

/// A set page's cells, numbers, owned lookup and prices, made once per `SetPageCellsKey` (A9); the filter and the search
/// run on these cells.
nonisolated struct SetPageContent: Sendable {
    let cells: [SetCell]
    let numbers: SetNumbers
    let owned: SetOwned
    /// The game had a collection row when the content was made (a refused file has none).
    let hasRows: Bool
    /// Each read product's finishes and prices, asked once per product.
    let prices: [Int: [FinishPrice]]

    /// A target's own price: its finish's in its product's prices (`GamePrices.shown`'s rule); nil when there is none.
    func price(_ key: PrintingKey) -> ShownPrice? {
        prices[key.productID]?.first { $0.finish == key.finish }?.price.shown
    }
}

/// The cells, numbers and texts of a set's page, pure.
nonisolated enum SetPage {
    /// A9: the page's content from the index's products, the read, the game's collection rows (read once per making) and
    /// the price lookup, asked once per product the read has.
    static func content(products: [Int], read: [Int: ProductRecord], rows: [CollectionRow],
                        prices lookup: (Int) -> [FinishPrice]) -> SetPageContent {
        let owned = SetOwned(rows: rows)
        var prices: [Int: [FinishPrice]] = [:]
        for id in products where read[id] != nil && prices[id] == nil { prices[id] = lookup(id) }
        let priced = { (id: Int) in (prices[id] ?? []).map(\.finish) }
        let cells = Self.cells(products: products, read: read, owned: owned, priced: priced)
        let numbers = SetMaths.numbers(products: products.filter { read[$0] != nil }, prices: { prices[$0] ?? [] },
                                       ownedCount: owned.count, ownedFinishes: owned.finishes(of:))
        return SetPageContent(cells: cells, numbers: numbers, owned: owned, hasRows: !rows.isEmpty, prices: prices)
    }

    /// A6: the toolbar's subtitle, `187 of 412`, only while the page has a cell; nothing beside the sentence of a page
    /// without one (no "0 of 0").
    @MainActor static func subtitle(_ phase: ListPhase, numbers: SetNumbers) -> String {
        phase == .list ? SetMaths.pageCount(numbers) : ""
    }

    /// The page's targets: the index's products in card-number order (F4), each printing's finishes side by side in the
    /// finishes' order (F1: the priced ones, `Normal` when none, then every owned finish they lack). A product id the read
    /// lacks is skipped (F5).
    static func cells(products: [Int], read: [Int: ProductRecord], owned: SetOwned,
                      priced: (Int) -> [String]) -> [SetCell] {
        products.flatMap { id -> [SetCell] in
            guard let product = read[id] else { return [] }
            return SetMaths.targets(productID: id, priced: priced(id), owned: owned.finishes(of: id))
                .map { SetCell(product: product, finish: $0.finish) }
        }
    }

    /// The numbers of the page's targets (the subtitle): the set's products the read has (F5), counted as the list counts.
    static func numbers(products: [Int], read: [Int: ProductRecord], owned: SetOwned, priced: (Int) -> [String],
                        price: (PrintingKey) -> ShownPrice?) -> SetNumbers {
        SetMaths.numbers(products: products.filter { read[$0] != nil }, priced: priced, ownedCount: owned.count,
                         ownedFinishes: owned.finishes(of:), price: price)
    }

    /// The cells of the filter whose product name holds every folded word of `text`.
    static func shown(_ cells: [SetCell], filter: SetFilter, text: String, owned: SetOwned) -> [SetCell] {
        let words = CardName.searchKey(text).split(separator: " ")
        let kept = SetMaths.filtered(cells.map { SetTarget(productID: $0.product.productID, finish: $0.finish) },
                                     filter: filter, ownedCount: owned.count)
        let keys = Set(kept.map(\.key))
        return cells.filter { cell in
            guard keys.contains(cell.key) else { return false }
            guard !words.isEmpty else { return true }
            let name = CardName.searchKey(cell.product.name)
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// A missing target (an owned count under 1) is drawn faded.
    static func isFaded(count: Int) -> Bool { count < 1 }

    /// What VoiceOver and the UI tests read: `<product name>, ×n` or `missing`, the finish when it is not Normal, the
    /// price or `no price`.
    static func label(name: String, count: Int, finish: String, price: ShownPrice?) -> String {
        var parts = [name, count >= 1 ? "×\(count)" : "missing"]
        if finish != "Normal" { parts.append(finish) }
        parts.append(price.map { CardFacts.priceText($0) } ?? "no price")
        return parts.joined(separator: ", ")
    }

    /// The sentence of a page with no cell to show: the search text first, then the filter's own sentence.
    static func emptySentence(filter: SetFilter, text: String) -> String {
        if !CardName.searchKey(text).isEmpty { return "No card matches \"\(text)\"." }
        switch filter {
        case .missing: return "This set is complete."
        case .owned: return "No card of this set in your collection yet."
        case .all: return "No card of this set is in the catalog."
        }
    }

    /// The catalog's line above the gallery: a failed read first, then a catalog still downloading; nil when whole.
    static func note(catalogSettled: Bool, failed: Bool, hasProducts: Bool) -> String? {
        if failed {
            return hasProducts ? "The catalog could not be read. Showing what was read before." : "The catalog could not be read."
        }
        if !catalogSettled { return "The catalog is still downloading. Cards come when it is ready." }
        return nil
    }
}

/// What a set's page shows: the filter, the search text, and its products with the key they were read for. The Sets
/// list's state keeps one per set (`SetsScreenState.page`), so Back from a card page and a sidebar switch lose none of it.
@Observable
final class SetPageState {
    let gameID: String
    let groupID: Int
    var filter: SetFilter = .all
    var text = ""
    /// The set's products by id, from the last read that succeeded. Nil until one did.
    private(set) var products: [Int: ProductRecord]?
    private(set) var readKey: SetPageKey?
    /// Goes up with every read that succeeded (`SetPageCellsKey`).
    @ObservationIgnored private(set) var readCount = 0
    /// The content made last and its key (A9). Not observed: it is made while the view's body runs.
    @ObservationIgnored private var cached: (key: SetPageCellsKey, content: SetPageContent)?
    /// The latest read threw: `products` stays as it was, and the next appearance of the page tries again.
    private(set) var failed = false

    init(gameID: String, groupID: Int) {
        self.gameID = gameID
        self.groupID = groupID
    }

    /// True when the search text has a word to match.
    var searching: Bool { !CardName.searchKey(text).isEmpty }

    func needsRead(for key: SetPageKey) -> Bool { key != readKey || failed }

    /// Reads once per key. A read that throws keeps the last products and marks the state failed; a cancelled one stores
    /// nothing.
    func run(_ key: SetPageKey, read: () async throws -> [Int: ProductRecord]) async {
        guard needsRead(for: key) else { return }
        let value: [Int: ProductRecord]
        do {
            value = try await read()
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            readKey = key
            return
        }
        guard !Task.isCancelled else { return }
        failed = false
        readKey = key
        readCount += 1
        if products != value { products = value }
    }

    /// The page's content for `key`, made by `make` only when the key differs from the last one (A9).
    func content(for key: SetPageCellsKey, make: () -> SetPageContent) -> SetPageContent {
        if let cached, cached.key == key { return cached.content }
        let made = make()
        cached = (key, made)
        return made
    }

    /// The set's products from the index, in one batched read through `reader` (off the main thread).
    func read(_ key: SetPageKey, model: AppModel) async {
        let ids = model.setIndexes[key.game]?.products(of: key.groupID) ?? [], reader = model.reader
        await run(key) { ids.isEmpty ? [:] : try await reader.products(ids: ids, game: key.game) }
    }
}

/// A set's page (A26, F8): the subtitle `187 of 412`, the line `$1,240.50 to complete` above a gallery of its targets
/// in card-number order where a target the user lacks is faded, each with its owned count control. The toolbar has All /
/// Missing / Owned and one search field (the product's name). A click on a cell's picture or name opens the card page on that
/// printing in Sets' stack.
struct SetPageView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: SetPageState
    /// The set's name (the title).
    let name: String

    var body: some View {
        let game = state.gameID, library = model.library, prices = model.prices
        // A9: the cells, numbers and owned lookup are made once per (products read, price day, collection version), so a
        // count change still shows at once; the filter and the search run on them.
        let cellsKey = SetPageCellsKey(readCount: state.readCount, priceDay: prices.day(game: game),
                                       libraryVersion: library.version)
        let content = state.content(for: cellsKey) {
            SetPage.content(products: model.setIndexes[game]?.products(of: state.groupID) ?? [], read: state.products ?? [:],
                            rows: library.rows(game: game), prices: { prices.prices(game: game, productID: $0) })
        }
        let numbers = content.numbers
        let shown = SetPage.shown(content.cells, filter: state.filter, text: state.text, owned: content.owned)
        // As the Collection: listed while the rows are known (a refused file has none: unavailable, the problem line says
        // why); the controls are off while the game cannot change.
        let canChange = library.canChange(game: game)
        let rowsKnown = canChange || content.hasRows
        let phase = ListPhase.of(listing: rowsKnown ? state.products.map { _ in !content.cells.isEmpty } : nil,
                                 game: game, library: library)
        let note = SetPage.note(catalogSettled: model.catalogSettled(game: game), failed: state.failed,
                                hasProducts: state.products != nil)
        let key = SetPageKey.of(game: game, groupID: state.groupID, model: model)
        gallery(phase, shown: shown, content: content, canChange: canChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The set's whole cost, whatever the filter or the search text shows (nothing for a complete set). In the
            // content, not the toolbar's subtitle: there it was cut at 900 pt.
            .safeAreaInset(edge: .top, spacing: 0) {
                CatalogNote(text: phase == .list ? SetMaths.pageCost(numbers) : nil, identifier: "set-cost")
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                CatalogNote(text: phase == .unavailable ? nil : note, identifier: "set-note")
            }
            .background { Theme.ground.ignoresSafeArea() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("set-screen")
            .navigationTitle(name)
            .navigationSubtitle(SetPage.subtitle(phase, numbers: numbers))
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    Picker("Show", selection: $state.filter) {
                        Text("All").tag(SetFilter.all)
                        Text("Missing").tag(SetFilter.missing)
                        Text("Owned").tag(SetFilter.owned)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Not the accent, as the Sets list's scope.
                    .tint(Theme.faint)
                    .fixedSize()
                    .accessibilityIdentifier("set-filter")
                }
            }
            .task(id: key) { await state.read(key, model: model) }
    }

    @ViewBuilder private func gallery(_ phase: ListPhase, shown: [SetCell], content: SetPageContent, canChange: Bool) -> some View {
        switch phase {
        case .loading:
            LoadingGallery()
        case .unavailable:
            Color.clear
        case .empty, .list:
            if shown.isEmpty {
                EmptyMessage(sentence: SetPage.emptySentence(filter: state.filter, text: state.text),
                             identifier: "empty-state") { EmptyView() }
            } else {
                ScrollView {
                    GalleryGrid {
                        ForEach(shown) { cell in
                            self.cell(cell, count: content.owned.count(cell.key), price: content.price(cell.key),
                                      canChange: canChange)
                        }
                    }
                }
            }
        }
    }

    /// F8: the cell (faded while missing), 8 pt, then its owned count control, which is never faded.
    private func cell(_ cell: SetCell, count: Int, price: ShownPrice?, canChange: Bool) -> some View {
        let product = cell.product, suffix = "\(product.productID)-\(cell.finish)"
        let content = CellContent(product: product, name: product.name,
                                  left: SetMaths.leftText(count: count, finish: cell.finish), price: price)
        return VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: CardTarget(gameID: state.gameID, cardKey: product.searchKey,
                                             startProductID: product.productID)) {
                CardCell(content: content, faded: SetPage.isFaded(count: count))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SetPage.label(name: product.name, count: count, finish: cell.finish, price: price))
            .accessibilityIdentifier("set-cell-\(suffix)")
            CountControl(count: count, label: "\(product.name), \(cell.finish)", prefix: "set-cell", key: suffix) {
                SetPage.step(by: $0 - count, key: cell.key, name: product.name, game: state.gameID, library: model.library)
            }
            .disabled(!canChange)
        }
    }
}

extension SetPage {
    /// A set cell's count control, the card page's rule: the step goes onto the library's current count, so two clicks
    /// before the next render both count; a row that reaches 0 is removed (its for-sale count follows it down and the
    /// library says so, C8). A new row saves the product's name.
    @MainActor static func step(by delta: Int, key: PrintingKey, name: String, game: String, library: UserLibrary) {
        library.setCount(library.count(game: game, key: key) + delta, game: game, key: key, name: name)
    }
}
