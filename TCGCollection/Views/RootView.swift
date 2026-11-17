import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false
    /// All cards' search, filters, results and card pages, for the life of this window.
    @State private var catalog = CatalogMemory()
    /// The Collection's search, filters, sort, scroll position and pages, for the life of this window.
    @State private var collection = CollectionMemory()
    /// Wanted's search, sort, scroll position and pages, for the life of this window.
    @State private var wanted = WantedMemory()
    /// For Sale's search, sort, scroll position and pages, for the life of this window.
    @State private var forSale = ForSaleMemory()
    /// The Sets list's scope, sort, search, rows and pages, for the life of this window.
    @State private var sets = SetsMemory()
    /// Each deck page's search, pages and last join, for the life of this window.
    @State private var decks = DeckMemory()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(screen: model.screen)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            // One screen at a time: a hidden screen would still fill the toolbar (its menus, search field and title).
            // Each screen keeps what it showed (`collection`, `wanted`, `forSale`, `catalog`), so a visit to another one
            // loses nothing; its open pages too (`kept(on:in:)`). Search text, filters and the open pages belong to one
            // game: a game switch drops the kept state of every screen (`keep(game:)` below; `.id` makes new stacks).
            switch model.screen {
            case .collection:
                let state = collection.state(game: model.gameID)
                ListStack(path: Bindable(state).path.kept(on: .collection, in: model)) { CollectionView(state: state) }
                    .id(model.gameID)
            case .wanted:
                let state = wanted.state(game: model.gameID)
                ListStack(path: Bindable(state).path.kept(on: .wanted, in: model)) { WantedView(state: state) }
                    // The PDF's save panel and its end: on the stack, which leaves only with the screen.
                    .pdfSaving(state.export, model: model)
                    .id(model.gameID)
            case .forSale:
                let state = forSale.state(game: model.gameID)
                ListStack(path: Bindable(state).path.kept(on: .forSale, in: model)) { ForSaleView(state: state) }
                    .pdfSaving(state.export, model: model)
                    .id(model.gameID)
            case .sets:
                let state = sets.state(game: model.gameID)
                ListStack(path: Bindable(state).path.kept(on: .sets, in: model)) { SetsView(state: state) }
                    .id(model.gameID)
            case .allCards:
                CatalogStack(gameID: model.gameID, state: catalog.state(game: model.gameID, search: model.options.search),
                             confirmRebuild: $confirmRebuild)
                    // Search text, filters and the open card page belong to one game.
                    .id(model.gameID)
            case .deck(let id):
                let state = decks.state(game: model.gameID, deck: id)
                ListStack(path: Bindable(state).path.kept(on: .deck(id), in: model)) { DeckView(state: state) }
                    // Each deck has its own stack.
                    .id("\(model.gameID)|\(id)")
            }
        }
        // Every screen of the old game starts afresh, not only the one on show.
        .onChange(of: model.gameID) { _, game in
            catalog.keep(game: game)
            collection.keep(game: game)
            wanted.keep(game: game)
            forSale.keep(game: game)
            sets.keep(game: game)
            decks.keep(game: game)
        }
        // A deck deleted (here, or on another device) drops its kept state at once. A view of its own reads the decks, so a
        // change of the library does not compute this body again.
        .background { DeckMemoryKeeper(memory: decks) }
        // Phase 5B task 5 (A33, K12): the 90-day download's confirmation, from the chart's line and the Catalog menu.
        // Its text is the count when it opened (`backfillDialog`); "Download" with nothing missing by then does nothing.
        .confirmationDialog(model.backfillDialog?.title ?? "",
                            isPresented: $model.asksBackfill, titleVisibility: .visible) {
            Button(MissingDays.confirmTitle) { model.startBackfill() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.backfillDialog?.message ?? "")
        }
        .confirmationDialog("Download every set again? Sets already downloaded today are skipped. About 1,100 requests and 190 MB.",
                            isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild catalog") { Task { await model.refresh(rebuild: true) } }
        }
        // Open while no folder is chosen (it cannot be closed then), or after "Collection Folder…". The onboarding sheet
        // waits until this one has gone (two sheets never change places at once).
        .sheet(isPresented: Binding(get: { model.needsUserFolder || model.showsFolderSheet },
                                    set: { if !$0 { model.showsFolderSheet = false } }),
               onDismiss: { model.folderSheetClosed() }) {
            UserFolderSheet()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { model.folderSheetOnScreen = true }
        }
        // G11: the first-run question on a new folder. It cannot be dismissed: only "Continue" closes it (the binding takes
        // no write). "Collection Folder…" meanwhile closes it first and opens the folder sheet once it has gone.
        .sheet(isPresented: Binding(get: { model.showsOnboarding }, set: { _ in }),
               onDismiss: { model.onboardingSheetClosed() }) {
            OnboardingSheet()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        // "Import CSV…" (the Collection's toolbar and empty state, File › Import CSV…). The picked file is read, never
        // written; the system panel is not driven by the UI tests (they use `-importCSV`).
        .fileImporter(isPresented: $model.choosesCSVFile, allowedContentTypes: [.commaSeparatedText]) { result in
            switch result {
            case .success(let url): Task { await model.importCSV(from: url) }
            case .failure(let error): model.importFailed(error)
            }
        }
        // "Paste a deck…" of this sheet opens the paste sheet once this one has closed.
        .sheet(isPresented: $model.showsNewDeck, onDismiss: {
            model.newDeckClosed()
            model.openPendingPaste()
        }) {
            // A5: the sheet's game is the one it was opened for, captured by the host when it opens.
            NewDeckSheetHost(game: model.newDeckGame, card: model.newDeckCard)
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $model.importing) { importModel in
            ImportSheet(importModel: importModel)
                .environment(model)
                .preferredColorScheme(.dark)
        }
        // "Paste…" of a deck page, and "Paste a deck…" of the New Deck sheet.
        .sheet(item: $model.pasting) { paste in
            PasteDeckSheet(paste: paste)
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Drops the kept state of a deck that is gone (`DeckMemory.keep(decks:)`) as soon as the game's deck ids change.
private struct DeckMemoryKeeper: View {
    @Environment(AppModel.self) private var model
    let memory: DeckMemory

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: model.library.decks(game: model.gameID).map(\.id)) { _, ids in memory.keep(decks: Set(ids)) }
    }
}

