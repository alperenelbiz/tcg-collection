#if os(iOS)
import SwiftUI

/// Phase 6A (A54): the iPhone's Settings, a sheet the gear opens (the Mac has its Settings window and its Catalog menu).
/// One scrolling column on the dark ground, four sections ruled apart: "Games" (the Mac pane's rows and binding), "Collection
/// folder" (the folder's path and "Choose a folder…"), "Catalog" (the Mac's Catalog menu, with its rules) and "Status"
/// (the full status line). "Done" closes it.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    games
                    RuleLine()
                    folder
                    RuleLine()
                    catalog
                    RuleLine()
                    status
                }
                .padding(Theme.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showsSettings = false }
                        .accessibilityIdentifier("settings-done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.ground)
        // The root's dialogs cannot show over this sheet: Settings holds its own two (the Mac's Catalog menu's).
        .confirmationDialog(RootSheets.rebuildQuestion, isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild catalog") { Task { await model.refresh(rebuild: true) } }
        }
        .confirmationDialog(model.backfillDialog?.title ?? "", isPresented: $model.asksBackfill,
                            titleVisibility: .visible) {
            Button(MissingDays.confirmTitle) { model.startBackfill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.backfillDialog?.message ?? "")
        }
        .accessibilityIdentifier("settings-sheet")
    }

    /// A section's heading: as the card page's "Other printings".
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Theme.labelFont)
            .foregroundStyle(Theme.muted)
            .padding(.bottom, Theme.lineGap * 2)
    }

    /// The games and roles: `GamesSettingsPane`'s rows and binding, its note under them.
    private var games: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Games")
            GameProfilesView(profiles: GamesSettingsPane.binding(model: model,
                                                                 rendered: GamesSettingsPane.profiles(model.library)),
                             rows: GamesSettingsPane.rows(model))
            Text(ProfileRows.settingsNote(onboarding: model.onboardingDue))
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.ruleSpacing)
                .accessibilityIdentifier("settings-note")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-games")
    }

    /// The folder's path, the library's problem (Review Focus 5) and "Choose a folder…" (`askForFolder`: Settings closes
    /// first, then the folder sheet opens).
    private var folder: some View {
        let library = model.library
        return VStack(alignment: .leading, spacing: Theme.lineGap * 2) {
            heading("Collection folder")
            Text(library.folder?.path ?? "No collection folder is chosen.")
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-folder-path")
            if let problem = library.problem {
                Text(problem)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-problem")
            }
            Button("Choose a folder…") { model.askForFolder() }
                .buttonStyle(FieldButtonStyle())
                .padding(.top, Theme.lineGap)
                .accessibilityIdentifier("settings-choose-folder")
        }
    }

    /// The Mac's Catalog menu: off offline, while a sync runs and with a store in memory; the 90-day download only while
    /// `canAskBackfill`.
    private var catalog: some View {
        let catalogOff = model.options.offline || model.status.isSyncing || model.storeFailure != nil
        return VStack(alignment: .leading, spacing: Theme.lineGap * 2) {
            heading("Catalog")
            HStack(spacing: Theme.lineGap * 2) {
                Button("Refresh") { Task { await model.refresh(rebuild: false) } }
                    .accessibilityIdentifier("settings-refresh")
                Button("Rebuild catalog…") { confirmRebuild = true }
                    .accessibilityIdentifier("settings-rebuild")
            }
            .disabled(catalogOff)
            Button(MissingDays.menuTitle) { model.askBackfill() }
                .disabled(catalogOff || !model.canAskBackfill)
                .accessibilityIdentifier("catalog-download-history")
        }
        .buttonStyle(FieldButtonStyle())
    }

    /// The full status line (the line above the tab bar shows only while there is something to say).
    private var status: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Status")
            Text(model.statusLineText)
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("status-line")
        }
    }
}
#endif
