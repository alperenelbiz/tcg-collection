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
                    .task {
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
    }

    #if DEBUG
    /// `-catalogReport YES`: the report goes to standard output, then the app quits.
    private static func printCatalogReport(_ model: AppModel) async {
        let text: String
        do {
            text = try await CatalogReport.text(store: model.reader, prices: model.prices.allGames, ygo: model.ygoIndex)
        } catch {
            text = "catalog report failed: \(error)\n"
        }
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }
    #endif
}
