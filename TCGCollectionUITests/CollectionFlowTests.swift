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

    /// The sidebar's two screens. `-screen collection` opens on the Collection (empty on a fresh root: one sentence); a
    /// click on "All cards" shows the catalog, a click on "Collection" brings the Collection back.
    func testSidebarSwitchesBetweenCollectionAndAllCards() {
        let app = launch(game: "riftbound", extra: ["-screen", "collection"])
        let collection = element(app, "collection-screen")
        XCTAssertTrue(collection.waitForExistence(timeout: 20), app.windows.firstMatch.debugDescription)
        let sentence = NSPredicate(format: "label == %@ OR value == %@", "No cards in this collection yet.", "No cards in this collection yet.")
        XCTAssertTrue(collection.descendants(matching: .staticText).matching(sentence).firstMatch.exists)
        XCTAssertFalse(element(app, "gallery").exists)
        XCTAssertTrue(waitUntilSynced(app))
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

    // MARK: The Collection screen (phase 2B task 5)

    /// Adding by hand: All cards → Dockside Lock-Up → `+` of Foil twice → the Collection has one cell with `×2` and the
    /// subtitle "2 copies · 1 printing". Cmd+Q and a new launch on the same root: the cell is still there.
    func testAddByHandAndSeeItInTheCollection() throws {
        let app = launch(game: "riftbound")
        let card = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))                     // the prices are in: the Foil line is the price table's
        card.click()
        let plus = element(app, "count-plus-Foil")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: 0")
        XCTAssertFalse(element(app, "count-minus-Foil").isEnabled, "− is on at 0")
        shot("collection-06-card-page-counts")
        plus.click()
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "card-owned")) == "In your collection: 2" },
                      text(element(app, "card-owned")))
        XCTAssertEqual(text(element(app, "count-value-Foil")), "2")
        XCTAssertEqual(text(element(app, "count-value-Normal")), "0")
        shot("collection-07-card-page-two-foils")

        element(app, "sidebar-collection").click()
        let cell = element(app, "collection-cell-721334-Foil")
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertEqual(identifiers(collectionCells(app)), ["collection-cell-721334-Foil"])
        XCTAssertTrue(cell.label.contains("×2"), cell.label)
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("2 copies · 1 printing") }, app.windows.firstMatch.title)
        shot("collection-08-one-printing")

        quit(app)
        XCTAssertEqual(try storedCollection(game: "riftbound"),
                       [StoredRow(productID: 721334, finish: "Foil", count: 2, name: "Dockside Lock-Up")])
        app.launch()                                             // the same root and flags: All cards first
        XCTAssertTrue(element(app, "sidebar-collection").waitForExistence(timeout: 20))
        element(app, "sidebar-collection").click()
        XCTAssertTrue(element(app, "collection-cell-721334-Foil").waitForExistence(timeout: 20))
        XCTAssertEqual(identifiers(collectionCells(app)), ["collection-cell-721334-Foil"])
        shot("collection-09-after-relaunch")
    }

    /// A row counted down to 0 on the card page is removed: from the file, and from the Collection, which is empty again.
    func testCountDownToZeroRemovesTheRow() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: 721334, finish: "Foil", count: 2, name: "Dockside Lock-Up")],
                                     game: "riftbound", in: root)
        }
        let cell = element(app, "collection-cell-721334-Foil")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.click()
        let minus = element(app, "count-minus-Foil")
        XCTAssertTrue(minus.waitForExistence(timeout: 10))
        XCTAssertEqual(text(element(app, "count-value-Foil")), "2")
        minus.click()
        minus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "count-value-Foil")) == "0" })
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: 0")
        XCTAssertFalse(minus.isEnabled, "− is on at 0")
        minus.click()                                            // disabled: nothing happens, the count stays 0
        XCTAssertEqual(text(element(app, "count-value-Foil")), "0")
        shot("collection-10-counted-down-to-zero")
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound")) == [] }, "the row is still in the file")

        goBack(app)
        let empty = NSPredicate(format: "label == %@ OR value == %@", "No cards in this collection yet.", "No cards in this collection yet.")
        let screen = element(app, "collection-screen")
        XCTAssertTrue(screen.descendants(matching: .staticText).matching(empty).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(collectionCells(app).count, 0)
        XCTAssertTrue(element(app, "collection-search-catalog").exists)
        XCTAssertFalse(element(app, "collection-import").exists, "Import CSV… shows before Task 7 wires it")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("0 copies · 0 printings") }, app.windows.firstMatch.title)
        shot("collection-11-empty-again")
        element(app, "collection-search-catalog").click()      // "Search a card" switches the sidebar to All cards
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-all-cards")
    }

    /// Five printings of the fixture catalog (three cards; a Riftbound playset is 3): the Filter menu's rarity, price and
    /// playset, the four sort orders, the search field, the totals with a filter on, and the state kept across a visit to
    /// All cards.
    func testCollectionFiltersAndSort() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: 721334, finish: "Normal", count: 1, name: "Dockside Lock-Up"),
                                      StoredRow(productID: 721334, finish: "Foil", count: 2, name: "Dockside Lock-Up"),
                                      StoredRow(productID: 721337, finish: "Normal", count: 1, name: "Kai'Sa, Rebel"),
                                      StoredRow(productID: 722282, finish: "Normal", count: 3, name: "Calm Rune (R02a)"),
                                      StoredRow(productID: 722282, finish: "Foil", count: 1, name: "Calm Rune (R02a)")],
                                     game: "riftbound", in: root)
        }
        let cells = collectionCells(app)
        XCTAssertTrue(waitUntil(timeout: 20) { cells.count == 5 }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntilSynced(app))                     // the prices: Dockside Normal $5.12, Foil ~$9.50; the rest none
        let ids = { (names: [String]) in names.map { "collection-cell-\($0)" } }
        func shown() -> [String] { identifiersInOrder(cells) }
        // Name: card key (calm rune, dockside lock up, kai sa rebel), then set, then finish.
        let byName = ids(["722282-Foil", "722282-Normal", "721334-Foil", "721334-Normal", "721337-Normal"])
        XCTAssertTrue(waitUntil { shown() == byName }, "\(shown())")
        XCTAssertTrue(app.windows.firstMatch.title.hasSuffix("8 copies · 5 printings"), app.windows.firstMatch.title)
        shot("collection-12-five-printings")

        sort(app, "Price high to low")
        XCTAssertTrue(waitUntil { shown() == ids(["721334-Foil", "721334-Normal", "722282-Foil", "722282-Normal", "721337-Normal"]) }, "\(shown())")
        sort(app, "Price low to high")
        XCTAssertTrue(waitUntil { shown() == ids(["721334-Normal", "721334-Foil", "722282-Foil", "722282-Normal", "721337-Normal"]) }, "\(shown())")
        sort(app, "Copies")
        let byCount = ids(["722282-Normal", "721334-Foil", "722282-Foil", "721334-Normal", "721337-Normal"])
        XCTAssertTrue(waitUntil { shown() == byCount }, "\(shown())")
        shot("collection-13-sorted-by-copies")

        filter(app, "collection-filter-rarity", "Showcase", shot: "collection-14-filter-menu-open")
        XCTAssertTrue(waitUntil { shown() == ids(["722282-Normal", "722282-Foil"]) }, "\(shown())")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("4 of 8 copies · 2 of 5 printings") }, app.windows.firstMatch.title)
        shot("collection-15-rarity-showcase")
        // The search text, the filter and the sort survive a visit to All cards.
        element(app, "sidebar-all-cards").click()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 10))
        element(app, "sidebar-collection").click()
        XCTAssertTrue(waitUntil { shown() == ids(["722282-Normal", "722282-Foil"]) }, "\(shown())")
        XCTAssertTrue(app.windows.firstMatch.title.hasSuffix("4 of 8 copies · 2 of 5 printings"), app.windows.firstMatch.title)
        filter(app, "collection-filter-rarity", "All")

        sort(app, "Name")
        filter(app, "collection-filter-price", "$5.00 or more")
        XCTAssertTrue(waitUntil { shown() == ids(["721334-Foil", "721334-Normal"]) }, "\(shown())")
        filter(app, "collection-filter-price", "Under $1.00")
        let noMatch = NSPredicate(format: "label == %@ OR value == %@", "No card matches these filters.", "No card matches these filters.")
        XCTAssertTrue(element(app, "collection-screen").descendants(matching: .staticText).matching(noMatch).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cells.count, 0)
        shot("collection-16-no-match")
        app.buttons["Clear filters"].firstMatch.click()
        XCTAssertTrue(waitUntil { shown() == byName }, "\(shown())")

        // Playset: Calm Rune has 4 copies over two printings, Dockside Lock-Up 3, Kai'Sa 1.
        filter(app, "collection-filter-playset", "More than a playset (3)")
        XCTAssertTrue(waitUntil { shown() == ids(["722282-Foil", "722282-Normal"]) }, "\(shown())")
        filter(app, "collection-filter-playset", "A playset (3) or fewer")
        XCTAssertTrue(waitUntil { shown() == ids(["721334-Foil", "721334-Normal", "721337-Normal"]) }, "\(shown())")
        filter(app, "collection-filter-playset", "Any number")

        let search = searchField(app)
        search.click()
        search.typeText("rune")
        XCTAssertTrue(waitUntil { shown() == ids(["722282-Foil", "722282-Normal"]) }, "\(shown())")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("4 of 8 copies · 2 of 5 printings") }, app.windows.firstMatch.title)
        shot("collection-17-search-rune")
        // The search text survives a visit to All cards, which has a search field of its own.
        element(app, "sidebar-all-cards").click()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 10))
        XCTAssertEqual(text(searchField(app)), "")
        element(app, "sidebar-collection").click()
        XCTAssertTrue(waitUntil { shown() == ids(["722282-Foil", "722282-Normal"]) }, "\(shown())")
        XCTAssertEqual(text(searchField(app)), "rune")
    }

    /// B5 and a finish with a space: Yu-Gi-Oh! has no prices in the fixture, so the card page offers `Normal`; the owned
    /// `1st Edition` (a CSV's `Printing` the price table does not list) gets a line of its own after it, and its
    /// identifiers keep the space.
    func testAnOwnedFinishThePriceTableDoesNotListHasALine() throws {
        let app = try launch(game: "yu-gi-oh", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: 719834, finish: "1st Edition", count: 1, name: "Swiftwind Panther Warrior")],
                                     game: "yu-gi-oh", in: root)
        }
        let cell = element(app, "collection-cell-719834-1st Edition")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.click()
        let plus = element(app, "count-plus-1st Edition")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertEqual(text(element(app, "count-value-1st Edition")), "1")
        XCTAssertEqual(text(element(app, "count-value-Normal")), "0")
        XCTAssertLessThan(element(app, "count-value-Normal").frame.minY, element(app, "count-value-1st Edition").frame.minY,
                          "the price table's (here: Normal) line comes first")
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "card-owned")) == "In your collection: 2" })
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "yu-gi-oh"))
                == [StoredRow(productID: 719834, finish: "1st Edition", count: 2, name: "Swiftwind Panther Warrior")] })
        shot("collection-20-first-edition-line")
    }

    /// A game file this app must not rewrite (here: a newer version) is read-only for the run: the Collection says why in
    /// its problem line and shows no cards; the count controls of the card page are off, and the sidebar says why there.
    func testARefusedFileTurnsTheCountControlsOff() throws {
        let newer = Data(#"{"version":2,"collection":[{"productID":721334,"finish":"Foil","count":2,"condition":"","name":"Dockside Lock-Up"}]}"#.utf8)
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            let folder = root.appending(path: "user", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try newer.write(to: folder.appending(path: "riftbound.json"))
        }
        let problem = app.staticTexts["collection-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 20))
        XCTAssertEqual(text(problem), "riftbound.json was written by a newer version of the app.")
        XCTAssertEqual(collectionCells(app).count, 0)
        let empty = NSPredicate(format: "label == %@ OR value == %@", "No cards in this collection yet.", "No cards in this collection yet.")
        XCTAssertFalse(app.staticTexts.matching(empty).firstMatch.exists, "a refused file is not an empty collection")
        shot("collection-22-refused-file")

        element(app, "sidebar-all-cards").click()
        let card = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        card.click()
        let plus = element(app, "count-plus-Foil")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertFalse(plus.isEnabled, "+ is on for a refused file")
        XCTAssertFalse(element(app, "count-plus-Normal").isEnabled)
        XCTAssertEqual(text(app.staticTexts["collection-problem"]), "riftbound.json was written by a newer version of the app.")
        shot("collection-23-refused-file-card-page")
        let file = try XCTUnwrap(root).appending(path: "user/riftbound.json")
        XCTAssertEqual(try Data(contentsOf: file), newer, "the refused file was rewritten")
    }

    /// Review Focus 4: a row whose product is not in the catalog stays in the file and in the gallery, with its saved
    /// name, the neutral picture and no price; its page says so and its count control removes it by hand.
    func testAnUnknownProductStaysVisible() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: 999999, finish: "Normal", count: 2, name: "Gone Card"),
                                      StoredRow(productID: 721334, finish: "Normal", count: 1, name: "Dockside Lock-Up")],
                                     game: "riftbound", in: root)
        }
        let gone = element(app, "collection-cell-999999-Normal")
        XCTAssertTrue(gone.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(element(app, "collection-cell-721334-Normal").exists)
        XCTAssertTrue(gone.label.contains("Gone Card") && gone.label.contains("×2") && gone.label.contains("—"), gone.label)
        XCTAssertFalse(gone.label.contains("$"), gone.label)
        shot("collection-18-unknown-product")

        gone.click()
        let title = app.staticTexts["card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(text(title), "Gone Card")
        let sentence = NSPredicate(format: "label == %@ OR value == %@", "This printing is not in the catalog any more.",
                                   "This printing is not in the catalog any more.")
        XCTAssertTrue(app.staticTexts.matching(sentence).firstMatch.exists)
        XCTAssertEqual(text(element(app, "count-value-Normal")), "2")
        shot("collection-19-unknown-product-page")
        element(app, "count-minus-Normal").click()
        element(app, "count-minus-Normal").click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "count-value-Normal")) == "0" })
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound"))
                == [StoredRow(productID: 721334, finish: "Normal", count: 1, name: "Dockside Lock-Up")] },
                      "\(String(describing: try? storedCollection(game: "riftbound")))")
        goBack(app)
        XCTAssertTrue(waitUntil { self.identifiers(self.collectionCells(app)) == ["collection-cell-721334-Normal"] },
                      "\(identifiers(collectionCells(app)))")
    }

    /// Review Focus 5 and the quit path. `-writeDelay 1500`: every write of a game file waits 1.5 s, so the writes are
    /// still queued when Cmd+Q arrives right after the clicks; the app must wait for them before it ends. Five fast clicks
    /// on `+` (a double click and three clicks) count five, and all five are in the file after the quit.
    func testFastClicksAndAQuitAtOnceReachTheFile() throws {
        let app = launch(game: "riftbound", extra: ["-writeDelay", "1500"])
        let card = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        card.click()
        let plus = element(app, "count-plus-Foil")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.doubleClick()
        plus.click()
        plus.click()
        plus.click()
        XCTAssertTrue(waitUntil(timeout: 3) { self.text(self.element(app, "count-value-Foil")) == "5" },
                      text(element(app, "count-value-Foil")))
        quit(app)                                                // at once: the last write is still waiting
        XCTAssertEqual(try storedCollection(game: "riftbound"),
                       [StoredRow(productID: 721334, finish: "Foil", count: 5, name: "Dockside Lock-Up")])

        app.launch()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        element(app, "card-cell-dockside lock up").click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "count-value-Foil")) == "5" })
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: 5")
        shot("collection-21-five-after-relaunch")
    }

    // MARK: Helpers

    /// Picks `item` in the Sort menu.
    private func sort(_ app: XCUIApplication, _ item: String) {
        element(app, "collection-sort").click()
        let choice = app.menuItems[item].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(item) in the Sort menu")
        choice.click()
    }

    /// Opens the Filter menu, then the submenu with the identifier `submenu`, and picks `item` in it. With `shot`, a
    /// picture of the open submenu first.
    private func filter(_ app: XCUIApplication, _ submenu: String, _ item: String, shot name: String? = nil) {
        element(app, "collection-filter").click()
        let sub = app.menuItems.matching(identifier: submenu).firstMatch
        XCTAssertTrue(sub.waitForExistence(timeout: 5), "no \(submenu) in the Filter menu: \(app.menus.firstMatch.debugDescription)")
        sub.hover()
        let choice = sub.menuItems[item].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(item) in \(submenu)")
        if let name { shot(name) }
        choice.click()
    }

    /// The back button of a page pushed on the Collection.
    private func goBack(_ app: XCUIApplication) {
        let back = app.toolbars.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button: \(app.toolbars.firstMatch.debugDescription)")
        back.click()
    }
}
