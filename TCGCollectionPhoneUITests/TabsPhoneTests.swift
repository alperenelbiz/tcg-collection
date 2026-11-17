import XCTest

/// Phase 6A task 2: the iPhone's tab bar, the game menu and the status line (A50, A54; Review Focus 1–3).
final class TabsPhoneTests: PhoneUITestCase {
    /// A tab of the tab bar by its title ("Collection", "Wanted", "Decks", "Sets"; the search tab is "Search").
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    /// Picks a game in the game menu of the tab on show.
    private func chooseGame(_ app: XCUIApplication, _ game: String) {
        let menu = element(app, "game-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no game menu")
        menu.tap()
        let item = app.buttons["game-menu-\(game)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no item for \(game)")
        item.tap()
    }

    private static let wantedFile = """
        {"collection": [], "version": 1, "wanted": [{"cardKey": "dockside lock up", "count": 1, "name": "Dockside Lock-Up"}]}
        """

    private static func profileFile(player: Bool) -> String {
        """
        {"collection": [], "profile": {"collector": true, "followed": true, "player": \(player)}, "version": 1}
        """
    }

    private func writeUserFile(_ json: String, game: String, root: URL) throws {
        let folder = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "\(game).json"))
    }

    /// The four tabs and the search button; the game menu lists the four games; Yu-Gi-Oh! shows its Collection.
    func testTheTabsAndTheGameMenu() {
        let app = launch()
        for title in ["Collection", "Wanted", "Decks", "Sets", "Search"] {
            XCTAssertTrue(tab(app, title).waitForExistence(timeout: 20), "no tab \(title)")
        }
        XCTAssertTrue(tab(app, "Collection").isSelected, "the Collection tab is not the first one shown")
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Collection")
        let menu = element(app, "game-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no game menu")
        XCTAssertTrue(menu.label.contains("Riftbound"), "game menu: \(menu.label)")
        XCTAssertTrue(element(app, "settings-button").exists, "no gear")
        menu.tap()
        for game in ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"] {
            XCTAssertTrue(app.buttons["game-menu-\(game)"].firstMatch.waitForExistence(timeout: 5), "no item \(game)")
        }
        shot("tabs-01")
        app.buttons["game-menu-yu-gi-oh"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.element(app, "game-menu").label.contains("Yu-Gi-Oh") },
                      "game menu: \(element(app, "game-menu").label)")
        XCTAssertTrue(tab(app, "Collection").isSelected)
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Yu-Gi-Oh! Collection")
        shot("tabs-02-yu-gi-oh")
    }

    /// Review Focus 1: Wanted → a card page → Collection → Wanted: the card page is still there.
    func testATabKeepsItsPage() throws {
        let app = launch(prepare: { root in try self.writeUserFile(Self.wantedFile, game: "riftbound", root: root) })
        XCTAssertTrue(tab(app, "Wanted").waitForExistence(timeout: 20))
        tab(app, "Wanted").tap()
        let cell = app.buttons["wanted-cell-dockside lock up"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "no Wanted cell")
        XCTAssertTrue(waitUntil(timeout: 30) { cell.isHittable }, "the Wanted cell is not hittable")
        cell.tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page")
        tab(app, "Collection").tap()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Collection")
        tab(app, "Wanted").tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "the card page of Wanted is gone")
        XCTAssertTrue(tab(app, "Wanted").isSelected)
        shot("tabs-03-kept-page")
    }

    /// Review Focus 2: the player role turned off (by another device's write) while the Decks tab is on show: the Decks
    /// tab goes and the Collection tab shows.
    func testARoleTurnedOffLeavesItsTab() throws {
        let app = launch(prepare: { root in
            try self.writeUserFile(Self.profileFile(player: true), game: "riftbound", root: root)
        })
        XCTAssertTrue(tab(app, "Decks").waitForExistence(timeout: 20), "no Decks tab")
        tab(app, "Decks").tap()
        XCTAssertTrue(element(app, "decks-screen").waitForExistence(timeout: 10), "no deck list")
        try changeUserFile(game: "riftbound", json: Self.profileFile(player: false))
        XCTAssertTrue(waitUntil(timeout: 20) { !self.tab(app, "Decks").exists }, "the Decks tab is still there")
        XCTAssertTrue(waitUntil(timeout: 10) { self.tab(app, "Collection").isSelected }, "the Collection tab is not shown")
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Collection")
        XCTAssertTrue(tab(app, "Sets").exists, "the Sets tab went too")
        shot("tabs-04-role-off")
    }

    /// Review Focus 3: a card page open in Collection, the game switched (from Wanted's game menu) and back: every tab of
    /// the old game starts afresh, so the Collection is at its root.
    func testAGameSwitchStartsEveryTabAfresh() throws {
        let app = launch(prepare: { _ in
            try self.writeCollection([["productID": 721334, "finish": "Normal", "count": 1, "condition": "",
                                       "name": "Dockside Lock-Up"]], game: "riftbound")
        })
        let cell = app.buttons["collection-cell-721334-Normal"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "no Collection cell")
        XCTAssertTrue(waitUntil(timeout: 30) { cell.isHittable }, "the Collection cell is not hittable")
        cell.tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page")
        tab(app, "Wanted").tap()
        XCTAssertTrue(element(app, "wanted-screen").waitForExistence(timeout: 10), "no Wanted")
        chooseGame(app, "yu-gi-oh")
        XCTAssertTrue(waitUntil(timeout: 10) { self.element(app, "game-menu").label.contains("Yu-Gi-Oh") })
        chooseGame(app, "riftbound")
        XCTAssertTrue(waitUntil(timeout: 10) { self.element(app, "game-menu").label.contains("Riftbound") })
        tab(app, "Collection").tap()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Collection")
        XCTAssertTrue(app.buttons["collection-cell-721334-Normal"].firstMatch.waitForExistence(timeout: 20),
                      "the Collection is not at its root")
        XCTAssertFalse(element(app, "card-page").exists, "the old game's card page is still there")
        shot("tabs-05-game-switch")
    }
}
