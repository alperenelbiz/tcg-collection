import SwiftUI

/// "New Deck…" in the sidebar: a name (pre-filled with "Deck", made unique among the game's decks), a format picker for a
/// game with more than one format, "Create" (default) and "Cancel". Create adds the deck, not active (A14), and opens its
/// page. A blank name becomes a unique "Deck" (`UserLibrary.addDeck`). Opened from a card page's "Add to deck" (`adding`),
/// Create adds that card's one copy to the new deck instead (its default section in the chosen format), and the card page
/// stays on show. From the sidebar, "Paste a deck…" closes it and opens the paste sheet with its name and format.
struct NewDeckSheet: View {
    let gameID: String
    /// The card a card page's "New Deck…" adds to the new deck; nil from the sidebar.
    let adding: DeckCardToAdd?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var format: String

    init(gameID: String, deckNames: [String], adding: DeckCardToAdd? = nil) {
        self.gameID = gameID
        self.adding = adding
        _name = State(initialValue: DeckRules.uniqueName("Deck", among: deckNames))
        _format = State(initialValue: Games.game(gameID)?.formats.first?.id ?? "")
    }

    var body: some View {
        let formats = Games.game(gameID)?.formats ?? []
        DeckNameSheet(title: "New Deck", name: $name, identifier: "new-deck", confirm: "Create",
                      canConfirm: !formats.isEmpty && model.library.canChange(game: gameID)
                        && model.decksWritable(game: gameID)) {
            if formats.count > 1 {
                Picker("Format", selection: $format) {
                    ForEach(formats) { format in Text(format.name).tag(format.id) }
                }
                .accessibilityIdentifier("new-deck-format")
            }
            // From the sidebar only: a card page's "New Deck…" adds its card.
            if adding == nil {
                Button("Paste a deck…") {
                    model.pendingPaste = (name, format)
                    dismiss()
                }
                .disabled(formats.isEmpty || !model.library.canChange(game: gameID))
                .accessibilityIdentifier("new-deck-paste")
            }
        } confirmed: {
            // A card page's "New Deck…": the deck and the card's one copy in one library change (final fix A3).
            let cards = adding.flatMap { card in Games.game(gameID).map { DeckPage.newDeckCards(card, format: format, game: $0) } }
            // A5, B2: written to the sheet's own game, and only while it is followed with the player role.
            guard let id = model.addNewDeck(game: gameID, name: name, format: format, cards: cards ?? []) else { return }
            dismiss()
            if adding == nil { model.showRoot(of: .deck(id)) }
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
            // B2: nothing while the game is not followed or its player role is off.
            guard !trimmed.isEmpty, model.decksWritable(game: gameID) else { return }
            model.library.changeDeck(game: gameID, id: deckID) { deck in
                var deck = deck
                deck.name = trimmed
                return deck
            }
            dismiss()
        } cancelled: {
            dismiss()
        }
        // One of the app's sheets (`AppModel.showsSheet`): no import starts under it (final fix B5).
        .onAppear { model.renamingDeck = true }
        .onDisappear { model.renamingDeck = false }
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
    /// The sheet confirmed once (final fix A2): a double click on the default button, or Return and a click, confirms once.
    @State private var done = false

    /// `confirmed`, at most once per sheet.
    private func confirmOnce() {
        guard canConfirm, !done else { return }
        done = true
        confirmed()
    }

    var body: some View {
        let isNew = identifier == "new-deck"
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.sheetTitleFont)
                .foregroundStyle(Theme.text)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(isNew ? "new-deck-name" : "deck-rename-field")
            extra
            HStack {
                Spacer()
                Button("Cancel", action: cancelled)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(identifier)-cancel")
                // The default button takes Return (`sheetDefaultButton`); the field has no `onSubmit` of its own.
                Button(confirm, action: confirmOnce)
                    .sheetDefaultButton()
                    .disabled(!canConfirm || done)
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