/// The catalog gallery and the card pages pushed on it.
private struct CatalogStack: View {
    /// The game this stack belongs to; `RootView` makes a new stack when the game changes.
    let gameID: String
    @Bindable var state: CatalogScreenState
    @Binding var confirmRebuild: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: $state.path.kept(on: .allCards, in: model)) {
            CatalogSearchView(state: state)
                .toolbar {
                    ToolbarItem {
                        Menu("Catalog") {
                            Button("Refresh") { Task { await model.refresh(rebuild: false) } }
                            Button("Rebuild catalog…") { confirmRebuild = true }
                            Button(MissingDays.menuTitle) { model.askBackfill() }
                                .disabled(!model.canAskBackfill)
                                .accessibilityIdentifier("catalog-download-history")
                        }
                        // Not with a store in memory (`storeFailure`): a sync would do nothing there.
                        .disabled(model.options.offline || model.status.isSyncing || model.storeFailure != nil)
                        .accessibilityIdentifier("catalog-menu")
                    }
                }
        }
        .task(id: model.pendingCard) {
            // The stack of the old game is still alive for a moment: only the new one takes the card.
            guard let card = model.pendingCard, card.gameID == gameID else { return }
            model.pendingCard = nil
            // Through the kept path: `-card` switched by code (`showRoot`), so the card's page replaces any kept page.
            $state.path.kept(on: .allCards, in: model).wrappedValue.append(card)
        }
    }
}

