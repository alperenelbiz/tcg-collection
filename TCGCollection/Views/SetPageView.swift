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

/// The cells, numbers and texts of a set's page, pure.
nonisolated enum SetPage {
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
        if products != value { products = value }
    }

    /// The set's products from the index, in one batched read through `reader` (off the main thread).
    func read(_ key: SetPageKey, model: AppModel) async {
        let ids = model.setIndexes[key.game]?.products(of: key.groupID) ?? [], reader = model.reader
        await run(key) { ids.isEmpty ? [:] : try await reader.products(ids: ids, game: key.game) }
    }
}

/// A set's page (A26, F8): the subtitle `187 of 412 · $1,240.50 to complete`, a gallery of its targets in card-number
/// order where a target the user lacks is faded, each with its owned count control. The toolbar has All / Missing /
/// Owned and one search field (the product's name). A click on a cell's picture or name opens the card page on that
/// printing in Sets' stack.
struct SetPageView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: SetPageState
    /// The set's name (the title).
    let name: String

    var body: some View {
        let game = state.gameID, library = model.library
        let ids = model.setIndexes[game]?.products(of: state.groupID) ?? []
        let read = state.products ?? [:]
        // The rows are live: a count change shows at once. Only the products are read once per key.
        let owned = SetOwned(rows: library.rows(game: game))
        let prices = model.prices
        let priced = { (id: Int) in prices.prices(game: game, productID: id).map(\.finish) }
        let cells = SetPage.cells(products: ids, read: read, owned: owned, priced: priced)
        let numbers = SetPage.numbers(products: ids, read: read, owned: owned, priced: priced,
                                      price: { prices.shown(game: game, key: $0) })
        let shown = SetPage.shown(cells, filter: state.filter, text: state.text, owned: owned)
        // As the Collection: listed while the rows are known (a refused file has none: unavailable, the problem line says
        // why); the controls are off while the game cannot change.
        let canChange = library.canChange(game: game)
        let rowsKnown = canChange || !library.rows(game: game).isEmpty
        let phase = ListPhase.of(listing: rowsKnown ? state.products.map { _ in !cells.isEmpty } : nil,
                                 game: game, library: library)
        let note = SetPage.note(catalogSettled: model.catalogSettled(game: game), failed: state.failed,
                                hasProducts: state.products != nil)
        let key = SetPageKey.of(game: game, groupID: state.groupID, model: model)
        content(phase, shown: shown, owned: owned, canChange: canChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                CatalogNote(text: phase == .unavailable ? nil : note, identifier: "set-note")
            }
            .background { Theme.ground.ignoresSafeArea() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("set-screen")
            .navigationTitle(name)
            .navigationSubtitle(phase == .list ? SetMaths.pageSubtitle(numbers) : "")
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

    @ViewBuilder private func content(_ phase: ListPhase, shown: [SetCell], owned: SetOwned, canChange: Bool) -> some View {
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
                            self.cell(cell, count: owned.count(cell.key), canChange: canChange)
                        }
                    }
                }
            }
        }
    }

    /// F8: the cell (faded while missing), 8 pt, then its owned count control, which is never faded.
    private func cell(_ cell: SetCell, count: Int, canChange: Bool) -> some View {
        let product = cell.product, suffix = "\(product.productID)-\(cell.finish)"
        let price = model.prices.shown(game: state.gameID, key: cell.key)
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
                step(by: $0 - count, cell: cell)
            }
            .disabled(!canChange)
        }
    }

    /// The card page's rule: the step goes onto the library's current count, so two clicks before the next render both
    /// count; a row that reaches 0 is removed. A new row saves the product's name.
    private func step(by delta: Int, cell: SetCell) {
        let library = model.library, game = state.gameID
        library.setCount(library.count(game: game, key: cell.key) + delta, game: game, key: cell.key, name: cell.product.name)
    }
}
