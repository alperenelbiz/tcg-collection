import XCTest

/// The new catalog rules on a copy of a real store. Skipped unless the environment has `TCG_REAL_STORE`: the absolute
/// path of a store root that holds `support/catalog.store`. `TCG_REAL_STORE=<root> scripts/ui-test.sh <dir>` forwards
/// it to the test runner (`TEST_RUNNER_TCG_REAL_STORE`). The app runs offline on that root, without fixtures, and the
/// root stays after the test. Never give it the installed app's own folder: give it a copy.
final class RealCatalogTests: UITestCase {
    /// Magic: the Type menu (A4) and "erase" (A3, a bracket that is part of the official name). Yu-Gi-Oh!: "call of the
    /// haunted" (A3, a printing named `… (Skill Card)` is a card of its own). Not Power Bond: its Skill printings are
    /// named `Power Bond`, with no bracket; A5 (rules version 3) separates them by their card type, but only in sets
    /// stored under version 3, and a copy run offline keeps the version its sets were stored with.
    func testTheNewRulesOnTheRealCatalog() throws {
        let app = launch(storeRoot: try realStoreRoot(), game: "magic-the-gathering")
        let cells = cardCells(app)
        XCTAssertTrue(waitUntil(timeout: 30) { cells.count > 0 }, "no Magic card in the gallery")

        // The Type menu first: with the search field active, the toolbar moves it into the overflow.
        let typeMenu = element(app, "filter-type")
        XCTAssertTrue(typeMenu.waitForExistence(timeout: 10))
        typeMenu.click()
        XCTAssertTrue(app.menuItems["Creature"].firstMatch.waitForExistence(timeout: 5), "no Creature in the Type menu")
        shot("real-01-magic-type-menu")
        // The menu's items as XCUITest lists them: an untitled one, the section title "Type", "All", then the values.
        let titles = Set(typeMenu.menuItems.allElementsBoundByIndex.map { $0.title.isEmpty ? $0.label : $0.title })
        let values = titles.subtracting(["", "Type", "All"])
        XCTContext.runActivity(named: "Type menu: \(titles.sorted())") { _ in
            XCTAssertFalse(values.isEmpty, "no type in the Type menu")
            XCTAssertTrue(values.isSubset(of: Self.magicTypes), "not a card type: \(values.subtracting(Self.magicTypes).sorted())")
            XCTAssertFalse(app.menuItems["Summon"].firstMatch.exists, "an old type-line word is in the Type menu")
        }
        app.menuItems["All"].firstMatch.click()

        // The search matches a part of a word, so other cards (such as Sharp Eraser) may show too.
        app.searchFields.firstMatch.click()
        app.searchFields.firstMatch.typeText("erase")
        let erase = ["card-cell-erase", "card-cell-erase not the urza s legacy one"]
        XCTAssertTrue(waitUntil(timeout: 15) { erase.allSatisfy { self.element(app, $0).exists } }, "\(identifiers(cells))")
        shot("real-02-magic-erase")

        element(app, "game-picker").click()
        XCTAssertTrue(app.menuItems["Yu-Gi-Oh!"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["Yu-Gi-Oh!"].firstMatch.click()
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasPrefix("Yu-Gi-Oh!") }, app.windows.firstMatch.title)
        app.searchFields.firstMatch.click()
        app.searchFields.firstMatch.typeText("call of the haunted")
        let haunted = ["card-cell-call of the haunted", "card-cell-call of the haunted skill card"]
        XCTAssertTrue(waitUntil(timeout: 15) { haunted.allSatisfy { self.element(app, $0).exists } }, "\(identifiers(cells))")
        shot("real-03-yugioh-call-of-the-haunted")
    }

    /// The 15 Magic card types of P7 (`MagicTypes.all` in the app, which a UI test cannot import).
    private static let magicTypes: Set<String> = [
        "Artifact", "Battle", "Conspiracy", "Creature", "Dungeon", "Enchantment", "Instant", "Kindred", "Land",
        "Phenomenon", "Plane", "Planeswalker", "Scheme", "Sorcery", "Vanguard",
    ]
}

extension UITestCase {
    /// `TCG_REAL_STORE`, or a skip when it is not set. A root under `~/Library` (the app's own folders, iCloud Drive in
    /// `~/Library/Mobile Documents`) fails before the app starts: the app writes into its root, and a test must have a
    /// scratch copy. So does a root with no catalog store: the app would make an empty store there. Also used by
    /// `RealCollectionTests`.
    func realStoreRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TCG_REAL_STORE"], !path.isEmpty else {
            throw XCTSkip("TCG_REAL_STORE is not set: this test runs only on a copy of a real store")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let library = Self.realHome.appending(path: "Library", directoryHint: .isDirectory)
        guard !Self.isInside(root, library) else {
            return try XCTUnwrap(nil, "TCG_REAL_STORE is under ~/Library or ~/Library/Mobile Documents (\(root.path)): "
                                 + "give a scratch copy of a store root, never the app's own folder or iCloud Drive")
        }
        let store = root.appending(path: "support/catalog.store")
        guard FileManager.default.fileExists(atPath: store.path) else {
            return try XCTUnwrap(nil, "TCG_REAL_STORE has no catalog store: \(store.path)")
        }
        return root
    }

    /// The user's own home folder. The test runner is sandboxed: its `NSHomeDirectory()` is its container, not the home
    /// whose `Library` holds the app's folders and iCloud Drive.
    private static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    /// `url` is `folder` or inside it, after symbolic links are resolved; letter case does not count (APFS ignores it).
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        return parts.starts(with: base)
    }
}
