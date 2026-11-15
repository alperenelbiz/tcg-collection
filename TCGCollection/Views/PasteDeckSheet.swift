import SwiftUI

/// A deck pasted as text (D11, A16), shown line by line before anything is saved. Step 1: a text editor and "Read". Step 2:
/// the table: per card line its number, the count, the name and its section, with a note where the paste changes
/// something ("0 copies", "saved as 999", "no section Sideboard in Commander", "no count"); an unknown name shows its text
/// in `muted` and a menu of its nearest names and "Drop this line". "Create deck" / "Add to <deck>" is the only write, and
/// is off while a line is still unknown. Cancel writes nothing. A new deck has its name field and format picker on top.
struct PasteDeckSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var paste: PasteDeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch paste.step {
            case .text:
                textStep
            case .reading:
                EmptyMessage(sentence: "Reading the cards…")
            case .table:
                table
            case .failed(let sentence):
                EmptyMessage(sentence: sentence, identifier: "paste-failed") { EmptyView() }
            }
            buttons
        }
        #if os(macOS)
        .frame(minWidth: Theme.importSheetMinWidth, idealWidth: Theme.importSheetIdealWidth,
               minHeight: Theme.importSheetMinHeight, idealHeight: Theme.importSheetIdealHeight)
        #endif
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paste-sheet")
        // Whether the catalog has cards of the game: when the sheet opens, and again when the catalog changes.
        .task(id: "\(model.catalogSettled(game: paste.gameID))|\(model.catalogVersion)") { await paste.checkCatalog() }
        // A read still running when the sheet goes away stores nothing.
        .onDisappear { paste.cancelRead() }
    }

    private var deckName: String { paste.deck?.name ?? "this deck" }

    // MARK: Header

    private var header: some View {
        let formats = Games.game(paste.gameID)?.formats ?? []
        return VStack(alignment: .leading, spacing: Theme.lineGap) {
            Text(paste.deckID == nil ? "Paste a Deck" : "Paste into \(deckName)")
                .font(Theme.sheetTitleFont)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("paste-title")
            if paste.deckID == nil {
                HStack(spacing: Theme.columnGap) {
                    TextField("Name", text: $paste.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("paste-name")
                    if formats.count > 1 {
                        Picker("Format", selection: $paste.format) {
                            ForEach(formats) { format in Text(format.name).tag(format.id) }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("paste-format")
                    }
                }
                .padding(.top, 10)
            }
            if let problem = paste.problem {
                line(problem, color: Theme.muted, id: "paste-problem")
            } else if paste.step == .text, let block = paste.catalogBlock {
                line(block, color: Theme.muted, id: "paste-catalog-note")
            }
            if paste.step == .table {
                Text(paste.summary)
                    .font(Theme.lineFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .padding(.top, Theme.lineGap)
                    .accessibilityIdentifier("paste-summary")
                if paste.unknownCount > 0 {
                    line("\(paste.unknownCount) \(paste.unknownCount == 1 ? "line" : "lines") not recognised: pick a name or drop the line.",
                         color: Theme.text, id: "paste-unknown-count")
                }
                if let notice = paste.notice { line(notice, color: Theme.text, id: "paste-notice") }
            }
        }
        .padding([.horizontal, .top], Theme.sheetPadding)
    }

    private func line(_ text: String, color: Color, id: String) -> some View {
        Text(text)
            .font(Theme.bodyFont)
            .foregroundStyle(color)
            .padding(.top, Theme.lineGap)
            .accessibilityIdentifier(id)
    }

    // MARK: Step 1: the text

    private var textStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One card per line: a count, then the name (3 Ash Blossom & Joyous Spring). A line ending with \":\" starts a section; a line starting with # is a note.")
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $paste.text)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.pictureRadius))
                .accessibilityIdentifier("paste-text")
        }
        .padding(.horizontal, Theme.sheetPadding)
        .padding(.vertical, Theme.ruleSpacing)
    }

    // MARK: Step 2: the table

    private var table: some View {
        let lines = paste.lines
        let format = paste.currentFormat
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
                RuleLine()
                HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
                    Text("Line").frame(width: Self.numberWidth, alignment: .trailing)
                    Text("Count").frame(width: Self.countWidth, alignment: .trailing)
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Section").frame(width: Theme.tableFinishWidth, alignment: .leading)
                }
                .font(Theme.labelFont)
                .foregroundStyle(Theme.muted)
                ForEach(lines) { line in row(line, sectionName: format?.section(line.section)?.name ?? line.section) }
            }
            .padding(.horizontal, Theme.sheetPadding)
            .padding(.bottom, Theme.ruleSpacing)
        }
    }

    private static let numberWidth: CGFloat = 40
    private static let countWidth: CGFloat = 56

    /// One line: its number and count right-aligned in tabular digits, the name (or the menu of an unknown one) with its
    /// note under it, and the section. A dropped line is drawn in `faint`.
    private func row(_ line: PastedLine, sectionName: String) -> some View {
        let dropped = line.match == .dropped
        let notes = [line.note, paste.isDroppedByHand(line) ? "dropped" : nil].compactMap { $0 }
        return HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
            Text("\(line.number)")
                .foregroundStyle(Theme.muted)
                .frame(width: Self.numberWidth, alignment: .trailing)
            Text(line.section.isEmpty ? "—" : "\(line.count)")
                .foregroundStyle(dropped ? Theme.faint : Theme.text)
                .frame(width: Self.countWidth, alignment: .trailing)
                .accessibilityIdentifier("paste-count-\(line.number)")
            VStack(alignment: .leading, spacing: 2) {
                name(line)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .font(Theme.lineFont)
                        .foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("paste-note-\(line.number)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(line.section.isEmpty ? "—" : sectionName)
                .foregroundStyle(dropped ? Theme.faint : Theme.muted)
                .lineLimit(1)
                .frame(width: Theme.tableFinishWidth, alignment: .leading)
                .accessibilityIdentifier("paste-section-\(line.number)")
        }
        .monospacedDigit()
        .font(Theme.bodyFont)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paste-line-\(line.number)")
    }

    /// The card's name; for a name the catalog does not know, a menu of its nearest names and "Drop this line" (or "Keep
    /// this line"), whose label is the written text in `muted` until a name is picked.
    @ViewBuilder private func name(_ line: PastedLine) -> some View {
        if let offered = paste.suggestions(for: line) {
            Menu {
                if offered.isEmpty {
                    Text("No near names in the catalog")
                }
                ForEach(offered, id: \.cardKey) { suggestion in
                    Button(suggestion.name) { paste.pick(suggestion, for: line) }
                }
                Divider()
                if paste.isDroppedByHand(line) {
                    Button("Keep this line") { paste.keep(line) }
                } else {
                    Button("Drop this line") { paste.drop(line) }
                }
            } label: {
                nameText(line)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("paste-unknown-\(line.number)")
        } else {
            nameText(line)
                .accessibilityIdentifier("paste-name-\(line.number)")
        }
    }

    @ViewBuilder private func nameText(_ line: PastedLine) -> some View {
        switch line.match {
        case .card(_, let name):
            Text(name).foregroundStyle(Theme.text).lineLimit(2)
        case .unknown:
            Text(line.text).foregroundStyle(Theme.muted).lineLimit(2)
        case .dropped:
            Text(line.text).foregroundStyle(Theme.faint).lineLimit(2)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Button("Cancel") {
                paste.cancelRead()
                model.pasting = nil
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("paste-cancel")
            // A game that cannot change: its reason stands on top, and Cancel is the only button.
            switch paste.problem == nil ? paste.step : nil {
            case .table?, .failed?:
                Button("Back") { paste.back() }
                    .accessibilityIdentifier("paste-back")
            case .text?, .reading?, nil:
                EmptyView()
            }
            Spacer()
            switch paste.problem == nil ? paste.step : nil {
            case .text?, .reading?:
                // Return is a new line in the text editor, not Read.
                Button("Read") { paste.startRead() }
                    .sheetDefaultButton(onReturn: false)
                    .disabled(!paste.canRead)
                    .accessibilityIdentifier("paste-read")
            case .table?:
                Button(paste.deckID == nil ? "Create deck" : "Add to \(deckName)") { apply() }
                    .sheetDefaultButton()
                    .disabled(!paste.canApply)
                    .accessibilityIdentifier("paste-apply")
            case .failed?, nil:
                EmptyView()
            }
        }
        .padding(Theme.sheetPadding)
        .background(alignment: .top) { Theme.rule.frame(height: 1) }
    }

    /// The paste is written, the sheet closes, and a new deck's page opens.
    private func apply() {
        guard let id = paste.apply() else { return }
        model.pasting = nil
        if paste.deckID == nil { model.showRoot(of: .deck(id)) }
    }
}
