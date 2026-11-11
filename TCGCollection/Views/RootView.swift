import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            NavigationStack {
                CatalogSearchView(search: model.options.search ?? "")
                    .toolbar {
                        ToolbarItem {
                            Menu("Catalog") {
                                Button("Refresh") { Task { await model.refresh(rebuild: false) } }
                                Button("Rebuild catalog…") { confirmRebuild = true }
                            }
                            .disabled(model.options.offline || model.status.isSyncing)
                        }
                    }
            }
            // Search text and filters belong to one game.
            .id(model.gameID)
        }
        .confirmationDialog("Download every set again? About 1,100 requests and 190 MB.",
                            isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild catalog") { Task { await model.refresh(rebuild: true) } }
        }
    }
}

private struct Sidebar: View {
    private enum Item: Hashable { case allCards }

    @Environment(AppModel.self) private var model
    @State private var selection: Item? = .allCards

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
            Section("Catalog") {
                Label("All cards", systemImage: "square.grid.2x2").tag(Item.allCards)
            }
        }
        .safeAreaInset(edge: .bottom) { StatusLine(status: model.status) }
        #if DEBUG && os(macOS)
        .capturableSidebar()
        #endif
    }
}

/// One or two lines; a long text is cut, it never makes the sidebar wider.
private struct StatusLine: View {
    let status: Status

    var body: some View {
        HStack(spacing: 6) {
            if status.isSyncing { ProgressView().controlSize(.small) }
            Text(status.text)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
