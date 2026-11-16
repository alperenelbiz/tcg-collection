import XCTest

/// Phase 4B: the games the user follows (G3–G5), on the fixture catalog. The profiles are written into the game files
/// before the launch (`writeUserFile`) or while the app runs, as another device (`changeUserFile`).
final class ProfilesFlowTests: UITestCase {
    /// A game file that turns the game off (G1).
    private static let notFollowed = #"{"version":1,"collection":[],"profile":{"followed":false}}"#

    /// G4, G5: Yu-Gi-Oh! is not followed. The game picker lists the other three in the games' order; their catalogs are
    /// downloaded (the sync ends up to date); All cards of another followed game shows its cards.
    func testAGameThatIsNotFollowedIsNotInThePicker() throws {
        let app = try launch(game: "riftbound") { _ in try self.writeUserFile(game: "yu-gi-oh", json: Self.notFollowed) }
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app), text(app.staticTexts["status-line"]))
        let picker = element(app, "game-picker")
        XCTAssertEqual(picker.value as? String, "Riftbound")
        picker.click()
        XCTAssertTrue(app.menuItems["Cyberpunk TCG"].firstMatch.waitForExistence(timeout: 5))
        shot("profiles-01-picker-without-yugioh")
        // The picker's own menu (not the menu bar's); an open menu may list its items twice: the first of each, in order.
        let items = picker.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
        var seen: [String] = []
        for item in items where !seen.contains(item) { seen.append(item) }
        XCTAssertEqual(seen, ["Magic: The Gathering", "Riftbound", "Cyberpunk TCG"], "\(items)")
        XCTAssertFalse(app.menuItems["Yu-Gi-Oh!"].firstMatch.exists)
        app.menuItems["Cyberpunk TCG"].firstMatch.click()
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasPrefix("Cyberpunk TCG") }, app.windows.firstMatch.title)
        XCTAssertTrue(element(app, "card-cell-kerry eurodyne the last rockerboy").waitForExistence(timeout: 10))
        shot("profiles-02-cyberpunk-all-cards")
    }

    /// G4: the game on screen (Riftbound, on All cards) is turned off by another device while the app runs: the first
    /// followed game (Magic) is shown on its Collection, the picker no longer lists Riftbound, and nothing crashes.
    func testTheGameOnScreenTurnedOffElsewhereShowsTheFirstFollowedGame() throws {
        let app = launch(game: "riftbound")
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        let picker = element(app, "game-picker")
        XCTAssertEqual(picker.value as? String, "Riftbound")
        try changeUserFile(game: "riftbound", json: Self.notFollowed)
        XCTAssertTrue(waitUntil { picker.value as? String == "Magic: The Gathering" }, String(describing: picker.value))
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasPrefix("Collection") }, app.windows.firstMatch.title)
        shot("profiles-03-turned-off-elsewhere")
        picker.click()
        XCTAssertTrue(app.menuItems["Cyberpunk TCG"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Riftbound"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(app.state, .runningForeground)
        // The file another device wrote is not rewritten by the app.
        let stored = try XCTUnwrap(storedUserFile(game: "riftbound"))
        XCTAssertEqual(stored["profile"] as? [String: Bool], ["followed": false])
    }
}
