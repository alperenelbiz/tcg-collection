import SwiftUI

@main
struct TCGCollectionApp: App {
    @State private var model: AppModel?

    init() {
        // The unit tests run inside the app. There the app makes no model: no store is opened and
        // nothing is downloaded; the tests make their own models with fakes.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        _model = State(initialValue: Self.makeModel(LaunchOptions(arguments: CommandLine.arguments)))
    }

    private static func makeModel(_ options: LaunchOptions) -> AppModel {
        #if DEBUG
        // `-fixtures <dir>`: the UI tests run the app on files, never on the network.
        if let fixtures = options.fixtures {
            // Fixture data goes only into a store of its own, never into the default one.
            if options.storeRoot != nil {
                return AppModel(options: options, catalogClient: FileCatalogClient(directory: fixtures),
                                archiveClient: FileArchiveClient(directory: fixtures), fetcher: FileFetcher(directory: fixtures))
            }
            FileHandle.standardOutput.write(Data("-fixtures is ignored: it needs -store <dir>\n".utf8))
        }
        #endif
        return AppModel(options: options, catalogClient: TCGCSVClient(), archiveClient: ArchiveClient(),
                        fetcher: URLSessionFetcher())
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .task {
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
