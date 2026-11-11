import SwiftUI

@main
struct TCGCollectionApp: App {
    private let options = LaunchOptions(arguments: CommandLine.arguments)

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG && os(macOS)
                    await DebugSnapshot.runIfAsked(options)
                    #endif
                }
        }
    }
}
