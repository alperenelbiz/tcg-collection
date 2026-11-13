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
/// saved frame.
private struct WindowPlacer: NSViewRepresentable {
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
            guard let primary = NSScreen.screens.first else { return }
            window.setFrame(TestWindow.frame(on: primary), display: true)
        }
    }
}
#endif
