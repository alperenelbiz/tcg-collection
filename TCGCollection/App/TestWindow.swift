#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// A Debug run with `-store` (the UI tests, scratch runs): every window opens 900 × 450 pt in the middle of the primary
/// display (the one at the origin, with the menu bar), whatever frame macOS saved for the Debug app, and saves none. So a
/// UI test's window has the same size and display on every Mac and every display arrangement. Measured 2026-11-13 with
/// two displays: a window picture (`XCUIElement.screenshot()`) of the same build and run failed on the second display
/// (the built-in one, beside an external main display) and worked on the primary one.
enum TestWindow {
    static let size = CGSize(width: 900, height: 450)

    /// From the app's init, before AppKit restores windows: a `-store` run ignores the windows an earlier run saved. In
    /// memory only (the registration domain); no preference is written. Observed 2026-11-13: saved state whose window group
    /// no longer existed restored no window, and SwiftUI then opened none, in every later launch.
    static func ignoreSavedWindows(_ options: LaunchOptions) {
        guard options.storeRoot != nil else { return }
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    /// The frame on the primary display, centered in its visible part.
    static func frame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}

extension View {
    /// `TestWindow` placement in a Debug run with `-store`; nothing otherwise.
    @ViewBuilder func testWindowPlacement(_ options: LaunchOptions) -> some View {
        if options.storeRoot != nil { background(WindowPlacer()) } else { self }
    }
}

/// Places its window once, on the next turn of the main loop after it joined the window: after SwiftUI has applied the
/// saved frame. Not `private`: the window group's identity is made from its content's type name, and a private type's
/// name holds an address that changes at every launch ("unknown context at $…"), which gave the window a new identity
/// (and a new saved-frame key) at every launch.
struct WindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PlacingView: NSView {
    private var placed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !placed else { return }
        placed = true
        DispatchQueue.main.async {
            window.setFrameAutosaveName("")
            // A test run saves no window for a later launch to restore.
            window.isRestorable = false
            guard let primary = NSScreen.screens.first else { return }
            window.setFrame(TestWindow.frame(on: primary), display: true)
        }
    }
}
#endif
