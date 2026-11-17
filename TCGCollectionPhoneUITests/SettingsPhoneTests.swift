import XCTest

/// Phase 6A task 4: Settings as a sheet (A54), the folder sheet without iCloud Drive (A55), a folder problem on every
/// tab (Review Focus 5) and the first-run question on the iPhone (A51).
final class SettingsPhoneTests: PhoneUITestCase {
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    /// Taps the gear and waits for the Settings sheet.
    private func openSettings(_ app: XCUIApplication) {
        let gear = element(app, "settings-button")
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "no gear")
        XCTAssertTrue(waitUntil(timeout: 10) { gear.isHittable }, "the gear is not hittable")
        gear.tap()
        XCTAssertTrue(element(app, "settings-sheet").waitForExistence(timeout: 10), "no Settings sheet")
    }

    /// Scrolls the Settings sheet until `element` is hittable.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element) is not hittable")
    }

    /// Taps a toggle's switch (the trailing end of its row), not its label.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// The user folder's files that are not history files (a history pass may write `<game>.prices.json` any time).
    private func userFiles(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasSuffix(".prices.json") }.sorted()
    }

    private func userFile(_ game: String) throws -> [String: Any] {
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "\(game).json")
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeUserFile(_ json: String, game: String, root: URL) throws {
        let folder = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "\(game).json"))
    }

    /// The gear, Cyberpunk turned off, Done: the game menu lists three games and Cyberpunk's file says it.
    func testSettingsTurnsAGameOff() throws {
        let app = launch()
        openSettings(app)
        let followed = app.switches["profile-followed-cyberpunk"].firstMatch
        XCTAssertTrue(followed.waitForExistence(timeout: 10), "no Cyberpunk toggle")
        XCTAssertTrue(app.switches["profile-player-cyberpunk"].exists, "no Player toggle")
        XCTAssertTrue(app.switches["profile-collector-cyberpunk"].exists, "no Collector toggle")
        XCTAssertEqual(followed.value as? String, "1")
        flip(followed)
        XCTAssertTrue(waitUntil(timeout: 10) { followed.value as? String == "0" }, "the toggle did not turn off")
        shot("settings-01")
        let done = app.buttons["settings-done"].firstMatch
        XCTAssertTrue(done.exists, "no Done")
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "settings-sheet").exists }, "Settings did not close")
        let menu = element(app, "game-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        for game in ["magic-the-gathering", "yu-gi-oh", "riftbound"] {
            XCTAssertTrue(app.buttons["game-menu-\(game)"].firstMatch.waitForExistence(timeout: 5), "no item \(game)")
        }
        XCTAssertFalse(app.buttons["game-menu-cyberpunk"].exists, "Cyberpunk is still in the game menu")
        XCTAssertTrue(waitUntil(timeout: 10) {
            ((try? self.userFile("cyberpunk"))?["profile"] as? [String: Any])?["followed"] as? Bool == false
        }, "cyberpunk.json does not say \"followed\": false")
    }

    /// Settings holds the Catalog menu's actions and the full status line.
    func testTheCatalogActionsAreInSettings() {
        let app = launch()
        openSettings(app)
        let status = app.staticTexts["status-line"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "no status line in Settings")
        XCTAssertTrue(waitUntil(timeout: 30) { self.text(status).hasPrefix("Catalog up to date") },
                      "status line: \(text(status))")
        for (identifier, title) in [("settings-refresh", "Refresh"), ("settings-rebuild", "Rebuild catalog…"),
                                    ("catalog-download-history", "Download Price History…")] {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(title)")
            XCTAssertEqual(button.label, title)
        }
        XCTAssertTrue(element(app, "settings-folder-path").exists, "no folder path")
        shot("settings-03-catalog")
    }

    /// Review Focus 5: a game file this build must not rewrite. The problem is said on the Collection, the Decks list and
    /// the search tab, in Settings under the game's row, and a card page's count controls are off.
    func testAFolderProblemIsSaidOnTheIPhone() throws {
        let app = launch(prepare: { root in try self.writeUserFile(#"{"version": 99}"#, game: "riftbound", root: root) })
        let problem = app.staticTexts["collection-problem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 20), "no problem on the Collection")
        XCTAssertTrue(text(problem).contains("riftbound.json"), "problem: \(text(problem))")
        tab(app, "Decks").tap()
        XCTAssertTrue(element(app, "decks-screen").waitForExistence(timeout: 10), "no deck list")
        XCTAssertTrue(app.staticTexts["collection-problem"].firstMatch.waitForExistence(timeout: 10),
                      "no problem on the Decks list")
        tab(app, "Search").tap()
        XCTAssertTrue(app.staticTexts["collection-problem"].firstMatch.waitForExistence(timeout: 10),
                      "no problem on the search tab")
        shot("settings-04-problem-search")
        let cell = app.buttons["card-cell-dockside lock up"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "no catalog cell")
        XCTAssertTrue(waitUntil(timeout: 30) { cell.isHittable }, "the catalog cell is not hittable")
        cell.tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page")
        let plus = app.buttons["count-plus-Normal"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no count control")
        XCTAssertFalse(plus.isEnabled, "the count control is on")
        shot("settings-05-problem-card-page")
        // Back to the search tab's root, where the gear is.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "card-page").exists }, "the card page stays")
        openSettings(app)
        let line = app.staticTexts["profile-problem-riftbound"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no problem under Riftbound's row")
        XCTAssertFalse(app.switches["profile-followed-riftbound"].firstMatch.isEnabled, "Riftbound's toggle is on")
        shot("settings-06-problem-settings")
    }

    /// The first-run question on an empty folder: tick Riftbound, Continue, the Collection tab.
    func testTheOnboardingOnTheIPhone() throws {
        let app = launch(extra: ["-onboarding", "YES"])
        let sheet = element(app, "onboarding-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "no first-run question")
        let continueButton = app.buttons["onboarding-continue"].firstMatch
        XCTAssertTrue(continueButton.exists)
        XCTAssertFalse(continueButton.isEnabled, "Continue is on before a game is ticked")
        let riftbound = app.switches["profile-followed-riftbound"].firstMatch
        XCTAssertTrue(riftbound.exists, "no Riftbound toggle")
        flip(riftbound)
        XCTAssertTrue(waitUntil(timeout: 5) { continueButton.isEnabled }, "Continue stays off")
        shot("settings-02-onboarding")
        continueButton.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !sheet.exists }, "the question did not close")
        XCTAssertTrue(tab(app, "Collection").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(app, "Collection").isSelected, "the Collection tab is not shown")
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Collection")
        XCTAssertTrue(element(app, "game-menu").label.contains("Riftbound"), "game: \(element(app, "game-menu").label)")
        XCTAssertEqual((try userFile("riftbound")["profile"] as? [String: Any])?["followed"] as? Bool, true)
        XCTAssertEqual((try userFile("yu-gi-oh")["profile"] as? [String: Any])?["followed"] as? Bool, false)
    }

    /// Review m5: "Choose a folder…" in Settings closes Settings first; the folder sheet opens after it has gone (with
    /// no iCloud Drive button, A55); Cancel closes it and nothing is written.
    func testChooseAFolderFromSettings() throws {
        let app = launch(prepare: { _ in
            try self.writeCollection([["productID": 721334, "finish": "Normal", "count": 1, "condition": "",
                                       "name": "Dockside Lock-Up"]], game: "riftbound")
        })
        let user = try XCTUnwrap(root).appending(path: "user")
        XCTAssertTrue(app.buttons["collection-cell-721334-Normal"].firstMatch.waitForExistence(timeout: 30))
        let before = try userFiles(user)
        let fileBefore = try Data(contentsOf: user.appending(path: "riftbound.json"))
        openSettings(app)
        let choose = app.buttons["settings-choose-folder"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10), "no Choose a folder…")
        reveal(app, choose)
        choose.tap()
        let folderSheet = element(app, "user-folder-sheet")
        XCTAssertTrue(folderSheet.waitForExistence(timeout: 10), "no folder sheet")
        XCTAssertFalse(element(app, "settings-sheet").exists, "Settings is still open under the folder sheet")
        XCTAssertFalse(app.buttons["user-folder-icloud"].exists, "the iPhone shows Use iCloud Drive")
        XCTAssertTrue(app.staticTexts["user-folder-path"].firstMatch.exists, "no current folder")
        shot("settings-07-folder")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !folderSheet.exists }, "the folder sheet did not close")
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10), "no Collection")
        // The gear works again: no sheet is left half open.
        openSettings(app)
        app.buttons["settings-done"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "settings-sheet").exists })
        XCTAssertEqual(try userFiles(user), before)
        XCTAssertEqual(try Data(contentsOf: user.appending(path: "riftbound.json")), fileBefore)
    }

    /// A55: the first-run folder sheet of `-askUserFolder YES` has "Choose a folder…" and no iCloud Drive button.
    func testTheFolderSheetHasNoICloudButton() {
        let app = launch(extra: ["-askUserFolder", "YES"])
        XCTAssertTrue(element(app, "user-folder-sheet").waitForExistence(timeout: 20), "no folder sheet")
        XCTAssertTrue(app.buttons["user-folder-choose"].firstMatch.exists, "no Choose a folder…")
        XCTAssertFalse(app.buttons["user-folder-icloud"].exists, "the iPhone shows Use iCloud Drive")
        shot("settings-08-first-run-folder")
    }
}
