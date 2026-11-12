import SwiftUI
import UniformTypeIdentifiers

/// Where the collection lives (B6). The first run of a Release build (and a `-askUserFolder YES` run) opens it, and it
/// cannot be closed without a choice. "Collection Folder…" opens it again with the current folder's path; a choice there
/// switches the library to the new folder and leaves the old folder's files where they are.
struct UserFolderSheet: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        let setup = model.userFolderSetup
        let firstRun = model.needsUserFolder
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where to keep your collection")
                    .font(Theme.sheetTitleFont)
                    .foregroundStyle(Theme.text)
                sentence("Your collection is a few small files: in iCloud Drive they reach your other devices.")
                if firstRun, let lost = setup.lost {
                    sentence(lost.sentence)
                        .accessibilityIdentifier("user-folder-lost")
                }
                if !setup.canChoose {
                    sentence("This run keeps its collection in a fixed folder.")
                } else if setup.iCloudDrive == nil {
                    #if os(macOS)
                    sentence("This Mac has no iCloud Drive.")
                    #else
                    // Without an app iCloud container the iPhone cannot name the drive itself: the folder panel can.
                    sentence("Choose a folder in iCloud Drive to reach your other devices.")
                    #endif
                }
            }
            if !firstRun, let folder = model.library.folder {
                RuleLine()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current folder")
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.muted)
                    Text(folder.path)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("user-folder-path")
                }
                if setup.canChoose {
                    sentence("Files already in the old folder stay there.")
                        .padding(.top, 8)
                }
            }
            if let failure {
                RuleLine()
                // The block that failed says so in one sentence; the buttons below are its actions.
                Text(failure)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("user-folder-failure")
            }
            HStack {
                if !firstRun {
                    Button("Cancel") { model.showsFolderSheet = false }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Choose a folder…") { choosing = true }
                    .disabled(!setup.canChoose || working)
                    .accessibilityIdentifier("user-folder-choose")
                if setup.canChoose, setup.iCloudDrive != nil {
                    Button("Use iCloud Drive") { run { try await model.useICloudDrive() } }
                        .sheetDefaultButton()
                        .disabled(working)
                        .accessibilityIdentifier("user-folder-icloud")
                }
            }
            .padding(.top, 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .presentationBackground(Theme.ground)
        .interactiveDismissDisabled(firstRun)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): run { try await model.useFolder(folder) }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user-folder-sheet")
    }

    /// A sentence of the sheet: body size, `muted`.
    private func sentence(_ text: String) -> some View {
        Text(text)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.muted)
    }

    /// One choice at a time; a failure is said in the sheet, which stays open.
    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do { try await action() } catch { failure = error.localizedDescription }
        }
    }
}
