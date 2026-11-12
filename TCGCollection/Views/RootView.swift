import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false
    /// All cards' search, filters, results and card pages, for the life of this window.
    @State private var catalog = CatalogMemory()
    /// The Collection's search, filters, sort, scroll position and pages, for the life of this window.
    @State private var collection = CollectionMemory()

    var body: some View {
        NavigationSplitView {
            Sidebar(screen: model.screen)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            // One screen at a time: a hidden screen would still fill the toolbar (its menus, search field and title).
            // Each screen keeps what it showed (`collection`, `catalog`), so a visit to the other one loses nothing.
            switch model.screen {
            case .collection:
                CollectionStack(state: collection.state(game: model.gameID))
                    // Search text, filters and the open pages belong to one game.
                    .id(model.gameID)
            case .allCards:
                CatalogStack(gameID: model.gameID, state: catalog.state(game: model.gameID, search: model.options.search),
                             confirmRebuild: $confirmRebuild)
                    // Search text, filters and the open card page belong to one game.
                    .id(model.gameID)
            }
        }
        .confirmationDialog("Download every set again? Sets already downloaded today are skipped. About 1,100 requests and 190 MB.",
                            isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild catalog") { Task { await model.refresh(rebuild: true) } }
        }
        // Open while no folder is chosen (it cannot be closed then), or after "Collection Folder…".
        .sheet(isPresented: Binding(get: { model.needsUserFolder || model.showsFolderSheet },
                                    set: { if !$0 { model.showsFolderSheet = false } })) {
            UserFolderSheet()
                .environment(model)
                .preferredColorScheme(.dark)
        }
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
        NavigationStack(path: $state.path) {
            CatalogSearchView(state: state)
                .toolbar {
                    ToolbarItem {
                        Menu("Catalog") {
                            Button("Refresh") { Task { await model.refresh(rebuild: false) } }
                            Button("Rebuild catalog…") { confirmRebuild = true }
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
            state.path.append(card)
        }
    }
}

/// The Collection and the card pages pushed on it.
private struct CollectionStack: View {
    @Bindable var state: CollectionScreenState

    var body: some View {
        NavigationStack(path: $state.path) {
            CollectionView(state: state)
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Optional, as the split view wants it: on the iPhone, going back to the sidebar clears it. The screen itself stays
    /// in the model, which keeps it.
    @State private var selection: Screen?

    init(screen: Screen) {
        _selection = State(initialValue: screen)
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $selection) {
            Picker("Game", selection: $model.gameID) {
                ForEach(Games.all) { game in
                    Text(game.name).tag(game.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // A control, not a selection: it does not take the accent.
            .tint(Theme.text)
            .accessibilityIdentifier("game-picker")
            Section("Lists") {
                row(.collection, title: "Collection", icon: "rectangle.portrait.on.rectangle.portrait")
                    .accessibilityIdentifier("sidebar-collection")
            }
            Section("Catalog") {
                row(.allCards, title: "All cards", icon: "square.grid.2x2")
                    .accessibilityIdentifier("sidebar-all-cards")
            }
        }
        .onChange(of: selection) { _, new in if let new { model.screen = new } }
        .onChange(of: model.screen) { _, new in selection = new }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // On the Collection screen these lines are in the screen itself.
                if model.screen != .collection { LibraryLines(inSidebar: true) }
                StatusLine(status: model.status)
            }
        }
        #if DEBUG && os(macOS)
        .capturableSidebar()
        #endif
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

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(selected ? Theme.ground : Theme.text)
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
/// conflict, each with its one action. Shown on the Collection screen and the pages pushed on it, or in the sidebar's
/// status area while another screen is showing; the identifier `collection-problem` is in one place at a time.
struct LibraryLines: View {
    let inSidebar: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        if library.problem != nil || library.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = library.problem {
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

/// One or two lines, 11 pt `faint`; a long text is cut, it never makes the sidebar wider.
private struct StatusLine: View {
    let status: Status

    var body: some View {
        HStack(spacing: 6) {
            if status.isSyncing { ProgressView().controlSize(.small) }
            Text(status.text)
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
