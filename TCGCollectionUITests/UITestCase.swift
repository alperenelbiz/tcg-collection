import XCTest

/// Starts the Debug app on a fresh temporary store and the fixture network, and keeps pictures of its window.
/// After every test, also a failed one, the app is terminated and a fresh store root is removed. A root the test was
/// given (`launch(storeRoot:)`) is left as it is.
@MainActor
class UITestCase: XCTestCase {
    /// The unit test fixtures, copied into this bundle as the folder `Fixtures`.
    static var fixturesDirectory: URL {
        let bundle = Bundle(for: UITestCase.self)
        return (bundle.resourceURL ?? bundle.bundleURL).appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    /// The Debug app (project.yml). The tests launch, and XCUITest quits, only the app with this id: never the installed
    /// app, which is the Release build (`com.alperenelbiz.tcgcollection2`).
    nonisolated static let debugBundleID = "com.alperenelbiz.tcgcollection2.debug"

    private var app: XCUIApplication?
    /// The store root of the running test (`-store`).
    private(set) var root: URL?
    /// False when the root was given to `launch(storeRoot:)`: tearDown leaves it.
    private var removesRoot = true

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        #if !DEBUG
        // This bundle and the app under test are built in one configuration. Outside Debug the app under test is the
        // Release build, not the app with `debugBundleID`, and it has no fixture network: stop before any launch.
        throw NotTheDebugApp()
        #endif
    }

    override func tearDown() async throws {
        app?.terminate()
        if let root, removesRoot {
            try? FileManager.default.removeItem(at: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "the store root is left: \(root.path)")
        }
        app = nil
        root = nil
        removesRoot = true
        try await super.tearDown()
    }

    /// Launches the app with `-store <fresh root>`, `-fixtures <Fixtures>` (unless `fixtures` is false) and `-game`.
    /// Every launch opens on All cards (`-screen all-cards`, the catalog the phase 1 and 2A tests expect) unless `extra`
    /// names a `-screen` of its own.
    func launch(game: String? = nil, extra: [String] = [], fixtures: Bool = true) -> XCUIApplication {
        start(root: newRoot(), game: game, extra: extra, fixtures: fixtures)
    }

    /// As `launch`, with `prepare` getting the fresh root before the app starts, to put files into it.
    func launch(game: String? = nil, extra: [String] = [], fixtures: Bool = true,
                prepare: (URL) throws -> Void) throws -> XCUIApplication {
        let root = newRoot()
        self.root = root                                         // tearDown removes it, also when `prepare` fails
        try prepare(root)
        return start(root: root, game: game, extra: extra, fixtures: fixtures)
    }

    /// Launches the app on a store root that exists already, such as a copy of a real store: `-store <storeRoot>
    /// -offline YES`, no fixtures, and `-game`. `-offline YES` comes before `extra`, so `extra` cannot turn it off (the
    /// first value of a flag wins). tearDown leaves the root.
    func launch(storeRoot: URL, game: String? = nil, extra: [String] = []) -> XCUIApplication {
        removesRoot = false
        return start(root: storeRoot, game: game, extra: ["-offline", "YES"] + extra, fixtures: false)
    }

    private func newRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tcg-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func start(root: URL, game: String?, extra: [String], fixtures: Bool) -> XCUIApplication {
        var arguments = ["-store", root.path]
        if fixtures { arguments += ["-fixtures", Self.fixturesDirectory.path] }
        if let game { arguments += ["-game", game] }
        if !extra.contains("-screen") { arguments += ["-screen", "all-cards"] }
        let app = XCUIApplication(bundleIdentifier: Self.debugBundleID)
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

    /// The identifiers of the elements of `query`, sorted.
    func identifiers(_ query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.map(\.identifier).sorted()
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

/// `UITestCase.setUp` outside a Debug build: the app under test is not the Debug app.
private struct NotTheDebugApp: LocalizedError {
    var errorDescription: String? {
        "The UI tests run only on the Debug app (\(UITestCase.debugBundleID)). This run was built in another "
            + "configuration, whose app has the installed app's bundle id, so nothing is launched. "
            + "Run scripts/ui-test.sh, which passes -configuration Debug."
    }
}
