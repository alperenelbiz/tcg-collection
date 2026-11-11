import SwiftUI

@main
struct TCGCollectionApp: App {
    @State private var model: AppModel?

    init() {
        // The unit tests run inside the app. There the app makes no model: no store is opened and
        // nothing is downloaded; the tests make their own models with fakes.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        _model = State(initialValue: AppModel(options: LaunchOptions(arguments: CommandLine.arguments),
                                              catalogClient: TCGCSVClient(), archiveClient: ArchiveClient(),
                                              fetcher: URLSessionFetcher()))
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .task { await model.start() }
                    .task {
                        #if DEBUG && os(macOS)
                        await DebugSnapshot.runIfAsked(model.options)
                        #endif
                    }
            }
        }
    }
}
