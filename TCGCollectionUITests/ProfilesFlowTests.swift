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

    // MARK: Roles (task 3: G7–G9)

    private var title: String { XCUIApplication(bundleIdentifier: Self.debugBundleID).windows.firstMatch.title }

    /// A Riftbound file: one deck `rb1` "Wind" (2 Dockside Lock-Up, none owned), active or not, with `profile`.
    private static func riftboundDeck(active: Bool = true, profile: String) -> String {
        """
        {"version": 1, "collection": [],
         "decks": [{"id": "rb1", "name": "Wind", "format": "standard", "active": \(active),
                    "cards": [{"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 2}]}],
         "profile": \(profile)}
        """
    }

    /// G7: the player role off. No Decks section in the sidebar, Wanted without the deck's missing card (empty), and a card
    /// page without "Decks" and "Add to deck". Another device turns the role on: the section, the card page's block and
    /// the Wanted cell with "2 for decks" come back from the file.
    func testPlayerOffHidesDecksEverywhere() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "wanted"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.riftboundDeck(profile: #"{"player": false}"#))
        }
        XCTAssertTrue(element(app, "wanted-search-catalog").waitForExistence(timeout: 20), "Wanted is not empty")
        XCTAssertTrue(waitUntilSynced(app), text(app.staticTexts["status-line"]))
        XCTAssertFalse(app.buttons["wanted-cell-dockside lock up"].exists)
        XCTAssertFalse(element(app, "sidebar-deck-rb1").exists)
        XCTAssertFalse(element(app, "sidebar-new-deck").exists)
        XCTAssertFalse(app.staticTexts["Decks"].exists, "a Decks heading in the sidebar")
        XCTAssertTrue(element(app, "sidebar-sets").exists, "the collector role is on")
        shot("profiles-04-player-off-wanted")

        element(app, "sidebar-all-cards").click()
        let card = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.click()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "wanted-value").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "card-add-to-deck").exists)
        XCTAssertFalse(element(app, "deck-line-rb1-main").exists)
        XCTAssertFalse(element(app, "wanted-for-decks").exists)
        XCTAssertFalse(app.staticTexts["Decks"].exists, "a Decks heading on the card page or in the sidebar")
        shot("profiles-05-player-off-card-page")

        try changeUserFile(game: "riftbound", json: Self.riftboundDeck(profile: #"{"player": true}"#))
        XCTAssertTrue(element(app, "card-add-to-deck").waitForExistence(timeout: 10), "the card page's Decks block")
        XCTAssertTrue(element(app, "sidebar-deck-rb1").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "deck-line-rb1-main").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "wanted-for-decks").waitForExistence(timeout: 10))
        XCTAssertEqual(text(element(app, "wanted-for-decks")), "+ 2 for decks")
        shot("profiles-06-player-on-card-page")
        element(app, "sidebar-wanted").click()
        let cell = app.buttons["wanted-cell-dockside lock up"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { cell.label == "Dockside Lock-Up, ×2, 2 for decks, $5.12" }, cell.label)
        shot("profiles-07-player-on-wanted")
    }

    /// G8: the collector role off. No Sets row; the arrow keys go from For Sale to the next row (no deck in the file:
    /// "New Deck…" is not selectable, so All cards).
    func testCollectorOffHidesSets() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { _ in
            try self.writeUserFile(game: "riftbound", json: #"{"version": 1, "collection": [], "profile": {"collector": false}}"#)
        }
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "sidebar-sets").exists)
        XCTAssertTrue(element(app, "sidebar-new-deck").exists, "the player role is on")
        element(app, "sidebar-collection").click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "wanted-screen").waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-wanted")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "for-sale-screen").waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-for-sale")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-all-cards")
        XCTAssertFalse(element(app, "sets-screen").exists)
        shot("profiles-08-collector-off-arrow-to-all-cards")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "for-sale-screen").waitForExistence(timeout: 10))
    }

    /// Review Focus 3: on a deck page, another device turns the player role off: the Collection shows (no crash), the deck
    /// row goes, and the deck is still in the file. Then on a set's page, the collector role turned off: the Collection.
    func testARoleTurnedOffElsewhereLeavesItsScreen() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb1"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.riftboundDeck(active: false, profile: "{}"))
        }
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Wind") }, title)
        try changeUserFile(game: "riftbound", json: Self.riftboundDeck(active: false, profile: #"{"player": false}"#))
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Collection") }, title)
        XCTAssertTrue(waitUntil { !self.element(app, "sidebar-deck-rb1").exists })
        XCTAssertFalse(element(app, "deck-screen").exists)
        XCTAssertEqual(app.state, .runningForeground)
        shot("profiles-09-player-off-elsewhere")
        let stored = try XCTUnwrap(storedUserFile(game: "riftbound"))
        XCTAssertEqual((stored["decks"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["rb1"])

        element(app, "sidebar-sets").click()
        let radiance = app.buttons["sets-row-24819"]
        XCTAssertTrue(radiance.waitForExistence(timeout: 30))
        radiance.click()
        XCTAssertTrue(element(app, "set-screen").waitForExistence(timeout: 10))
        try changeUserFile(game: "riftbound", json: Self.riftboundDeck(active: false, profile: #"{"player": false, "collector": false}"#))
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { !self.element(app, "sidebar-sets").exists })
        XCTAssertFalse(element(app, "set-screen").exists)
        XCTAssertEqual(app.state, .runningForeground)
        shot("profiles-10-collector-off-elsewhere")
    }
}
