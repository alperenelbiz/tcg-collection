import SwiftUI

/// What the Sets list's rows are made from (F7): while none of it changes, the rows are still right. The index version
/// (`AppModel.setIndexVersions`) changes when this run stores a new index of the game, which can come seconds after the
/// catalog step that asked for it, so the rows are made again then.
nonisolated struct SetsKey: Equatable, Sendable {
    let game: String
    let libraryVersion: Int
    let priceDay: String?
    let catalogVersion: Int
    let setIndexVersion: Int

    /// What the rows of `game` are made from now.
    @MainActor static func of(game: String, model: AppModel) -> SetsKey {
        SetsKey(game: game, libraryVersion: model.library.version, priceDay: model.prices.day(game: game),
                catalogVersion: model.catalogVersion, setIndexVersion: model.setIndexVersions[game] ?? 0)
    }
}

/// The navigation value of a set's page, pushed on the Sets list's stack.
nonisolated struct SetPageTarget: Hashable, Sendable {
    let groupID: Int
}

/// What the Sets list shows for one game: the scope (A27), the sort, the search text, the open pages, and the rows with
/// the key they were made for. The window keeps it (`SetsMemory`), so a visit to another screen loses none of it.
@Observable
final class SetsScreenState: GameScreenState {
    let gameID: String
    /// The scope asked for; the list shows `SetMaths.scope(scope, rows:)` (all sets while nothing is owned).
    var scope: SetScope = .mine
    var sort: SetSort = .newest
    var text = ""
    var path = NavigationPath()
    /// The set at the top of the list.
    var scrolledTo: Int?
    /// The rows made last, for `rowsKey`. Nil until rows of this game were made once.
    private(set) var rows: [SetRow]?
    private(set) var rowsKey: SetsKey?
    /// The latest making of the rows threw (the catalog's sets could not be read): `rows` stays as it was, and the next
    /// appearance of the screen tries again.
    private(set) var failed = false
    /// One page state per set opened (its filter, text and products), kept with the list, so Back from a card page and a
    /// sidebar switch lose none of it. Not observed: a page asks for its state while its view is made.
    @ObservationIgnored private var pages: [Int: SetPageState] = [:]

    init(gameID: String) {
        self.gameID = gameID
    }

    /// The state of the set's page, made the first time the set is opened.
    func page(_ groupID: Int) -> SetPageState {
        if let page = pages[groupID] { return page }
        let page = SetPageState(gameID: gameID, groupID: groupID)
        pages[groupID] = page
        return page
    }

    /// True when the search text has a word to match (punctuation alone is no search).
    var searching: Bool { !CardName.searchKey(text).isEmpty }

    /// True when the rows are not made for `key` yet, or their last making failed.
    func needsRows(for key: SetsKey) -> Bool { key != rowsKey || failed }

    /// The key of the latest making started: an older making that ends after it stores nothing.
    @ObservationIgnored private var latestKey: SetsKey?

    /// What the list's phase is told (`ListPhase.of(listing:)`): nil while no making has ended (loading); false for no
    /// row, also after a first failed read (final fix A4: the note says why, no loading blocks); true with rows.
    var listing: Bool? {
        if let rows { return !rows.isEmpty }
        return failed ? false : nil
    }

    /// Makes the rows once per key, once the folder is read (`loaded`). A making that throws keeps the last rows and
    /// marks the state failed; a cancelled one (the screen gone) and one overtaken by a newer key's making store nothing.
    func run(_ key: SetsKey, loaded: Bool, make: () async throws -> [SetRow]) async {
        guard loaded, needsRows(for: key) else { return }
        latestKey = key
        let made: [SetRow]
        do {
            made = try await make()
        } catch {
            guard !Task.isCancelled, latestKey == key else { return }
            failed = true
            rowsKey = key
            return
        }
        guard !Task.isCancelled, latestKey == key else { return }
        failed = false
        rowsKey = key
        if rows != made { rows = made }
    }