extension Binding where Value == NavigationPath {
    /// The path of `screen`'s navigation stack, kept in that screen's state, so its open pages are there again when the
    /// sidebar returns to it.
    /// - A stack that leaves the window writes an empty path through its binding (seen on macOS 27: the sidebar shows one
    ///   screen at a time, so a switch removes the stack). That write comes when `model.screen` is already another
    ///   screen, and is not taken.
    /// - After a switch made by code (`AppModel.showRoot(of:)`: "Search a card", the import, `-card`) the screen reads as
    ///   its root, whatever it kept; the first page opened or closed there replaces the kept pages
    ///   (`AppModel.pagesChanged(on:)`).
    /// - Every write while the screen is on show is taken: a link, Back, a game switch (the new game's state is fresh).
    func kept(on screen: Screen, in model: AppModel) -> Binding<NavigationPath> {
        Binding(get: { model.showsRoot(screen) ? NavigationPath() : wrappedValue },
                set: { path in
                    guard model.screen == screen else { return }
                    model.pagesChanged(on: screen)
                    wrappedValue = path
                })
    }
}

/// A list screen (the Collection, Wanted, For Sale, a deck) and the pages pushed on it, in the screen's own navigation
/// stack.
private struct ListStack<Content: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack(path: $path) {
            content
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Optional, as the split view wants it: on the iPhone, going back to the sidebar clears it. The screen itself stays
    /// in the model, which keeps it.
    @State private var selection: Screen?
    /// The catalog read of every active deck of the game, for the rows' missing counts (A14, D7): one join for all rows.
    @State private var activeDecks = DeckJoin()

    init(screen: Screen) {
        _selection = State(initialValue: screen)
    }

    var body: some View {
        // The status area has its own room under the list: the list scrolls above it, so with many decks in a short
        // window nothing is drawn over its last rows.
        VStack(spacing: 0) {
            list
                #if DEBUG && os(macOS)
                .capturableSidebar()
                #endif
            // A view of its own: a status change redraws only it, not the list and its decks (final fix B9).
            SidebarStatus()
        }
        // E8: the count of pending cards of the game on screen, from the sidebar's join; a view of its own, as above.
        .background { PendingWatcher(activeDecks: activeDecks) }
    }

    private var list: some View {
        @Bindable var model = model
        let profile = model.profile(of: model.gameID)
        return List(selection: $selection) {
            // G4: the followed games only, in the games' order.
            // B8: the selection shown is always one of the items: when the game on screen stops being followed, the first
            // followed game, in this render (the model's own switch follows).
            Picker("Game", selection: Binding(
                get: { GameSelection.shown(asked: model.gameID, followed: model.followedGames.map(\.id)) },
                set: { model.gameID = $0 })) {
                ForEach(model.followedGames) { game in
                    Text(game.name).tag(game.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // A control, not a selection: it does not take the accent.
            .tint(Theme.text)
            .accessibilityIdentifier("game-picker")
            // Collection, Wanted, For Sale, Sets, in this order.
            Section("Lists") {
                row(.collection, title: "Collection", icon: "rectangle.portrait.on.rectangle.portrait")
                    .accessibilityIdentifier("sidebar-collection")
                row(.wanted, title: "Wanted", icon: "star")
                    .accessibilityIdentifier("sidebar-wanted")
                row(.forSale, title: "For Sale", icon: "tag")
                    .accessibilityIdentifier("sidebar-for-sale")
                // G8: only with the collector role; a hidden row leaves no gap.
                if GameSections.showsSets(profile) {
                    row(.sets, title: "Sets", icon: "square.stack.3d.up")
                        .accessibilityIdentifier("sidebar-sets")
                }
            }
            // G7: only with the player role; a hidden section leaves no heading.
            if GameSections.showsDecks(profile) {
                SidebarDecks(selection: selection, activeDecks: activeDecks)
            }
            Section("Catalog") {
                row(.allCards, title: "All cards", icon: "square.grid.2x2")
                    .accessibilityIdentifier("sidebar-all-cards")
            }
        }
        .onChange(of: selection) { _, new in if let new { model.screen = new } }
        .task(id: DeckJoin.deckKey(game: model.gameID, model: model)) {
            let key = DeckJoin.deckKey(game: model.gameID, model: model)
            // G7: no deck in play without the player role: the join does not run.
            let active = model.decksInPlay(game: key.game).filter(\.active)
            // Without an active deck no row shows a count: nothing to read.
            guard !active.isEmpty else { return }
            await activeDecks.run(key, cardKeys: Set(active.flatMap { $0.cards.map(\.cardKey) }), model: model)
        }
        .onChange(of: model.screen) { _, new in selection = new }
    }

    /// A row of the list's selection. The selected one draws its own accent fill over the system's (grey without focus,
    /// the user's colour with a system accent other than Multicolor), so it is amber in every state; it stays the list's
    /// real selection for the arrow keys and VoiceOver.
    private func row(_ screen: Screen, title: String, icon: String) -> some View {
        let selected = selection == screen
        return SidebarRow(title: title, icon: icon, selected: selected)
            .tag(screen)
            .listRowBackground(selected ? SelectionFill() : nil)
    }
}

/// E8: hands the count of pending cards of the game on screen to the model (`AppModel.pendingCountChanged`), which says
/// once when it goes up. The count is made in memory from the library's decks and answers and the owned copies of the
/// sidebar's last join of the active decks (`DeckPage.pendingCount`): no catalog read. Unknown (nil) until the folder is
/// read and, with an active deck, until a join of the game has read its cards; 0 with no active deck.
private struct PendingWatcher: View {
    @Environment(AppModel.self) private var model
    let activeDecks: DeckJoin

    private struct Count: Equatable {
        let game: String
        let pending: Int?
    }

    var body: some View {
        let library = model.library, game = model.gameID
        // G7: no count without the player role (nil: no notice, and the base stays).
        let pending = GameSections.watchedPendingCount(loaded: library.isLoaded, profile: model.profile(of: game),
                                                       decks: model.decksInPlay(game: game),
                                                       sharing: library.sharing(game: game), read: activeDecks.read(game: game))
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: Count(game: game, pending: pending), initial: true) { _, now in
                model.pendingCountChanged(now.pending, game: now.game)
            }
    }
}

/// The sidebar's status area: the library's lines (on a screen that is not a list) and the status line.
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // On a list screen these lines are in the screen itself.
            if !model.screen.isList { LibraryLines(inSidebar: true) }
            StatusLine(text: model.statusLineText,
                       working: model.statusNotice == nil && (model.status.isSyncing || model.backfillProgress != nil))
        }
    }
}

