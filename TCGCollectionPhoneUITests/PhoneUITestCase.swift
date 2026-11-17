import XCTest

/// Starts the Debug app in the iOS Simulator on a fresh temporary store and the fixture network, and keeps pictures of
/// the screen. After every test, also a failed one, the app is terminated and the store root is removed.
///
/// The paths (phase 6A task 1, step 2): the app in the simulator reads the store root that this runner makes under its
/// own `NSTemporaryDirectory()` and the `Fixtures` folder inside this runner's bundle directly, by their absolute paths
/// (`-store <root> -fixtures <dir>`), as the Mac's `UITestCase` does. A simulator app's file access is not limited to
/// its own container, so no `-store temp:` flag and no fixtures bundled into the app are needed.
@MainActor
class PhoneUITestCase: XCTestCase {
    /// The unit test fixtures, copied into this bundle as the folder `Fixtures`.
    static var fixturesDirectory: URL {
        let bundle = Bundle(for: PhoneUITestCase.self)
        return (bundle.resourceURL ?? bundle.bundleURL).appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    /// The Debug app (project.yml). Only this app is launched, never a Release build.
    nonisolated static let debugBundleID = "com.alperenelbiz.tcgcollection2.debug"

    private(set) var app: XCUIApplication?
    /// The store root of the running test (`-store`).
    private(set) var root: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        #if !DEBUG
        // Outside Debug the app under test has no fixture network: stop before any launch.
        throw NotTheDebugApp()
        #endif
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

    /// Launches the app with `-store <fresh root> -fixtures <Fixtures> -game <game>`, then `extra`. `prepare` gets the
    /// fresh root before the app starts, to put files into it (`writeCollection`).
    @discardableResult
    func launch(game: String = "riftbound", extra: [String] = [],
                prepare: ((URL) throws -> Void)? = nil) -> XCUIApplication {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tcg-phone-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.root = root                                         // tearDown removes it, also when `prepare` fails
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try prepare?(root)
        } catch {
            XCTFail("the store root could not be prepared: \(error)")
        }
        let app = XCUIApplication(bundleIdentifier: Self.debugBundleID)
        app.launchArguments = ["-store", root.path, "-fixtures", Self.fixturesDirectory.path, "-game", game] + extra
        self.app = app
        app.launch()
        return app
    }

    /// A picture of the whole simulator screen, kept in the result bundle as the attachment `name`.
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The element with this accessibility identifier, whatever its type.
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// The text of a static text (its `value`; a selectable text keeps it in an inner static text), else its label.
    func text(_ element: XCUIElement) -> String {
        let inner = element.staticTexts.firstMatch
        let shown = inner.exists ? inner : element
        let value = shown.value as? String ?? ""
        return value.isEmpty ? shown.label : value
    }

    /// Writes `rows` as the collection of `<root>/user/<game>.json` of the running test's root (`{"version": 1,
    /// "collection": rows}`). Each row as the app stores it: `productID`, `finish`, `count`, `condition`, `name`. For
    /// `launch(prepare:)`, before the app starts.
    func writeCollection(_ rows: [[String: Any]], game: String) throws {
        let folder = try XCTUnwrap(root).appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "collection": rows], options: [.sortedKeys])
        try data.write(to: folder.appending(path: "\(game).json"))
    }

    /// Replaces `<root>/user/<game>.json` while the app runs, as another device's write does: a coordinated write (as the
    /// Mac's `UITestCase.changeUserFile`), so the app's file presenter reports it.
    func changeUserFile(game: String, json: String) throws {
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "\(game).json")
        var coordination: NSError?
        var writing: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordination) { url in
            do { try Data(json.utf8).write(to: url, options: .atomic) } catch { writing = error }
        }
        if let coordination { throw coordination }
        if let writing { throw writing }
    }

    /// Polls `condition` until it holds or `timeout` seconds pass.
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < end
        return condition()
    }
}

private struct NotTheDebugApp: LocalizedError {
    var errorDescription: String? {
        "The phone UI tests run only on the Debug app (\(PhoneUITestCase.debugBundleID)). "
            + "Run scripts/ui-test-phone.sh, which passes -configuration Debug."
    }
}
