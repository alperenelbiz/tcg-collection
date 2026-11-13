import AppKit
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
        shot(name, of: app.windows.firstMatch)
    }

    /// A picture of one element (a sheet, which can reach past the window's edge), kept as the attachment `name`.
    func shot(_ name: String, of element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
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

    /// Every cell of the Collection's gallery (`collection-cell-<productID>-<finish>`).
    func collectionCells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'collection-cell-'"))
    }

    /// The identifiers of the elements of `query`, sorted.
    func identifiers(_ query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.map(\.identifier).sorted()
    }

    /// The identifiers of the elements of `query` in reading order: by row, then left to right.
    func identifiersInOrder(_ query: XCUIElementQuery) -> [String] {
        let placed: [(frame: CGRect, id: String)] = query.allElementsBoundByIndex.map { ($0.frame, $0.identifier) }
        let ordered = placed.sorted { (a: (frame: CGRect, id: String), b: (frame: CGRect, id: String)) -> Bool in
            let sameRow = abs(a.frame.minY - b.frame.minY) <= 1
            return sameRow ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
        }
        return ordered.map(\.id)
    }

    /// The `.searchable` field: SwiftUI gives it no identifier of ours on macOS, so it is found by type.
    func searchField(_ app: XCUIApplication) -> XCUIElement {
        app.searchFields.firstMatch
    }

    /// The whole fixture sync has ended (every game, prices, the Yu-Gi-Oh! index).
    func waitUntilSynced(_ app: XCUIApplication) -> Bool {
        let status = app.staticTexts["status-line"]
        return waitUntil(timeout: 20) { status.exists && self.text(status).hasPrefix("Catalog up to date") }
    }

    // MARK: The user folder

    /// One row of a game's collection file, as the app writes it (`CollectionRow`).
    struct StoredRow: Equatable {
        var productID: Int
        var finish: String
        var count: Int
        var condition = ""
        var name: String
    }

    /// Writes `<root>/user/<game>.json` in the form the app keeps a game's collection in (`GameUserFile`):
    /// `{"version": 1, "collection": [rows]}`. For `launch(prepare:)`, before the app starts. The UI test target cannot
    /// import the app module, so the JSON is written here by hand.
    func writeCollection(_ rows: [StoredRow], game: String, in root: URL) throws {
        let folder = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let collection = rows.map { ["productID": $0.productID, "finish": $0.finish, "count": $0.count,
                                     "condition": $0.condition, "name": $0.name] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "collection": collection], options: [.sortedKeys])
        try data.write(to: folder.appending(path: "\(game).json"))
    }

    /// Writes `json` as `<root>/user/<game>.json` of the running test's root, as it is: a whole game file (the lists of
    /// phase 2C, a version this app refuses). For `launch(prepare:)`, before the app starts.
    func writeUserFile(game: String, json: String) throws {
        let folder = try XCTUnwrap(root).appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "\(game).json"))
    }

    /// `<root>/user/<game>.json` of the running test's root as the app last wrote it, as a JSON object; nil with no file.
    func storedUserFile(game: String) throws -> [String: Any]? {
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "\(game).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], "not an object: \(file.path)")
    }

    /// The rows of `<root>/user/<game>.json` of the running test's root, as the app last wrote them; [] with no file.
    func storedCollection(game: String) throws -> [StoredRow] {
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "\(game).json")
        guard let object = try storedUserFile(game: game) else { return [] }
        let rows = try XCTUnwrap(object["collection"] as? [[String: Any]], "no collection array in \(file.path)")
        return try rows.map { row in
            StoredRow(productID: try XCTUnwrap(row["productID"] as? Int), finish: try XCTUnwrap(row["finish"] as? String),
                      count: try XCTUnwrap(row["count"] as? Int), condition: row["condition"] as? String ?? "",
                      name: row["name"] as? String ?? "")
        }
    }

    /// Quits the app as a person does (Cmd+Q: the app's own quit, which waits for queued writes; `terminate()` is a kill)
    /// and waits until it has ended.
    func quit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "the app did not quit on Cmd+Q", file: file, line: line)
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

    /// Fails unless the sidebar row `identifier` is drawn on the accent fill (#F2B33D): the window's pixel 180 pt from its
    /// left edge, in the row's middle, right of the row's title. The system's own selection there is grey without focus
    /// and blue with a system accent of its own. Polls for 3 s, so a selection animation can end.
    func assertAccentFill(_ app: XCUIApplication, row identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        let row = element(app, identifier)
        var seen: (red: Double, green: Double, blue: Double)?
        let amber = waitUntil(timeout: 3) {
            seen = pixel(of: window, at: CGPoint(x: window.frame.minX + 180, y: row.frame.midY))
            guard let c = seen else { return false }
            return c.red > 0.75 && c.green > 0.5 && c.green < 0.8 && c.blue < 0.35
        }
        XCTAssertTrue(amber, "\(identifier) is not on the accent fill: \(seen.map { "\($0)" } ?? "no pixel")", file: file, line: line)
    }

    /// The colour of one point (screen coordinates, as `XCUIElement.frame`) of a window picture, in sRGB.
    func pixel(of window: XCUIElement, at point: CGPoint) -> (red: Double, green: Double, blue: Double)? {
        let frame = window.frame
        guard frame.contains(point),
              let image = window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = Double(image.width) / frame.width
        let rep = NSBitmapImageRep(cgImage: image)       // pixel origin at the top left, as the screen coordinates
        guard let color = rep.colorAt(x: Int((point.x - frame.minX) * scale), y: Int((point.y - frame.minY) * scale))?
            .usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent)
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
