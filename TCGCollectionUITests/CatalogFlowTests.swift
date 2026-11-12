import XCTest

/// The phase 1 click paths, on the fixture catalog: Magic 4 cards, Yu-Gi-Oh! 2, Riftbound 3, Cyberpunk 3.
/// A cell's identifier is `card-cell-<card key>` (the card name in lower case, punctuation as spaces).
final class CatalogFlowTests: UITestCase {
    func testGalleryToCardPageAndPrintingSwitch() {
        let app = launch(game: "cyberpunk")
        XCTAssertTrue(app.staticTexts["status-line"].waitForExistence(timeout: 20))
        let cell = app.descendants(matching: .any)["card-cell-kerry eurodyne the last rockerboy"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20)); shot("01-gallery")
        cell.click()
        XCTAssertTrue(app.descendants(matching: .any)["card-page"].waitForExistence(timeout: 10))
        XCTAssertEqual(text(app.staticTexts["card-title"]), "Kerry Eurodyne - The Last Rockerboy"); shot("02-card-page")
    }

    func testSearchTyping() {
        let app = launch(game: "riftbound")
        let cells = cardCells(app)
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let all = cells.count
        let search = searchField(app)
        search.click()
        search.typeText("rune")
        XCTAssertTrue(waitUntil { cells.count > 0 && cells.count < all })
        XCTAssertTrue(identifiers(cells).allSatisfy { $0.contains("rune") }, "\(identifiers(cells))")
        shot("03-search-rune")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil { cells.count == all })
        shot("04-search-cleared")
    }

    func testFilterMenu() {
        let app = launch(game: "riftbound")
        let cells = cardCells(app)
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let all = cells.count
        let typeMenu = element(app, "filter-type")
        typeMenu.click()
        // An open menu shows its items twice (under the button and beside it): take the first.
        XCTAssertTrue(app.menuItems["Gear"].firstMatch.waitForExistence(timeout: 5)); shot("05-type-menu-open")
        app.menuItems["Gear"].firstMatch.click()
        XCTAssertTrue(waitUntil { identifiers(cells) == ["card-cell-dockside lock up"] }, "\(identifiers(cells))")
        shot("06-type-gear")
        typeMenu.click()
        XCTAssertTrue(app.menuItems["All"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["All"].firstMatch.click()
        XCTAssertTrue(waitUntil { cells.count == all })
    }

    func testGamePicker() {
        let app = launch(game: "riftbound")
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        let search = searchField(app)
        search.click()
        search.typeText("rune")
        XCTAssertTrue(waitUntil { self.text(search) == "rune" })
        element(app, "game-picker").click()
        XCTAssertTrue(app.menuItems["Cyberpunk TCG"].firstMatch.waitForExistence(timeout: 5)); shot("07-game-picker-open")
        app.menuItems["Cyberpunk TCG"].firstMatch.click()
        // The window title is the navigation title and the subtitle: "Cyberpunk TCG – 3 cards".
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasPrefix("Cyberpunk TCG") }, app.windows.firstMatch.title)
        XCTAssertTrue(element(app, "card-cell-kerry eurodyne the last rockerboy").waitForExistence(timeout: 10))
        XCTAssertEqual(text(searchField(app)), "")
        shot("08-cyberpunk")
    }

    func testPrintingSwitchByRowText() {
        let app = launch(game: "yu-gi-oh")
        let cell = element(app, "card-cell-swiftwind panther warrior")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.click()
        let facts = app.staticTexts["card-facts-line"]
        XCTAssertTrue(facts.waitForExistence(timeout: 10))
        let before = text(facts)
        // Products 719834 (Super Rare) and 719835 (Starlight Rare): the other one is the row to click.
        let other = before.contains("Starlight") ? 719834 : 719835
        let row = element(app, "printing-row-\(other)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // The printing rows are at the bottom of the page, below the test window's edge: scroll down first.
        // A coordinate click is not checked by XCUITest; it must not land outside the window.
        element(app, "card-page").scroll(byDeltaX: 0, deltaY: -2000)
        XCTAssertTrue(waitUntil { row.isHittable }, "the printing row is not on screen")
        shot("09-printing-before")
        // The set name is the first text of the row, at its left edge: the click lands on the text, not beside it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).click()
        XCTAssertTrue(waitUntil { self.text(facts) != before }, "facts line stayed \(before)")
        shot("10-printing-after")
    }

    /// Magic has 4 cards: two rows, taller than the gallery of the test window, so the gallery scrolls.
    func testClickRightAfterScroll() {
        let app = launch(game: "magic-the-gathering")
        let cells = cardCells(app)
        XCTAssertTrue(waitUntil(timeout: 20) { cells.count == 4 })
        let gallery = element(app, "gallery")
        let last = cells.element(boundBy: 3)                    // Stingcaster Mage, in the second row
        let top = last.frame.minY
        gallery.scroll(byDeltaX: 0, deltaY: -120)
        XCTAssertLessThan(last.frame.minY, top, "the gallery did not scroll")
        shot("11-gallery-scrolled")
        let name = last.label
        gallery.scroll(byDeltaX: 0, deltaY: -120)
        last.click()                                            // at once, no wait after the scroll
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10))
        XCTAssertTrue(name.hasPrefix(text(app.staticTexts["card-title"])), "opened \(text(app.staticTexts["card-title"])), clicked \(name)")
        shot("12-card-after-scroll")
    }

    /// Final review I1: the sync belongs to the model, so closing the window during a download does not stop it.
    /// `-fixtureDelay 1200`: each set answers after 1.2 s, 4 at a time. Riftbound (14 sets, 4 rounds) comes first,
    /// then the prices, then Magic, Yu-Gi-Oh! and Cyberpunk (1 set, 1 round each): about 8.4 s in all.
    func testWindowCloseKeepsTheSync() {
        let app = launch(game: "riftbound", extra: ["-fixtureDelay", "1200"])
        let status = app.staticTexts["status-line"]
        // Every status line read, in order: none may say "failed" or "cancelled".
        var seen: [String] = []
        func read() -> String {
            let line = status.exists ? text(status) : ""
            if seen.last != line { seen.append(line) }
            return line
        }
        // A running download shows a set count, for example "Riftbound: 4 / 14 sets".
        let counting = { (line: String) in line.range(of: #"\d+ / \d+ sets"#, options: .regularExpression) != nil }
        XCTAssertTrue(waitUntil(timeout: 15) { counting(read()) }, "no download seen: \(seen)")
        let atClose = read()
        XCTContext.runActivity(named: "close the window at \"\(atClose)\"") { _ in
            XCTAssertTrue(counting(atClose), "the sync was not running at Cmd+W: \(atClose)")
            app.typeKey("w", modifierFlags: .command)
        }
        XCTAssertTrue(waitUntil { app.windows.count == 0 })
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["New Window"].click()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        shot("13-new-window-during-sync")
        let ended = waitUntil(timeout: 30) { read().hasPrefix("Catalog up to date") }
        XCTContext.runActivity(named: "status lines seen: \(seen)") { _ in
            XCTAssertTrue(ended, "the sync did not end")
            XCTAssertFalse(seen.contains { $0.contains("failed") || $0.contains("cancelled") })
        }
        // Cyberpunk was downloaded after the window had closed.
        element(app, "game-picker").click()
        XCTAssertTrue(app.menuItems["Cyberpunk TCG"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["Cyberpunk TCG"].firstMatch.click()
        XCTAssertTrue(element(app, "card-cell-kerry eurodyne the last rockerboy").waitForExistence(timeout: 10))
        shot("13-new-window-synced")
    }

    func testEmptyOfflineCatalog() {
        let app = launch(extra: ["-offline", "YES"], fixtures: false)
        let empty = element(app, "empty-state")
        XCTAssertTrue(empty.waitForExistence(timeout: 20))
        let message = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Offline. The catalog is empty.", "Offline. The catalog is empty.")
        XCTAssertTrue(empty.descendants(matching: .staticText).matching(message).firstMatch.exists)
        shot("14-offline-empty")
    }

    /// Fix round 1, item 2. A store file the app may not read (mode 000) is kept: the app runs on an empty store in
    /// memory. The empty screen offers "Reset the catalog…"; after the confirmation the next launch sets the file aside
    /// and downloads the catalog again.
    func testResetCatalogAfterAStoreFailure() throws {
        let app = try launch(game: "riftbound") { root in
            let support = root.appending(path: "support", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let store = support.appending(path: "catalog.store")
            try Data("no permission".utf8).write(to: store)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        }
        let reset = element(app, "reset-catalog")
        XCTAssertTrue(reset.waitForExistence(timeout: 20))
        XCTAssertTrue(text(app.staticTexts["status-line"]).hasPrefix("Catalog: the store cannot be opened"))
        XCTAssertFalse(element(app, "catalog-menu").isEnabled, "the Catalog menu does nothing while the store is in memory")
        shot("15-store-failure")
        reset.click()
        // The confirmation is a sheet; the Touch Bar shows the same button, which cannot be clicked.
        let confirm = app.sheets.buttons["Reset the catalog"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); shot("16-reset-confirmation")
        confirm.click()
        let quit = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                               "Quit and open the app again", "Quit and open the app again")
        XCTAssertTrue(element(app, "empty-state").descendants(matching: .staticText).matching(quit).firstMatch.waitForExistence(timeout: 5))
        shot("17-reset-asked")

        app.terminate()                                          // the next launch, on the same root
        app.launch()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let support = try XCTUnwrap(root).appending(path: "support")
        let aside = try FileManager.default.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("unreadable-") }
        XCTAssertEqual(aside.count, 1)
        shot("18-after-reset")
    }

    // MARK: - Helpers

    /// The `.searchable` field: SwiftUI gives it no identifier of ours on macOS, so it is found by type.
    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        app.searchFields.firstMatch
    }

    private func identifiers(_ query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.map(\.identifier).sorted()
    }

    /// The whole fixture sync has ended (every game, prices, the Yu-Gi-Oh! index).
    private func waitUntilSynced(_ app: XCUIApplication) -> Bool {
        let status = app.staticTexts["status-line"]
        return waitUntil(timeout: 20) { status.exists && self.text(status).hasPrefix("Catalog up to date") }
    }
}
