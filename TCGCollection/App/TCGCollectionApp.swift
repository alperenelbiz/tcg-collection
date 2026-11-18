import SwiftUI

@main
struct TCGCollectionApp: App {
    @State private var model: AppModel?
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    init() {
        // The unit tests run inside the app. There the app makes no model: no store is opened and
        // nothing is downloaded; the tests make their own models with fakes.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let options = LaunchOptions(arguments: CommandLine.arguments)
        #if DEBUG && os(macOS)
        TestWindow.ignoreSavedWindows(options)
        #endif
        _model = State(initialValue: Self.makeModel(options))
    }

    /// The model on the network `LaunchNetwork.choose` picks. The real clients are made only when no `-fixtures` was
    /// given: a `-fixtures` run is on files, or it has no network at all (I3).
    private static func makeModel(_ options: LaunchOptions) -> AppModel {
        let network = LaunchNetwork.choose(options, isDebugBuild: AppModel.isDebugBuild)
        if network == .internet {
            return AppModel(options: options, catalogClient: TCGCSVClient(), archiveClient: ArchiveClient(),
                            fetcher: URLSessionFetcher())
        }
        #if DEBUG
        // `-fixtures <dir>`: the UI tests run the app on files, never on the network.
        if case .fixtures(let fixtures) = network {
            let catalog = FileCatalogClient(directory: fixtures, productsDelay: .milliseconds(options.fixtureDelay ?? 0))
            let fetcher = FileFetcher(directory: fixtures, picturesDelay: .milliseconds(options.pictureDelay ?? 0))
            return AppModel(options: options, catalogClient: catalog,
                            archiveClient: FileArchiveClient(
                                directory: fixtures, delay: .milliseconds(options.fixtureDelay ?? 0),
                                requestLog: options.storeRoot?.appending(path: "fixture-archive-requests.txt")),
                            fetcher: fetcher)
        }
        #endif
        // A `-fixtures` that cannot be honoured (and, in a build without the fixture network, any `-fixtures`): offline.
        if case .offline(let notice) = network { FileHandle.standardOutput.write(Data((notice + "\n").utf8)) }
        var offline = options
        offline.offline = true
        return AppModel(options: offline, catalogClient: NoNetwork(), archiveClient: NoNetwork(), fetcher: NoNetwork())
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    // Always dark. The accent reaches the system's selection, the default button and focus rings through
                    // the app's `AccentColor` asset (Theme.accent): on macOS 27 a `.tint` here does not reach the
                    // sidebar's selection, and it colours the label of every other button and the game picker.
                    .preferredColorScheme(.dark)
                    #if DEBUG && os(macOS)
                    .testWindowPlacement(model.options)
                    #endif
                    .task {
                        #if os(macOS)
                        appDelegate.library = model.library
                        #endif
                        // Every window calls it; the model runs the sync once, and a closing window does not stop it.
                        await model.start()
                        #if DEBUG
                        if model.options.catalogReport { await Self.printCatalogReport(model) }
                        #endif
                    }
                    .task {
                        #if DEBUG && os(macOS)
                        await DebugSnapshot.runIfAsked(model.options)
                        #endif
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let model else { return }
            #if os(iOS)
            switch phase {
            case .background:
                // A64: iOS gives the app extra time for the flush and suspends it once the task ends. The task begins here,
                // in this turn, before any hop (Task 1B); it ends when the flush ends, or when the time runs out first (the
                // change may then be lost; the next launch reads the file).
                let session = Self.beginBackgroundSave()
                // A64, Task 1B: nothing downloads in the background: the sync and the 90-day download are cancelled (no
                // failure) and go on when the app is active again.
                model.sceneWentToBackground()
                let library = model.library
                Task {
                    await library.flush()
                    session.finish()
                }
            case .active:
                model.sceneBecameActive()
            default:
                break
            }
            #else
            // A change made just before the app goes away is written now. (The Mac waits in AppDelegate.)
            guard phase == .background else { return }
            let library = model.library
            Task { await library.flush() }
            #endif
        }
        .commands {
            CommandGroup(after: .appSettings) {
                // While the first-run question is open, it closes first (`askForFolder`).
                Button("Collection Folder…") { model?.askForFolder() }
                    .disabled(model == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Import CSV…") { model?.chooseCSVFile() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model == nil)
            }
        }
        #if os(macOS)
        // G10: the Settings window (Cmd+,), one pane "Games" (the window's title stays "Settings"). The system draws the
        // selected pane's tab in the app's accent (`AccentColor`); a `.tint` here does not reach it. No model yet (the
        // unit tests' host): nothing. Not resizable: the pane has a fixed width and its own height.
        Settings {
            if let model {
                TabView {
                    Tab("Games", systemImage: "square.stack") {
                        GamesSettingsPane()
                            .navigationTitle("Settings")
                    }
                }
                .environment(model)
                .preferredColorScheme(.dark)
            }
        }
        .windowResizability(.contentSize)
        #endif
    }

    #if os(iOS)
    /// A background task named "Saving your collection" around the library's flush (A64), begun synchronously. Both
    /// closures run on the main actor: `begin` runs `start` at once on its caller's, and iOS calls the expiration handler
    /// on the main thread.
    private static func beginBackgroundSave() -> BackgroundSave.Session {
        // A65: a line when the task begins, when its time runs out, and when it ends (with its length).
        let began = ContinuousClock.now
        return BackgroundSave.begin(
            start: { expiration in
                MainActor.assumeIsolated {
                    StepLog.note(.backgroundSaveStart)
                    return UIApplication.shared.beginBackgroundTask(withName: "Saving your collection", expirationHandler: {
                        StepLog.note(.backgroundSaveExpired)
                        expiration()
                    })
                }
            },
            end: { task in
                // `finish` is called on the main actor (the flush's task inherits it); the expiration handler too.
                MainActor.assumeIsolated {
                    UIApplication.shared.endBackgroundTask(task)
                    StepLog.note(.backgroundSaveEnd(seconds: StepLog.seconds(ContinuousClock.now - began)))
                }
            })
    }
    #endif

    #if DEBUG
    /// `-catalogReport YES`: the report goes to standard output, then the app quits.
    private static func printCatalogReport(_ model: AppModel) async {
        let text: String
        do {
            text = try await CatalogReport.text(store: model.reader, prices: model.prices.allGames, ygo: model.ygoIndex)
                + "\n" + DeckReport.text(model: model)
                + "\n" + SetReport.text(model: model)
                + "\n" + HistoryReport.text(model: model)
        } catch {
            text = "catalog report failed: \(error)\n"
        }
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }
    #endif
}

#if os(macOS)
/// Quitting waits until every queued write of the user files is done (at most 10 s), so the last change reaches the file.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var library: UserLibrary?
    /// True from the first answer to a `.terminateLater` until the app quits: it is answered once.
    private var answered = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library, library.hasPendingWork else { return .terminateNow }
        answered = false
        Task {
            await library.flush()
            answer(sender)
        }
        // A write that hangs (a coordinated write waiting for iCloud) must not keep the app from quitting.
        Task {
            try? await Task.sleep(for: .seconds(10))
            answer(sender)
        }
        return .terminateLater
    }

    private func answer(_ sender: NSApplication) {
        guard !answered else { return }
        answered = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
#endif