/// D7: one row per deck of the game, in deck order (a drag changes it, E6), with its missing count (an active deck that
/// misses copies; the active decks are served in deck order, E4), the line for decks this build cannot read, then
/// "New Deck…", a button, not a selectable row. A view of its own, so a change of the status line does not compute it
/// again (final fix B9).
private struct SidebarDecks: View {
    @Environment(AppModel.self) private var model
    let selection: Screen?
    /// The sidebar's one join of every active deck (`Sidebar.activeDecks`).
    let activeDecks: DeckJoin

    var body: some View {
        let library = model.library, game = model.gameID
        let read = activeDecks.read(game: game), decks = model.decksInPlay(game: game)
        // E4: the active decks are served in deck order (a shared card: each sees every owned copy).
        let needs = DeckPage.needs(decks: decks, sharing: library.sharing(game: game), read: read)
        Section("Decks") {
            ForEach(decks) { deck in
                deckRow(deck, missing: DeckPage.sidebarCount(deck, read: read,
                                                             available: DeckPage.available(to: deck, needs: needs, read: read)))
            }
            // E6: a drag changes the deck order (the order the active decks are served in). Off while the game cannot change.
            .onMove(perform: library.canChange(game: game) ? { sources, destination in
                guard let source = sources.first, decks.indices.contains(source) else { return }
                library.moveDeck(game: game, id: decks[source].id,
                                 to: DeckPage.moveIndex(from: source, to: destination))
            } : nil)
            if let text = DeckPage.unreadableText(library.unreadableDecks(game: game)) {
                Text(text)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("sidebar-decks-unreadable")
            }
            Button { model.openNewDeck(game: game) } label: {
                SidebarRow(title: "New Deck…", icon: "plus", selected: false, muted: true)
            }
            .buttonStyle(.plain)
            .disabled(!library.canChange(game: game))
            .accessibilityIdentifier("sidebar-new-deck")
        }
    }

