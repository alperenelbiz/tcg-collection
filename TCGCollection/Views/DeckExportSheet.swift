import SwiftUI

/// What the export sheet shows, taken when "Export…" is clicked.
struct DeckExportContent: Identifiable {
    let id = UUID()
    let deckName: String
    let text: String
}

/// A80: "Export <deck>": the deck as Paste… text (`DeckExport.text`), read-only and selectable, with Copy and Done.
/// An empty deck says so and its Copy is off. It shows the text taken when it opened (`DeckExportContent`).
struct DeckExportSheet: View {
    let deckName: String
    let text: String
    @State private var copy: DeckExportCopy
    @Environment(\.dismiss) private var dismiss

    init(deckName: String, text: String, copy: DeckExportCopy = DeckExportCopy(write: Pasteboard.write)) {
        self.deckName = deckName
        self.text = text
        _copy = State(initialValue: copy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(deckName)")
                .font(Theme.sheetTitleFont)
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("deck-export-title")
            ScrollView {
                Text(text.isEmpty ? "This deck has no cards." : text)
                    .font(Theme.bodyFont)
                    .foregroundStyle(text.isEmpty ? Theme.muted : Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier("deck-export-text")
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.pictureRadius))
            #if os(macOS)
            .frame(minHeight: 240, maxHeight: 420)
            #endif
            HStack {
                Button(copy.copied ? "Copied" : "Copy") { copy.copy(text) }
                    .buttonStyle(FieldButtonStyle())
                    .disabled(text.isEmpty)
                    .accessibilityIdentifier("deck-export-copy")
                Spacer()
                Button("Done") { dismiss() }
                    .sheetDefaultButton()
                    .accessibilityIdentifier("deck-export-done")
            }
        }
        .padding(Theme.sheetPadding)
        #if os(macOS)
        .frame(width: Theme.settingsWidth)
        #else
        .presentationDetents([.large])
        .tint(Theme.text)
        #endif
        .background(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deck-export-sheet")
        .task(id: copy.copied) {
            guard copy.copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copy.copied = false
        }
    }
}
