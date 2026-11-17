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
    /// fresh root before the app starts, to put files into it (`writeCollection`). `fixtures` names another fixtures
    /// folder from the root (a copy that `prepare` made, as the Mac's `SetsFlowTests`), instead of the bundle's.
    @discardableResult
    func launch(game: String = "riftbound", extra: [String] = [], fixtures: ((URL) -> URL)? = nil,
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
        let served = fixtures?(root) ?? Self.fixturesDirectory
        app.launchArguments = ["-store", root.path, "-fixtures", served.path, "-game", game] + extra
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

    // MARK: Prices and the price history (copies of the Mac's `UITestCase`, phase 6A task 6)

    /// Writes the test's own price files into `<root>/support` before the launch, for every game, with a day far ahead:
    /// the price step then has that day and downloads nothing, so no day file is written. Yu-Gi-Oh!: Swiftwind Panther
    /// Warrior 719834 (Super Rare) 1st Edition $14.50, Unlimited $9.00; 719835 (Starlight Rare) 1st Edition $3.10. The
    /// other games have none. With `longFinish`, 719834 also has a made-up "1st Edition Holofoil" line without a shown
    /// price ("No price"). A copy of the Mac's `UITestCase.writePinPrices`.
    func writePinPrices(in root: URL, longFinish: Bool = false) throws {
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let none = #"{"day": "2099-12-31", "finishes": [], "rows": {}}"#
        let long = longFinish ? #", "2": {"mid": 50}"# : ""
        let yugioh = """
        {"day": "2099-12-31", "finishes": ["1st Edition", "Unlimited"\(longFinish ? #", "1st Edition Holofoil""# : "")],
         "rows": {"719834": {"0": {"market": 14.5}, "1": {"market": 9}\(long)}, "719835": {"0": {"market": 3.1}}}}
        """
        for game in ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"] {
            try Data((game == "yu-gi-oh" ? yugioh : none).utf8).write(to: support.appending(path: "prices-\(game).json"))
        }
    }

    /// The archive day the app's history window ends on: yesterday (UTC) until 20:30 UTC, then today. A copy of
    /// `PriceDay.wanted(now:)`: the UI test target cannot import the app module.
    static func wantedDay(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let afterPublish = parts.hour! * 60 + parts.minute! >= 20 * 60 + 30
        return day(of: afterPublish ? now : now.addingTimeInterval(-86_400))
    }

    /// `day` (`yyyy-MM-dd`, UTC) moved by `days` days.
    static func day(_ day: String, movedBy days: Int) -> String {
        Self.day(of: noon(day).addingTimeInterval(Double(days) * 86_400))
    }

    /// `2026-10-03` → `Oct 3`, as the chart writes a day.
    static func dayLabel(_ day: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "MMM d"
        return formatter.string(from: noon(day))
    }

    private static func day(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func noon(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd HH"
        return formatter.date(from: day + " 12")!
    }

    /// Writes `<root>/user/<game>.prices.json` of the running test's root before the launch, in the app's form: one
    /// finish of one product, one price per day, the last on `day` (the test's `wantedDay()`) and the others on the days
    /// before it. A copy of the Mac's `UITestCase.writeHistory`.
    func writeHistory(game: String, productID: Int, finish: String, prices: [Double], endingOn day: String) throws {
        let days = (0..<prices.count).map { Self.day(day, movedBy: $0 - (prices.count - 1)) }
        let object: [String: Any] = ["days": days, "products": [String(productID): [finish: ["prices": prices]]],
                                     "version": 1]
        let folder = try XCTUnwrap(root).appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: folder.appending(path: "\(game).prices.json"))
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