    /// A deck's row: as a Lists row, with the missing count as plain text at its trailing edge (no capsule, tabular digits).
    private func deckRow(_ deck: Deck, missing: String?) -> some View {
        let screen = Screen.deck(deck.id), selected = selection == screen
        return HStack(spacing: 6) {
            SidebarRow(title: deck.name, icon: "rectangle.stack", selected: selected)
            Spacer(minLength: 4)
            if let missing {
                Text(missing)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Theme.ground : Theme.muted)
                    .accessibilityIdentifier("sidebar-deck-missing-\(deck.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-deck-\(deck.id)")
        .tag(screen)
        .listRowBackground(selected ? SelectionFill() : nil)
    }
}

/// The selected sidebar row's fill: `accent`, with the size of the system's selection on macOS 27 (measured: 10 pt in
/// from each side, 10 pt corners, the row's full height), so none of the system's own fill shows around it.
private struct SelectionFill: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.accent)
            .padding(.horizontal, 10)
    }
}

/// A sidebar row: an outline icon (`sidebarIconSize`) in `muted` and the title in `text`. Selected, it sits on the
/// accent fill and both are `ground`, as the mockup has them: white on the amber accent reads at under 2:1.
private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    /// "New Deck…": the title in `muted`.
    var muted = false

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(selected ? Theme.ground : muted ? Theme.muted : Theme.text)
        } icon: {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .symbolVariant(.none)
                .frame(width: Theme.sidebarIconSize, height: Theme.sidebarIconSize)
                .foregroundStyle(selected ? Theme.ground : Theme.muted)
        }
    }
}

/// What the user folder needs said: a problem (the folder is missing, a file is refused, a write failed) and a settled
/// conflict, each with its one action. On a list screen it is this game's problem (`UserLibrary.problem(game:)`); in the
/// sidebar the first problem of all. Shown on a list screen (the Collection, Wanted, For Sale: `Screen.isList`) and the
/// pages pushed on it, or in the sidebar's status area while another screen is showing; the identifier
/// `collection-problem` is in one place at a time.
struct LibraryLines: View {
    let inSidebar: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        // The Collection and its pages show this game's problem first; the sidebar the first one of all.
        let problem = inSidebar ? library.problem : library.problem(game: model.gameID)
        if problem != nil || library.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let problem {
                    Text(problem)
                        .foregroundStyle(inSidebar ? Theme.faint : Theme.text)
                        .lineLimit(3)
                        .accessibilityIdentifier("collection-problem")
                    if library.folderIsMissing, model.userFolderSetup.canChoose {
                        Button("Choose the folder…") { model.showsFolderSheet = true }
                            .accessibilityIdentifier("collection-choose-folder")
                    }
                }
                if let notice = library.notice {
                    Text(notice)
                        .foregroundStyle(inSidebar ? Theme.faint : Theme.muted)
                        .lineLimit(3)
                        .accessibilityIdentifier("collection-notice")
                    Button("OK") { library.clearNotice() }
                }
            }
            .font(inSidebar ? Theme.labelFont : Theme.bodyFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inSidebar ? 16 : Theme.margin)
            .padding(.top, inSidebar ? 10 : Theme.ruleSpacing)
            .padding(.bottom, inSidebar ? 0 : Theme.ruleSpacing)
            .background(alignment: .bottom) {
                // On the screen the lines are a group of their own, ruled off from the content below.
                if !inSidebar { Theme.rule.frame(height: 1) }
            }
        }
    }
}

/// One or two lines, 11 pt `faint`; a long text is cut, it never makes the sidebar wider. An import's summary (`notice`)
/// stands in for the status until the status changes.
private struct StatusLine: View {
    /// `AppModel.statusLineText`: a notice, else the sync's line, else the 90-day download's progress, else the status.
    let text: String
    /// A sync or the 90-day download runs (and no notice stands in for it): the spinner shows.
    let working: Bool

    var body: some View {
        HStack(spacing: 6) {
            if working { ProgressView().controlSize(.small) }
            Text(text)
                .lineLimit(2)
                .truncationMode(.tail)
                .accessibilityIdentifier("status-line")
        }
        .font(Theme.labelFont)
        .foregroundStyle(Theme.faint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
