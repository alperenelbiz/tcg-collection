import SwiftUI

/// The comparison of a CSV import, shown before anything changes (spec 5.2): per game of the file, the new printings, the
/// count changes, and the printings of the collection that the file does not have (each kept unless set to Remove); then
/// the lines that are not imported. Only Import writes; Cancel and Close write nothing.
/// - A game that cannot be imported says why under its name (`ImportModel.block`); its rows cannot be chosen.
/// - The comparison is made again when a catalog step ends (the catalog may now know the file's products) and when the
///   collection changes while the sheet is open.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    let importModel: ImportModel
    /// "Not imported" is collapsed until clicked.
    @State private var showsSkipped = false
    /// Goes up when `importModel.needsPrepare` turns true; each value runs one `prepare` (the first at once).
    @State private var prepareRound = 0

    /// What the body shows under the title.
    private enum Layout: Equatable {
        /// One sentence (reading, a failed read, no game in the file, a file that matches): in the middle, or above the
        /// "Not imported" lines when there are some.
        case sentence(String)
        case comparison
    }

    var body: some View {
        let layout = layout
        VStack(alignment: .leading, spacing: 0) {
            header(layout)
            switch layout {
            case .sentence(let text) where importModel.state != .ready || importModel.notImported.isEmpty:
                EmptyMessage(sentence: text)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("import-sentence")
            case .sentence(let text):
                list {
                    Text(text)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, Theme.ruleSpacing)
                        .accessibilityIdentifier("import-sentence")
                }
            case .comparison:
                list {
                    ForEach(importModel.comparisons, id: \.gameID) { section($0) }
                }
            }
            buttons
        }
        #if os(macOS)
        .frame(minWidth: Theme.importSheetMinWidth, idealWidth: Theme.importSheetIdealWidth,
               minHeight: Theme.importSheetMinHeight, idealHeight: Theme.importSheetIdealHeight)
        #endif
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-sheet")
        // Again when `needsPrepare` turns true: a game compared during its download is settled now, or the collection holds
        // a product the last lookup did not read. A first comparison on a settled catalog needs no second `prepare`.
        .task(id: prepareRound) { await importModel.prepare() }
        .onChange(of: importModel.needsPrepare) { _, due in
            if due { prepareRound += 1 }
        }
        // The collection changed: compared again at once from the lines and products already read (or a full `prepare`).
        .onChange(of: model.library.version) { importModel.refreshComparison() }
    }

    /// The scrolling part: `content`, then "Not imported".
    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
                notImported
            }
            .padding(.horizontal, Theme.sheetPadding)
            .padding(.bottom, Theme.ruleSpacing)
        }
    }

    private var layout: Layout {
        switch importModel.state {
        case .reading: return .sentence("Reading the file…")
        case .failed(let text): return .sentence(text)
        case .ready:
            if importModel.comparisons.isEmpty { return .sentence(ImportModel.noGame) }
            // Only when no group has a row: kept rows alone are shown, with "Nothing to import: …" as the summary.
            let nothingBlocked = importModel.comparisons.allSatisfy { importModel.block(game: $0.gameID) == nil }
            if nothingBlocked, importModel.summary == ImportModel.matches { return .sentence(ImportModel.matches) }
            return .comparison
        }
    }

    private func header(_ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: Theme.lineGap) {
            Text("Import \(importModel.fileName)")
                .font(Theme.sheetTitleFont)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("import-title")
            if layout == .comparison {
                Text(importModel.summary)
                    .font(Theme.lineFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("import-summary")
            }
            if let notice = importModel.notice {
                Text(notice)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .padding(.top, Theme.lineGap)
                    .accessibilityIdentifier("import-notice")
            }
        }
        .padding([.horizontal, .top], Theme.sheetPadding)
    }

    // MARK: A game

    @ViewBuilder private func section(_ comparison: ImportComparison) -> some View {
        let game = comparison.gameID
        let block = importModel.block(game: game)
        VStack(alignment: .leading, spacing: 0) {
            Text(Games.game(game)?.name ?? game)
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.text)
                .padding(.top, Theme.ruleSpacing)
                .accessibilityIdentifier("import-game-\(game)")
            if let block {
                Text(block.text)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, Theme.lineGap)
                    .accessibilityIdentifier("import-blocked-\(game)")
            }
            // A catalog that is not ready would make every line "not in the catalog": no groups then.
            if block?.hidesComparison == true {
                EmptyView()
            } else if comparison.new.isEmpty, comparison.changed.isEmpty, comparison.missing.isEmpty {
                Text("Nothing changes in this game.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, Theme.lineGap)
            } else {
                groups(comparison, locked: block != nil)
            }
        }
    }

    @ViewBuilder private func groups(_ comparison: ImportComparison, locked: Bool) -> some View {
        let game = comparison.gameID
        if !comparison.new.isEmpty {
            group("New", count: comparison.new.count, id: "import-new-\(game)") {
                rows(comparison.new) { change in Cell(text: "+\(change.new)") }
            }
        }
        if !comparison.changed.isEmpty {
            group("Count changes", count: comparison.changed.count, id: "import-changed-\(game)") {
                rows(comparison.changed) { change in Cell(text: "\(change.old) → \(change.new)") }
            }
        }
        if !comparison.missing.isEmpty {
            let all = importModel.allMissingRemoved(game: game)
            group("In your collection, not in this file", count: comparison.missing.count, id: "import-missing-\(game)") {
                rows(comparison.missing) { change in
                    // Red only on a row set to Remove: the count the import takes away.
                    Cell(text: "×\(change.old)", risk: importModel.remove.contains(change.key), choice: removeToggle(change.key, locked: locked))
                }
            } control: {
                Button(all ? "Keep all" : "Remove all") { importModel.setAllMissing(remove: !all, game: game) }
                    .controlSize(.small)
                    .disabled(locked)
                    .accessibilityIdentifier("import-missing-all-\(game)")
            }
        }
    }

    private func removeToggle(_ key: PrintingKey, locked: Bool) -> AnyView {
        AnyView(
            Toggle("Remove", isOn: Binding(
                get: { importModel.remove.contains(key) },
                set: { on in if on { importModel.remove.insert(key) } else { importModel.remove.remove(key) } }))
            #if os(macOS)
                .toggleStyle(.checkbox)
            #endif
                // Not the accent (it is for the sidebar and the default button only) and not red (the count is the row's
                // one red mark): the check itself says "Remove".
                .tint(Theme.raised)
                .font(Theme.bodyFont)
                .disabled(locked)
                .accessibilityIdentifier("import-remove-\(key.productID)-\(key.finish)")
        )
    }

    /// A rule above, the title with its count, an optional control on the right, then the rows.
    private func group<Rows: View, Control: View>(_ title: String, count: Int, id: String, @ViewBuilder rows: () -> Rows,
                                                  @ViewBuilder control: () -> Control = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RuleLine()
            HStack(alignment: .center) {
                Text("\(title) · \(count)")
                    .font(Theme.labelFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier(id)
                Spacer()
                control()
            }
            .padding(.bottom, Theme.tableRowSpacing)
            LazyVStack(alignment: .leading, spacing: Theme.tableRowSpacing) { rows() }
        }
    }

    /// One table row per change: name (and the set's name where two rows would read the same), finish, the number
    /// right-aligned in tabular digits, and the choice column while a group of the sheet offers Remove
    /// (`ImportModel.offersRemove`; every row has it then, so the numbers stay in one column). The name takes the rest of
    /// the width and wraps to two lines at most; the other columns keep their widths and sit on the name's first line.
    private func rows(_ changes: [ImportComparison.Change], cell: @escaping (ImportComparison.Change) -> Cell) -> some View {
        let ambiguous = ImportModel.ambiguous(changes)
        let choiceColumn = importModel.offersRemove
        return ForEach(changes) { change in
            let cell = cell(change)
            let id = "\(change.key.productID)-\(change.key.finish)"
            HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(change.name)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .layoutPriority(1)
                    if ambiguous.contains(change.key) {
                        Text(importModel.setName(of: change.key) ?? "Product \(change.key.productID)")
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(change.key.finish)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .frame(width: Theme.tableFinishWidth, alignment: .leading)
                Text(cell.text)
                    .monospacedDigit()
                    .foregroundStyle(cell.risk ? Theme.risk : Theme.text)
                    .frame(width: Theme.tableNumberWidth, alignment: .trailing)
                    .accessibilityIdentifier("import-count-\(id)")
                if choiceColumn {
                    (cell.choice ?? AnyView(Color.clear.frame(height: 1)))
                        .frame(width: Theme.tableChoiceWidth, alignment: .leading)
                }
            }
            .font(Theme.bodyFont)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import-row-\(id)")
        }
    }

    /// The number column of a row, its colour, and the choice column (only "In your collection, not in this file").
    private struct Cell {
        var text: String
        var risk = false
        var choice: AnyView?
    }

    // MARK: Not imported

    /// Every skipped and not-recognised line with its line number and reason; collapsed until clicked.
    @ViewBuilder private var notImported: some View {
        let lines = importModel.notImported
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                RuleLine()
                Button { showsSkipped.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showsSkipped ? 90 : 0))
                        Text("Not imported · \(lines.count)")
                            .monospacedDigit()
                    }
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("import-skipped")
                .accessibilityValue(showsSkipped ? "expanded" : "collapsed")
                if showsSkipped {
                    LazyVStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
                                Text("Line \(line.line)")
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: Theme.tableNumberWidth, alignment: .trailing)
                                Text(line.name.isEmpty ? "—" : line.name)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(line.reason)
                                    .foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(Theme.bodyFont)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("import-skipped-line-\(line.line)")
                        }
                    }
                    .padding(.top, Theme.tableRowSpacing)
                }
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            // Import is offered (off) while a `prepare` runs, and (on) when it would write; rows that are only kept write
            // nothing, so then only Close is offered until a row is set to Remove.
            if importModel.state == .reading || importModel.isPreparing || importModel.writes {
                Button("Cancel") { model.importing = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("import-cancel")
                Spacer()
                Button("Import") {
                    // The sheet closes at once; the status line speaks when the writes have run.
                    if let applied = importModel.apply() { Task { await model.importApplied(applied) } }
                }
                .sheetDefaultButton()
                .disabled(!importModel.canApply)
                .accessibilityIdentifier("import-apply")
            } else {
                Spacer()
                Button("Close") { model.importing = nil }
                    .sheetDefaultButton()
                    .accessibilityIdentifier("import-close")
            }
        }
        .padding(Theme.sheetPadding)
        .background(alignment: .top) { Theme.rule.frame(height: 1) }
    }
}
