import SwiftUI

/// The choices of the sheet "Sharing decisions" (E7, A22). Pure: the rows are the pending cards when the sheet opened, by
/// name; no row has a choice at first (the app never answers for the user); Done writes `answers`, the rows with a
/// choice only, in one library change. A row left without a choice stays pending.
nonisolated struct SharingChoices: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let need: CardNeed
        /// True: "Share"; false: "Buy more"; nil: no choice yet.
        var choice: Bool?
        var id: String { need.cardKey }
    }

    private(set) var rows: [Row]

    /// The pending cards of `needs`, by name (then card key).
    init(needs: [CardNeed]) {
        rows = needs.filter(\.pending)
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.cardKey < b.cardKey : order == .orderedAscending
            }
            .map { Row(need: $0, choice: nil) }
    }

    /// One row's choice; a key that is no row changes nothing.
    mutating func choose(cardKey: String, shared: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == cardKey }) else { return }
        rows[i].choice = shared
    }

    /// "Share all" (true) / "Buy all" (false): every row.
    mutating func chooseAll(_ shared: Bool) {
        for i in rows.indices { rows[i].choice = shared }
    }

    /// What Done writes (`UserLibrary.setShared`): the rows with a choice.
    var answers: [String: Bool?] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.choice.map { (row.id, Optional($0)) } })
    }

    /// Done is off until a choice is made.
    var canFinish: Bool { rows.contains { $0.choice != nil } }

    /// The line under a row's name: each user deck with its copies, then the owned count: "Wind 3 · Cheap 2 · you own 3".
    static func rowText(_ need: CardNeed) -> String {
        (need.users.map { "\($0.deckName) \($0.use)" } + ["you own \(need.owned)"]).joined(separator: " · ")
    }
}

/// The sheet "Sharing decisions" (E7, "The look of the new parts"): the import sheet's table look. Per pending card its
/// name, under it in 12 pt `muted` its users and the owned count, right a segmented picker "Share" / "Buy more" with no
/// choice at first; above the table "Share all" and "Buy all" as text buttons; "Cancel" (writes nothing) and the default
/// button "Done" (off until a choice is made; writes the chosen rows in one change). Every control is off while the game
/// cannot change. The rows are the pending cards when the sheet opened: a card that stops being pending meanwhile keeps
/// its row, and a late choice only writes its answer (Review Focus 1).
struct SharingSheet: View {
    @Environment(AppModel.self) private var model
    let gameID: String
    @State private var choices: SharingChoices

    init(gameID: String, needs: [CardNeed]) {
        self.gameID = gameID
        _choices = State(initialValue: SharingChoices(needs: needs))
    }

    var body: some View {
        let canChange = model.library.canChange(game: gameID)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.lineGap) {
                Text("Sharing decisions")
                    .font(Theme.sheetTitleFont)
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("sharing-title")
                HStack(spacing: 16) {
                    Button("Share all") { choices.chooseAll(true) }
                        .accessibilityIdentifier("sharing-share-all")
                    Button("Buy all") { choices.chooseAll(false) }
                        .accessibilityIdentifier("sharing-buy-all")
                }
                .buttonStyle(.plain)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.text)
                .padding(.top, Theme.lineGap)
                .disabled(!canChange || choices.rows.isEmpty)
            }
            .padding([.horizontal, .top], Theme.sheetPadding)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    RuleLine()
                    LazyVStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
                        ForEach(choices.rows) { row($0, canChange: canChange) }
                    }
                }
                .padding(.horizontal, Theme.sheetPadding)
                .padding(.bottom, Theme.ruleSpacing)
            }
            HStack {
                Button("Cancel") { model.showsSharing = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("sharing-cancel")
                Spacer()
                Button("Done") {
                    // B2: nothing while the game is not followed or its player role is off.
                    if model.decksWritable(game: gameID) { model.library.setShared(choices.answers, game: gameID) }
                    model.showsSharing = false
                }
                .sheetDefaultButton()
                .disabled(!canChange || !choices.canFinish)
                .accessibilityIdentifier("sharing-done")
            }
            .padding(Theme.sheetPadding)
            .background(alignment: .top) { Theme.rule.frame(height: 1) }
        }
        #if os(macOS)
        .frame(minWidth: Theme.importSheetMinWidth, idealWidth: Theme.importSheetIdealWidth,
               minHeight: Theme.sharingSheetMinHeight, idealHeight: Theme.sharingSheetIdealHeight)
        #endif
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharing-sheet")
    }

    /// The card's name and under it its users and owned count; the picker right, keeping its width.
    private func row(_ row: SharingChoices.Row, canChange: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.need.name)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(SharingChoices.rowText(row.need))
                    .font(Theme.lineFont)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Sharing of \(row.need.name)", selection: Binding(
                get: { row.choice },
                set: { if let shared = $0 { choices.choose(cardKey: row.id, shared: shared) } })) {
                Text("Share").tag(Bool?.some(true))
                Text("Buy more").tag(Bool?.some(false))
            }
            .pickerStyle(.segmented)
            // Not the accent (the sidebar row and the default button only): the chosen segment is a grey fill, `faint`
            // (white on it reads at 3:1; on `muted` at 2:1).
            .tint(Theme.faint)
            .labelsHidden()
            .fixedSize()
            .disabled(!canChange)
            .accessibilityIdentifier("sharing-choice-\(row.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharing-row-\(row.id)")
    }
}
