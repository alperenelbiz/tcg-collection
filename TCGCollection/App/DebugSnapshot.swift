#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// `-snapshot <file.png>`: a few seconds after launch, writes a picture of the window (title bar
/// and toolbar included) and quits. It lets a build be checked without screen recording.
/// Every flag needs a value: macOS takes a lone trailing argument as a file to open and shows no window.
/// The sidebar is drawn with vibrancy, which a view capture leaves out; in a snapshot run it
/// uses the plain list style instead (`capturableSidebar`).
enum DebugSnapshot {
    static func runIfAsked(_ options: LaunchOptions) async {
        guard let url = options.snapshot else { return }
        NSApp.activate()
        try? await Task.sleep(for: .seconds(5))
        if let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        NSApp.terminate(nil)
    }
}

extension View {
    @ViewBuilder func capturableSidebar() -> some View {
        if LaunchOptions(arguments: CommandLine.arguments).snapshot != nil { listStyle(.inset) } else { self }
    }
}
#endif