    /// F7: the rows of `key`, off the main thread. On the main actor it takes values only: the game's index, its
    /// collection rows and a snapshot of its prices (`PriceTable.table(game:)`, a value that shares its storage, so the
    /// copy costs nothing). The sets come from `reader` (a short read of the set rows); the counting runs in a detached
    /// task. Without an index there is no row (the note says why).
    func makeRows(_ key: SetsKey, model: AppModel) async {
        let index = model.setIndexes[key.game], rows = model.library.rows(game: key.game)
        let prices = model.prices.table(game: key.game), reader = model.reader
        await run(key, loaded: model.library.isLoaded) {
            guard let index else { return [] }
            let sets = try await reader.sets(game: key.game)
            let counting = Task.detached(priority: .userInitiated) {
                Self.rows(sets: sets, index: index, rows: rows, prices: prices)
            }
            return await withTaskCancellationHandler { await counting.value } onCancel: { counting.cancel() }
        }
    }

    /// The rows of the sets in both the index and the store (F5), with the targets' finishes and prices from `prices`
    /// (nil: the game has no price file; every product is then one Normal target without a price).
    nonisolated static func rows(sets: [SetRecord], index: SetIndex, rows: [CollectionRow], prices: GamePrices?) -> [SetRow] {
        SetMaths.rows(sets: sets, index: index, rows: rows, prices: { prices?.prices(productID: $0) ?? [] })
    }

    /// The line above the list (final fix A4, Review Focus 5): why it shows nothing or old numbers, in this priority: the
    /// catalog still downloading; a failed read (with rows: they are the last ones read); the game's index being read or
    /// made (`AppModel.setIndexInWork`): "being read" without an index, "being updated" under the old rows; no sets (no
    /// index and none in work, or rows made and none to list). `rows`: the rows made last, nil until a making ended.
    /// Nil when the list is whole, and while the first rows are made.
    static func note(catalogSettled: Bool, failed: Bool, hasIndex: Bool, indexInWork: Bool, rows: [SetRow]?) -> String? {
        if !catalogSettled { return "The catalog is still downloading. Sets come when it is ready." }
        if failed {
            return rows?.isEmpty == false ? "The catalog could not be read. Showing what was read before." : "The catalog could not be read."
        }
        if indexInWork { return hasIndex ? "Sets are being updated." : "The sets of this game are being read." }
        if !hasIndex || rows?.isEmpty == true { return "The catalog has no sets of this game yet." }
        return nil
    }
}

/// The window's Sets state.
typealias SetsMemory = ScreenMemory<SetsScreenState>

