#if os(iOS)
import SwiftUI

/// Phase 6A (A50, A54): the iPhone's root, a tab bar over the model's screens. The tab on show is the tab of
/// `model.screen` (`PhoneTabs.tab(of:)`); a tap on a tab shows that tab's last screen (`last`), else its root. Every tab
/// holds its stacks as the Mac's `RootView` does: the same screen views, the same kept state (`*Memory`), the same kept
/// paths (`kept(on:in:)`, whose guard drops the empty path a hidden tab's stack may write), one stack per game
/// (`.id(model.gameID)`).
struct PhoneRootView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false
    /// All cards' search, filters, results and card pages (the search tab).
    @State private var catalog = CatalogMemory()
    /// The Collection's search, filters, sort, scroll position and pages.
    @State private var collection = CollectionMemory()
    /// Wanted's search, sort, scroll position and pages.
    @State private var wanted = WantedMemory()
    /// For Sale's search, sort, scroll position and pages (in the Collection tab).
    @State private var forSale = ForSaleMemory()
    /// The Sets list's scope, sort, search, rows and pages.
    @State private var sets = SetsMemory()
    /// Each deck page's search, pages and last join.
    @State private var decks = DeckMemory()
    /// Each tab's last screen: For Sale or the Collection in the Collection tab, the deck list or a deck in Decks. One
    /// game's: a game switch forgets them.
    @State private var last: [PhoneTab: Screen] = [:]

    var body: some View {
        @Bindable var model = model
        // G7, G8: Decks with the player role, Sets with the collector role. A role turned off sends its screen to the
        // Collection (`AppModel.applyRoles`); until then (a reload removes the tab first) the selection names the
        // Collection, never a tab that is gone.
        let tabs = PhoneTabs.tabs(profile: model.profile(of: model.gameID))
        TabView(selection: Binding(get: { PhoneTabs.selection(of: model.screen, tabs: tabs) },
                                   set: { model.screen = PhoneTabs.screen(for: $0, last: last) })) {
            Tab("Collection", systemImage: "rectangle.portrait.on.rectangle.portrait", value: PhoneTab.collection) {
                tabContent(.collection)
            }
            Tab("Wanted", systemImage: "star", value: PhoneTab.wanted) {
                tabContent(.wanted)
            }
            if tabs.contains(.decks) {
                Tab("Decks", systemImage: "rectangle.stack", value: PhoneTab.decks) {
                    tabContent(.decks)
                }
            }
            if tabs.contains(.sets) {
                Tab("Sets", systemImage: "square.stack.3d.up", value: PhoneTab.sets) {
                    tabContent(.sets)
                }
            }
            // The system draws it as the separate search button.
            Tab(value: PhoneTab.search, role: .search) {
                tabContent(.search)
            }
        }
        .onChange(of: model.screen, initial: true) { _, screen in last[PhoneTabs.tab(of: screen)] = screen }
        // Every tab of the old game starts afresh, not only the one on show.
        .onChange(of: model.gameID) { _, game in
            catalog.keep(game: game)
            collection.keep(game: game)
            wanted.keep(game: game)
            forSale.keep(game: game)
            sets.keep(game: game)
            decks.keep(game: game)
            // The old game's last screens (a deck of it) mean nothing in the new game.
            last = [PhoneTabs.tab(of: model.screen): model.screen]
        }
        .background { DeckMemoryKeeper(memory: decks) }
        // A54: Settings, a sheet of this window like the others: it opens only while no other sheet is open or due
        // (`openSettings`), and the folder sheet or the first-run question it hands over to opens once it has gone
        // (`settingsClosed`).
        .sheet(isPresented: $model.showsSettings, onDismiss: { model.settingsClosed() }) {
            SettingsSheet()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { model.settingsOnScreen = true }
        }
        .rootSheets(confirmRebuild: $confirmRebuild)
    }

    /// The screen a tab shows: the model's screen when it belongs to the tab, else the tab's last screen (or root).
    private func shown(in tab: PhoneTab) -> Screen {
        PhoneTabs.tab(of: model.screen) == tab ? model.screen : PhoneTabs.screen(for: tab, last: last)
    }

    /// A tab's stacks, with the status line above the tab bar.
    private func tabContent(_ tab: PhoneTab) -> some View {
        stacks(of: shown(in: tab))
            .safeAreaInset(edge: .bottom, spacing: 0) { PhoneStatusLine() }
    }

    @ViewBuilder
    private func stacks(of screen: Screen) -> some View {
        let game = model.gameID
        switch screen {
        case .collection:
            let state = collection.state(game: game)
            ListStack(path: Bindable(state).path.kept(on: .collection, in: model)) {
                CollectionView(state: state).phoneRootToolbar().collectionSwitch()
            }
            .id(game)
        case .forSale:
            let state = forSale.state(game: game)
            ListStack(path: Bindable(state).path.kept(on: .forSale, in: model)) {
                ForSaleView(state: state).phoneRootToolbar().collectionSwitch()
            }
            .pdfSaving(state.export, model: model)
            .id(game)
        case .wanted:
            let state = wanted.state(game: game)
            ListStack(path: Bindable(state).path.kept(on: .wanted, in: model)) {
                WantedView(state: state).phoneRootToolbar()
            }
            .pdfSaving(state.export, model: model)
            .id(game)
        case .sets:
            let state = sets.state(game: game)
            ListStack(path: Bindable(state).path.kept(on: .sets, in: model)) {
                SetsView(state: state).phoneRootToolbar()
            }
            .id(game)
        case .allCards:
            CatalogStack(gameID: game, state: catalog.state(game: game, search: model.options.search),
                         confirmRebuild: $confirmRebuild)
                .id(game)
        case .decks:
            NavigationStack {
                DeckListView().phoneRootToolbar()
            }
            .id(game)
        case .deck(let id):
            let state = decks.state(game: game, deck: id)
            ListStack(path: Bindable(state).path.kept(on: .deck(id), in: model)) {
                DeckView(state: state)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // The deck page is the Decks tab's second level: its leading button returns to the list.
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                model.screen = .decks
                            } label: {
                                Label("Decks", systemImage: "chevron.backward")
                                    .labelStyle(.titleAndIcon)
                            }
                            .accessibilityIdentifier("deck-list-back")
                        }
                    }
            }
            .id("\(game)|\(id)")
        }
    }
}

