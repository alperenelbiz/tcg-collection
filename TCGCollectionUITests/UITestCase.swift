import XCTest

/// Starts the Debug app on a fresh temporary store and the fixture network, and keeps pictures of its window.
/// After every test, also a failed one, the app is terminated and the store root is removed.
@MainActor
class UITestCase: XCTestCase {
    /// The unit test fixtures, copied into this bundle as the folder `Fixtures`.
    static var fixturesDirectory: URL {
        let bundle = Bundle(for: UITestCase.self)
        return (bundle.resourceURL ?? bundle.bundleURL).appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    private var app: XCUIApplication?
    private var root: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
        if let root {
            try? FileManager.default.removeItem(at: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "the store root is left: \(root.path)")
        }
        app = nil
        root = nil
        try await super.tearDown()
    }

    /// Launches the app with `-store <fresh root>`, `-fixtures <Fixtures>` (unless `fixtures` is false) and `-game`.
    func launch(game: String? = nil, extra: [String] = [], fixtures: Bool = true) -> XCUIApplication {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tcg-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        var arguments = ["-store", root.path]
        if fixtures { arguments += ["-fixtures", Self.fixturesDirectory.path] }
        if let game { arguments += ["-game", game] }
        let app = XCUIApplication()
        app.launchArguments = arguments + extra
        self.root = root
        self.app = app
        app.launch()
        return app
    }

    /// A picture of the app's window, kept in the result bundle as the attachment `name`.
    func shot(_ name: String) {
        guard let app else { return XCTFail("shot(\"\(name)\") before launch()") }
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The element with this accessibility identifier, whatever its type.
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Every gallery cell (`card-cell-<card key>`).
    func cardCells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'card-cell-'"))
    }

    /// The text a static text shows: macOS keeps it in `value`, or in `label`. A selectable text
    /// (`.textSelection(.enabled)`) is a wrapper that keeps its first value, around a static text that follows the
    /// view: the inner one is read.
    func text(_ element: XCUIElement) -> String {
        let inner = element.staticTexts.firstMatch
        let shown = inner.exists ? inner : element
        let value = shown.value as? String ?? ""
        return value.isEmpty ? shown.label : value
    }

    /// Polls `condition` until it holds or `timeout` seconds have passed; returns its last result.
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
