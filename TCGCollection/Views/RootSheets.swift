import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Every sheet, confirmation dialog and file importer of the app's window, on either root (the Mac's split view, the
    /// iPhone's tab bar): moved unchanged from `RootView` (phase 6A task 2).
    func rootSheets(confirmRebuild: Binding<Bool>) -> some View {
        modifier(RootSheets(confirmRebuild: confirmRebuild))
    }
}

/// The window's sheets and dialogs, in the order `RootView` had them.
struct RootSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var confirmRebuild: Bool

    /// "Rebuild catalog…"'s question (the Catalog menu, and the iPhone's Settings, which asks it itself).
    static let rebuildQuestion =
        "Download every set again? Sets already downloaded today are skipped. About 1,100 requests and 190 MB."

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
        // Phase 5B task 5 (A33, K12): the 90-day download's confirmation, from the chart's line and the Catalog menu.
        // Its text is the count when it opened (`backfillDialog`); "Download" with nothing missing by then does nothing.
        // The iPhone's Settings sheet asks it itself while it is open (a dialog of the root cannot show over a sheet).
        .confirmationDialog(model.backfillDialog?.title ?? "",
                            isPresented: Binding(get: { model.asksBackfill && !model.showsSettings },
                                                 set: { model.asksBackfill = $0 }),
                            titleVisibility: .visible) {
            Button(MissingDays.confirmTitle) { model.startBackfill() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.backfillDialog?.message ?? "")
        }
        .confirmationDialog(Self.rebuildQuestion, isPresented: $confirmRebuild, titleVisibility: .visible) {
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