extension View {
    /// The top bar of a tab's root (A54): the game menu leading, the gear trailing; the title inline.
    func phoneRootToolbar() -> some View {
        modifier(PhoneRootToolbar())
    }
}

private struct PhoneRootToolbar: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { GameMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings-button")
                }
            }
    }
}

extension View {
    /// A50: the Collection tab's one control row, the switch "Collection / For Sale", above the screen's content.
    func collectionSwitch() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { CollectionSwitch() }
    }
}

/// A50: For Sale is inside the Collection tab, behind one segmented switch bound to the model's screen. Each side keeps
/// its own stack (`PhoneRootView.stacks`), so each keeps its pages.
private struct CollectionSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Collection or For Sale", selection: Binding(get: { model.screen == .forSale ? Screen.forSale : .collection },
                                                            set: { model.screen = $0 })) {
            Text("Collection").tag(Screen.collection)
            Text("For Sale").tag(Screen.forSale)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Not the accent (the selected tab and a sheet's default button only), as the other segmented controls.
        .tint(Theme.faint)
        .accessibilityIdentifier("collection-switch")
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, Theme.lineGap * 2)
        .background(Theme.ground)
    }
}

/// A54: the game's name and a chevron, a menu of the followed games (G4). A control, not a selection: `Theme.text`.
struct GameMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // B8: the game shown is always one of the followed games.
        let shown = GameSelection.shown(asked: model.gameID, followed: model.followedGames.map(\.id))
        Menu {
            ForEach(model.followedGames) { game in
                Button {
                    model.gameID = game.id
                } label: {
                    if game.id == shown {
                        Label(game.name, systemImage: "checkmark")
                    } else {
                        Text(game.name)
                    }
                }
                .accessibilityIdentifier("game-menu-\(game.id)")
            }
        } label: {
            HStack(spacing: Theme.lineGap) {
                Text(Games.game(shown)?.name ?? model.game.name)
                    .font(Theme.sectionFont)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Theme.labelFont)
            }
            .foregroundStyle(Theme.text)
        }
        .accessibilityIdentifier("game-menu")
    }
}

/// The status line above the tab bar: one line, only while there is something to say (`PhoneStatus.shows`). Its full
/// text is always in Settings.
private struct PhoneStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloading = model.backfillProgress != nil
        if PhoneStatus.shows(status: model.status, notice: model.statusNotice, downloading: downloading) {
            HStack(spacing: Theme.lineGap) {
                if model.statusNotice == nil && (model.status.isSyncing || downloading) {
                    ProgressView().controlSize(.small)
                }
                Text(model.statusLineText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("status-inset")
            }
            .font(Theme.labelFont)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, Theme.lineGap * 2)
            .background(Theme.ground)
        }
    }
}

/// The Decks tab's root: the game's decks and "New Deck…" (Task 5 completes it with the Mac sidebar's missing counts,
/// the unreadable-decks line and the order by drag). A tap on a deck shows its page in the tab.
struct DeckListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library, game = model.gameID
        List {
            ForEach(model.decksInPlay(game: game)) { deck in
                Button {
                    model.screen = .deck(deck.id)
                } label: {
                    Label(deck.name, systemImage: "rectangle.stack")
                        .foregroundStyle(Theme.text)
                }
                .accessibilityIdentifier("sidebar-deck-\(deck.id)")
            }
            Button {
                model.openNewDeck(game: game)
            } label: {
                Label("New Deck…", systemImage: "plus")
                    .foregroundStyle(Theme.muted)
            }
            .disabled(!library.canChange(game: game))
            .accessibilityIdentifier("sidebar-new-deck")
        }
        .navigationTitle("Decks")
        // Review Focus 5: this game's problem, which the Mac's sidebar shows beside the Decks section.
        .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
        // A container, so the identifier does not cover the lines' own identifiers (as `listScreen`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("decks-screen")
    }
}

#endif
