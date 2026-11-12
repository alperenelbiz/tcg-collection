import XCTest

/// The new catalog rules on a copy of a real store. Skipped unless the environment has `TCG_REAL_STORE`: the absolute
/// path of a store root that holds `support/catalog.store`. `TCG_REAL_STORE=<root> scripts/ui-test.sh <dir>` forwards
/// it to the test runner (`TEST_RUNNER_TCG_REAL_STORE`). The app runs offline on that root, without fixtures, and the
/// root stays after the test. Never give it the installed app's own folder: give it a copy.
final class RealCatalogTests: UITestCase {
    /// Magic: the Type menu (A4) and "erase" (A3, a bracket that is part of the official name). Yu-Gi-Oh!: "power bond"
    /// (A3, the Skill Card is a card of its own).
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
        let titles = Set(typeMenu.menuItems.allElementsBoundByIndex.map { $0.title.isEmpty ? $0.label : $0.title })
        XCTContext.runActivity(named: "Type menu: \(titles.sorted())") { _ in
            XCTAssertLessThanOrEqual(titles.subtracting(["All"]).count, 15)
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
        app.searchFields.firstMatch.typeText("power bond")
        let bond = ["card-cell-power bond", "card-cell-power bond skill card"]
        XCTAssertTrue(waitUntil(timeout: 15) { bond.allSatisfy { self.element(app, $0).exists } }, "\(identifiers(cells))")
        shot("real-03-yugioh-power-bond")
    }

    /// `TCG_REAL_STORE`, or a skip when it is not set. A root with no catalog store fails before the app starts: the
    /// app would make an empty store there.
    private func realStoreRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TCG_REAL_STORE"], !path.isEmpty else {
            throw XCTSkip("TCG_REAL_STORE is not set: this test runs only on a copy of a real store")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let store = root.appending(path: "support/catalog.store")
        guard FileManager.default.fileExists(atPath: store.path) else {
            return try XCTUnwrap(nil, "TCG_REAL_STORE has no catalog store: \(store.path)")
        }
        return root
    }
}
