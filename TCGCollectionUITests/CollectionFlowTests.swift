import XCTest

/// The click paths of the collection, on the fixture catalog.
final class CollectionFlowTests: UITestCase {
    /// `-askUserFolder YES`: the first-run sheet opens although the run has a test root, and "Use iCloud Drive" uses the
    /// stand-in `<root>/icloud`. A second launch on the same root resolves the kept bookmark and shows no sheet; the menu
    /// item "Collection Folder…" opens the sheet with the folder's path. "Choose a folder…" opens the system folder panel,
    /// which XCUITest cannot drive: only the button is checked.
    func testFirstRunFolderSheet() throws {
        let app = launch(game: "riftbound", extra: ["-askUserFolder", "YES"])
        let sheet = element(app, "user-folder-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "user-folder-choose").exists)
        XCTAssertFalse(element(app, "user-folder-path").exists, "the first run has no folder to show")
        let useICloud = element(app, "user-folder-icloud")
        XCTAssertTrue(useICloud.exists)
        shot("collection-01-folder-sheet")
        useICloud.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        let folder = try XCTUnwrap(root).appending(path: "icloud").appending(path: "TCG Collection")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "settings.json").path))
        XCTAssertFalse(element(app, "collection-problem").exists)

        app.terminate()                                          // the next launch, on the same root, with the same flags
        app.launch()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        XCTAssertFalse(sheet.exists, "the kept folder was not used")
        XCTAssertFalse(element(app, "collection-problem").exists)

        let appMenu = app.menuBars.menuBarItems.element(boundBy: 1)  // 0 is the Apple menu
        appMenu.click()
        let item = app.menuItems["Collection Folder…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Collection Folder… in the menu \(appMenu.title)")
        item.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let path = text(element(app, "user-folder-path"))
        XCTAssertTrue(path.hasSuffix("icloud/TCG Collection"), path)
        XCTAssertTrue(element(app, "user-folder-icloud").exists); XCTAssertTrue(element(app, "user-folder-choose").exists)
        shot("collection-02-folder-sheet-from-menu")
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "Cancel did not close the sheet")
    }

    /// The sidebar's two screens. `-screen collection` opens on the Collection (Task 5 fills it; until then one
    /// sentence); a click on "All cards" shows the catalog, a click on "Collection" brings the Collection back.
    func testSidebarSwitchesBetweenCollectionAndAllCards() {
        let app = launch(game: "riftbound", extra: ["-screen", "collection"])
        let collection = element(app, "collection-screen")
        XCTAssertTrue(collection.waitForExistence(timeout: 20), app.windows.firstMatch.debugDescription)
        let sentence = NSPredicate(format: "label == %@ OR value == %@", "No cards in this collection yet.", "No cards in this collection yet.")
        XCTAssertTrue(collection.descendants(matching: .staticText).matching(sentence).firstMatch.exists)
        XCTAssertFalse(element(app, "gallery").exists)
        XCTAssertTrue(waitUntil { self.text(app.staticTexts["status-line"]).hasPrefix("Catalog up to date") })
        assertAccentFill(app, row: "sidebar-collection")
        shot("collection-03-empty-collection")

        element(app, "sidebar-all-cards").click()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 10))
        XCTAssertFalse(collection.exists)
        element(app, "sidebar-collection").click()
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "gallery").exists)
        assertAccentFill(app, row: "sidebar-collection")
        shot("collection-04-sidebar-collection-selected")
    }

    /// Task 4 fix 1: the drawn accent fill sits on the list's own selection, so the arrow keys still move it and the
    /// screen follows.
    func testTheArrowKeysMoveTheSidebarSelection() {
        let app = launch(game: "riftbound", extra: ["-screen", "collection"])
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 20))
        element(app, "sidebar-collection").click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-all-cards")
        // VoiceOver reads the selection from the row (the static text inside it is never "selected").
        let row = app.outlineRows.containing(.any, identifier: "sidebar-all-cards").firstMatch
        XCTAssertTrue(row.exists && row.isSelected, "the All cards row is not the list's selection")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-collection")
        shot("collection-05-arrow-up-to-collection")
    }
}
