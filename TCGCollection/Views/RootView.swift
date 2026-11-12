import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false

    var body: some View {
        NavigationSplitView {
            Sidebar(screen: model.screen)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            switch model.screen {
            case .collection:
                CollectionPlaceholder()
            case .allCards:
                CatalogStack(gameID: model.gameID, confirmRebuild: $confirmRebuild)
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
    @Binding var confirmRebuild: Bool
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            CatalogSearchView(search: model.options.search ?? "")
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
            path.append(card)
        }
    }
}

/// The Collection until Task 5 builds it: the title, one sentence, and what the user folder needs said.
private struct CollectionPlaceholder: View {
    var body: some View {
        NavigationStack {
            EmptyMessage(sentence: "No cards in this collection yet.")
                .safeAreaInset(edge: .top, spacing: 0) { LibraryLines(inSidebar: false) }
                .background { Theme.ground.ignoresSafeArea() }
                .navigationTitle("Collection")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("collection-screen")
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Optional, as the split view wants it: on the iPhone, going back to the sidebar clears it. The screen itself stays
    /// in the model, which keeps it.
    @State private var selection: Screen?
    /// The system emphasizes the selection (the accent fill) while the sidebar has focus in the active window.
    @FocusState private var listFocused: Bool
    @Environment(\.appearsActive) private var appearsActive

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
                SidebarRow(title: "Collection", icon: "square.stack", onAccent: emphasized(.collection)).tag(Screen.collection)
                    .accessibilityIdentifier("sidebar-collection")
            }
            Section("Catalog") {
                SidebarRow(title: "All cards", icon: "square.grid.2x2", onAccent: emphasized(.allCards)).tag(Screen.allCards)
                    .accessibilityIdentifier("sidebar-all-cards")
            }
        }
        .focused($listFocused)
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

    /// True while the row of `screen` is drawn on the accent fill. Not on the iPhone, whose list shows no selection fill.
    private func emphasized(_ screen: Screen) -> Bool {
        #if os(macOS)
        selection == screen && listFocused && appearsActive
        #else
        false
        #endif
    }
}

/// A sidebar row: a 16 pt outline icon in `muted` and the title in `text`. The selected row is the system's selection,
/// drawn in the app's accent (the `AccentColor` asset). On that fill (`onAccent`) icon and title are `ground`, as the
/// mockup has them: the system's white on the amber accent reads at under 2:1. (`backgroundProminence` does not report
/// the fill in a macOS 27 sidebar, so the sidebar works it out.)
private struct SidebarRow: View {
    let title: String
    let icon: String
    let onAccent: Bool

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(onAccent ? Theme.ground : Theme.text)
        } icon: {
            Image(systemName: icon)
                .symbolVariant(.none)
                .foregroundStyle(onAccent ? Theme.ground : Theme.muted)
        }
    }
}

/// What the user folder needs said: a problem (the folder is missing, a file is refused, a write failed) and a settled
/// conflict, each with its one action. Shown on the Collection screen, or in the sidebar's status area while another
/// screen is showing; the identifier `collection-problem` is in one place at a time.
private struct LibraryLines: View {
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