/// The game's sets (A27, F7, F9): a table of one row per set, its name and release month, how many targets of its master
/// set are owned (`187 / 412`) and what the missing ones cost. The toolbar has "My sets" / "All sets", Sort and one search
/// field (name or abbreviation). A click opens the set's page in this screen's own navigation stack.
struct SetsView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: SetsScreenState

    var body: some View {
        let game = state.gameID, library = model.library
        let rows = state.rows ?? []
        let scope = SetMaths.scope(state.scope, rows: rows)
        // One sort per render (A10): the subtitle's count of the scope's rows needs none.
        let shown = SetMaths.shown(rows, scope: scope, text: state.searching ? state.text : "", sort: state.sort)
        let all = state.searching ? SetMaths.count(rows, scope: scope) : shown.count
        // A refused file or a missing folder: no owned count is known, the problem line says why.
        let phase = ListPhase.of(listing: library.canChange(game: game) ? state.listing : nil, game: game, library: library)
        let note = SetsScreenState.note(catalogSettled: model.catalogSettled(game: game), failed: state.failed,
                                        hasIndex: model.setIndexes[game] != nil, indexInWork: model.setIndexInWork(game),
                                        rows: state.rows)
        let key = SetsKey.of(game: game, model: model)
        content(phase, shown: shown)
            .safeAreaInset(edge: .top, spacing: 0) {
                CatalogNote(text: phase == .unavailable ? nil : note, identifier: "sets-note")
            }
            .listScreen("sets", note: nil)
            .navigationDestination(for: SetPageTarget.self) { target in
                SetPageView(state: state.page(target.groupID), name: rows.first { $0.id == target.groupID }?.set.name ?? "")
                    .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
            }
            .navigationTitle("Sets")
            .navigationSubtitle(phase == .list ? SetMaths.subtitle(shown: shown.count, of: all, searching: state.searching) : "")
            .searchable(text: $state.text)
            .toolbar {
                ToolbarItemGroup {
                    Picker("Sets", selection: Binding(get: { scope }, set: { state.scope = $0 })) {
                        Text("My sets").tag(SetScope.mine)
                        Text("All sets").tag(SetScope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Not the accent (the sidebar row and a sheet's default button only), as the sharing sheet's choice.
                    .tint(Theme.faint)
                    .fixedSize()
                    .accessibilityIdentifier("sets-scope")
                    SetSortMenu(sort: $state.sort)
                }
            }
            .task(id: key) { await state.makeRows(key, model: model) }
    }

    @ViewBuilder private func content(_ phase: ListPhase, shown: [SetRow]) -> some View {
        switch phase {
        case .loading:
            LoadingSetRows()
        case .unavailable, .empty:
            // No set to list: the note says why (still downloading, a failed read, being read, no sets), or the problem line.
            Color.clear
        case .list:
            if shown.isEmpty {
                // The identifier goes on the sentence: `listScreen`'s container takes a container's identifier.
                EmptyMessage(sentence: "No set matches \"\(state.text)\".", identifier: "empty-state") { EmptyView() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
                        ForEach(shown) { row in SetListRow(row: row) }
                    }
                    .scrollTargetLayout()
                    .padding(Theme.margin)
                }
                .scrollPosition(id: $state.scrolledTo, anchor: .top)
            }
        }
    }
}

/// One set of the list: its name (13 pt, truncates) and under it its release month (12 pt `muted`, nothing when
/// unknown); right-aligned in fixed columns, so the numbers of every row stand in one column: `187 / 412` (13 pt,
/// tabular; `text` only for a complete set, else `muted`), then the price of the missing targets (12 pt `muted`,
/// nothing for a complete set). Hover puts `surface` behind the row; a click opens the set.
private struct SetListRow: View {
    let row: SetRow
    @State private var hovering = false

    /// The hover background reaches this far past the row's texts.
    private static let hoverPadding: CGFloat = 6

    var body: some View {
        let numbers = row.numbers, id = row.id
        let cost = SetMaths.costText(numbers), date = SetMaths.releaseText(row.set.publishedOn)
        HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.set.name)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !date.isEmpty {
                    Text(date)
                        .font(Theme.lineFont)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .accessibilityIdentifier("sets-date-\(id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SetMaths.countText(numbers))
                .font(Theme.bodyFont)
                .monospacedDigit()
                .foregroundStyle(numbers.isComplete ? Theme.text : Theme.muted)
                .lineLimit(1)
                .frame(width: Theme.setCountWidth, alignment: .trailing)
                .accessibilityIdentifier("sets-count-\(id)")
            Group {
                if let cost {
                    Text(cost)
                        .font(Theme.lineFont)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .accessibilityIdentifier("sets-cost-\(id)")
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Theme.setCostWidth, alignment: .trailing)
        }
        .padding(Self.hoverPadding)
        .background { if hovering { RoundedRectangle(cornerRadius: Theme.pictureRadius).fill(Theme.surface) } }
        // The link lies over the texts, so the texts keep their own identifiers for the tests.
        .overlay {
            NavigationLink(value: SetPageTarget(groupID: id)) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([row.set.name, "\(numbers.owned) of \(numbers.total)", cost].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("sets-row-\(id)")
        }
        .onHover { hovering = $0 }
        .padding(.horizontal, -Self.hoverPadding)
    }
}

/// The Sets list while the folder is read or its first rows are made: the rows' layout with flat `surface` blocks. No
/// shimmer.
private struct LoadingSetRows: View {
    private static let placeholders = 12

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
                ForEach(0..<Self.placeholders, id: \.self) { _ in
                    HStack(spacing: Theme.columnGap) {
                        VStack(alignment: .leading, spacing: 4) {
                            block(width: 220, height: 13)
                            block(width: 96, height: 11)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        block(width: 64, height: 13)
                            .frame(width: Theme.setCountWidth, alignment: .trailing)
                        block(width: 72, height: 11)
                            .frame(width: Theme.setCostWidth, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(Theme.margin)
        }
        .accessibilityHidden(true)
    }

    private func block(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: width, height: height)
    }
}

/// The Sets list's Sort menu: Newest (the default), Name, Most complete, Cost to complete.
private struct SetSortMenu: View {
    @Binding var sort: SetSort

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Newest").tag(SetSort.newest)
                Text("Name").tag(SetSort.name)
                Text("Most complete").tag(SetSort.complete)
                Text("Cost to complete").tag(SetSort.cost)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Sort")
        }
        .accessibilityIdentifier("sets-sort")
    }
}
