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
}
