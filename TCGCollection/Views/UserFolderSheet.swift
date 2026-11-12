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
        VStack(alignment: .leading, spacing: 14) {
            Text("Where to keep your collection")
                .font(.title2.weight(.semibold))
            Text("Your collection is a few small files. In iCloud Drive they reach your other devices.")
            if firstRun, let lost = setup.lost {
                Text(lost.sentence)
                    .accessibilityIdentifier("user-folder-lost")
            }
            if !firstRun, let folder = model.library.folder {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(folder.path)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("user-folder-path")
                }
                if setup.canChoose { Text("Files already in the old folder stay there.") }
            }
            if !setup.canChoose {
                Text("This run keeps its collection in a fixed folder.")
            } else if setup.iCloudDrive == nil {
                #if os(macOS)
                Text("This Mac has no iCloud Drive.")
                #else
                // Without an app iCloud container the iPhone cannot name the drive itself: the folder panel can.
                Text("Choose a folder in iCloud Drive to reach your other devices.")
                #endif
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.secondary)
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
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                        .accessibilityIdentifier("user-folder-icloud")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        #if os(macOS)
        .frame(width: 460)
        #endif
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
