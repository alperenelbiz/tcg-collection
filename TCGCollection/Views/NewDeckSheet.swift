import SwiftUI

/// "New Deck…" in the sidebar: a name (pre-filled with "Deck", made unique among the game's decks), a format picker for a
/// game with more than one format, "Create" (default) and "Cancel". Create adds the deck, not active (A14), and opens its
/// page. A blank name becomes a unique "Deck" (`UserLibrary.addDeck`).
struct NewDeckSheet: View {
    let gameID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var format: String

    init(gameID: String, deckNames: [String]) {
        self.gameID = gameID
        _name = State(initialValue: DeckRules.uniqueName("Deck", among: deckNames))
        _format = State(initialValue: Games.game(gameID)?.formats.first?.id ?? "")
    }

    var body: some View {
        let formats = Games.game(gameID)?.formats ?? []
        DeckNameSheet(title: "New Deck", name: $name, identifier: "new-deck", confirm: "Create",
                      canConfirm: !formats.isEmpty && model.library.canChange(game: gameID)) {
            if formats.count > 1 {
                Picker("Format", selection: $format) {
                    ForEach(formats) { format in Text(format.name).tag(format.id) }
                }
                .accessibilityIdentifier("new-deck-format")
            }
        } confirmed: {
            guard let id = model.library.addDeck(game: gameID, name: name, format: format) else { return }
            dismiss()
            model.showRoot(of: .deck(id))
        } cancelled: {
            dismiss()
        }
    }
}

/// "Rename…" in a deck's "Deck" menu: one text field with the deck's name; an empty or blank name is not saved.
struct RenameDeckSheet: View {
    let gameID: String
    let deckID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(gameID: String, deckID: String, name: String) {
        self.gameID = gameID
        self.deckID = deckID
        _name = State(initialValue: name)
    }

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        DeckNameSheet(title: "Rename Deck", name: $name, identifier: "deck-rename", confirm: "Save",
                      canConfirm: !trimmed.isEmpty && model.library.canChange(game: gameID)) {
            EmptyView()
        } confirmed: {
            guard !trimmed.isEmpty else { return }
            model.library.changeDeck(game: gameID, id: deckID) { deck in
                var deck = deck
                deck.name = trimmed
                return deck
            }
            dismiss()
        } cancelled: {
            dismiss()
        }
    }
}

/// The frame of a small sheet about a deck's name: the title, the name field, `extra` (the format picker), then Cancel and
/// the default button on the right. Identifiers: New Deck `new-deck-sheet`, `-name`, `-create`, `-cancel`; Rename
/// `deck-rename-sheet`, `-field`, `-save`, `-cancel`.
private struct DeckNameSheet<Extra: View>: View {
    let title: String
    @Binding var name: String
    let identifier: String
    let confirm: String
    let canConfirm: Bool
    @ViewBuilder let extra: Extra
    let confirmed: () -> Void
    let cancelled: () -> Void

    var body: some View {
        let isNew = identifier == "new-deck"
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.sheetTitleFont)
                .foregroundStyle(Theme.text)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canConfirm { confirmed() } }
                .accessibilityIdentifier(isNew ? "new-deck-name" : "deck-rename-field")
            extra
            HStack {
                Spacer()
                Button("Cancel", action: cancelled)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(identifier)-cancel")
                Button(confirm, action: confirmed)
                    .sheetDefaultButton()
                    .disabled(!canConfirm)
                    .accessibilityIdentifier(isNew ? "new-deck-create" : "deck-rename-save")
            }
            .padding(.top, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Theme.sheetPadding)
        #if os(macOS)
        .frame(width: 380)
        #endif
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isNew ? "new-deck-sheet" : "deck-rename-sheet")
    }
}
