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
        // The cell's name is the printing's product name; the count line names the finish (fix round 1, item 3).
        XCTAssertEqual(cell.label, "Dockside Lock-Up, ×2, Foil, Radiance, ~$9.50")
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
    /// The cell opens its card page once the catalog has its product (before that it is pending and opens nothing).
    func testCountDownToZeroRemovesTheRow() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: 721334, finish: "Foil", count: 2, name: "Dockside Lock-Up")],
                                     game: "riftbound", in: root)
        }
        let cell = element(app, "collection-cell-721334-Foil")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["collection-cell-721334-Foil"].waitForExistence(timeout: 30), "the cell is not a link")
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
        // "Import CSV…" is the empty state's first button, and in the toolbar (an icon).
        let importButton = element(app, "collection-empty-import")
        XCTAssertTrue(importButton.exists && importButton.isHittable)
        XCTAssertLessThan(importButton.frame.minY, element(app, "collection-search-catalog").frame.minY, "Import CSV… is not first")
        XCTAssertTrue(element(app, "collection-import").isHittable)
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
        // A Normal and a Foil of one product, and two products of one card, are told apart (fix round 1, item 3).
        XCTAssertTrue(waitUntil { self.element(app, "collection-cell-722282-Foil").label == "Calm Rune (R02a), ×1, Foil, Radiance, no price" },
                      element(app, "collection-cell-722282-Foil").label)
        XCTAssertEqual(element(app, "collection-cell-722282-Normal").label, "Calm Rune (R02a), ×3, Normal, Radiance, no price")
        XCTAssertEqual(element(app, "collection-cell-721334-Normal").label, "Dockside Lock-Up, ×1, Normal, Radiance, $5.12")
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
        // Task 7: with the search field active, Import CSV…, Filter and Sort still fit the toolbar (no overflow).
        for item in ["collection-import", "collection-filter", "collection-sort"] {
            XCTAssertTrue(element(app, item).isHittable, "\(item) is not in the toolbar while searching")
        }
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
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { app.buttons["collection-cell-719834-1st Edition"].exists }, "the cell is not a link")
        XCTAssertTrue(cell.label.hasPrefix("Swiftwind Panther Warrior, ×1, 1st Edition, "), cell.label)
        cell.click()
        let plus = element(app, "count-plus-1st Edition")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        // No price for either finish: "No price" in place of a price (fix round 1, item 8).
        let noPrice = NSPredicate(format: "label == %@ OR value == %@", "No price", "No price")
        XCTAssertEqual(app.staticTexts.matching(noPrice).count, 2)
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
    /// its problem line and shows no cards; the card page shows no count (not a false 0), its controls are off, and a line
    /// under them says why. Yu-Gi-Oh!'s file is refused too: the Collection and the card page name Riftbound's own
    /// problem; the sidebar keeps the first problem of all (fix round 1, items 1 and 6).
    func testARefusedFileTurnsTheCountControlsOff() throws {
        let newer = Data(#"{"version":2,"collection":[{"productID":721334,"finish":"Foil","count":2,"condition":"","name":"Dockside Lock-Up"}]}"#.utf8)
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            let folder = root.appending(path: "user", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try newer.write(to: folder.appending(path: "riftbound.json"))
            try Data("not json".utf8).write(to: folder.appending(path: "yu-gi-oh.json"))
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
        // The file holds Foil ×2, which this run cannot read: no number at all, not 0.
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: —")
        XCTAssertEqual(text(element(app, "count-value-Foil")), "—")
        XCTAssertEqual(text(element(app, "count-value-Normal")), "—")
        XCTAssertEqual(text(element(app, "card-counts-locked")),
                       "The counts cannot change: riftbound.json was written by a newer version of the app.")
        XCTAssertEqual(text(app.staticTexts["collection-problem"]), "yu-gi-oh.json cannot be read.")   // the sidebar
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
        // Only once the catalog has the game's sets is a missing product "not in the catalog any more".
        XCTAssertTrue(waitUntil { app.buttons["collection-cell-999999-Normal"].exists }, "the cell is not a link")
        XCTAssertFalse(element(app, "collection-catalog-note").exists)
        XCTAssertEqual(element(app, "collection-cell-721334-Normal").label, "Dockside Lock-Up, ×1, Normal, Radiance, $5.12")
        XCTAssertEqual(gone.label, "Gone Card, ×2, Normal, no price")
        shot("collection-18-unknown-product")

        gone.click()
        let title = app.staticTexts["card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(text(title), "Gone Card")
        let sentence = NSPredicate(format: "label == %@ OR value == %@", "This printing is not in the catalog any more.",
                                   "This printing is not in the catalog any more.")
        XCTAssertTrue(app.staticTexts.matching(sentence).firstMatch.exists)
        XCTAssertEqual(text(element(app, "count-value-Normal")), "2")
        let noPrice = NSPredicate(format: "label == %@ OR value == %@", "No price", "No price")
        XCTAssertEqual(app.staticTexts.matching(noPrice).count, 0, "the page of an unknown product has a price column")
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

    /// Review Focus 5 and the quit path. `-writeDelay 4000`: every write of a game file waits 4 s, so the writes are
    /// still queued when Cmd+Q arrives right after the clicks (checked: the file does not hold the count yet); the app must
    /// wait for them before it ends. Five fast clicks on `+` (a double click and three clicks) count five, and all five are
    /// in the file after the quit.
    func testFastClicksAndAQuitAtOnceReachTheFile() throws {
        let app = launch(game: "riftbound", extra: ["-writeDelay", "4000"])
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
        let five = [StoredRow(productID: 721334, finish: "Foil", count: 5, name: "Dockside Lock-Up")]
        XCTAssertNotEqual(try storedCollection(game: "riftbound"), five, "the write was done before the quit: nothing to wait for")
        quit(app)                                                // at once: the last write is still waiting
        XCTAssertEqual(try storedCollection(game: "riftbound"), five)

        app.launch()
        XCTAssertTrue(element(app, "card-cell-dockside lock up").waitForExistence(timeout: 20))
        element(app, "card-cell-dockside lock up").click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "count-value-Foil")) == "5" })
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: 5")
        shot("collection-21-five-after-relaunch")
    }

    /// Fix round 2, item 1: while a game's catalog is still downloading, a row whose product is not in yet is pending (its
    /// saved name, no link, the downloading line), never "not in the catalog any more"; a row whose product is in already
    /// opens its card page. `-game cyberpunk -fixtureDelay 3000`: Cyberpunk, the prices, Magic and Yu-Gi-Oh! come first,
    /// then Riftbound's 14 sets, 4 at a time, 3 s each. Once the first Riftbound set is in, the test switches to
    /// Riftbound, whose step still runs for about 9 s. When the step has ended, the missing row opens the page of a printing
    /// that left the catalog.
    func testARowNotInTheCatalogYetIsPendingDuringADownload() throws {
        let app = try launch(game: "cyberpunk", extra: ["-screen", "collection", "-fixtureDelay", "3000"]) { root in
            try self.writeCollection([StoredRow(productID: 721334, finish: "Foil", count: 2, name: "Dockside Lock-Up"),
                                      StoredRow(productID: 999999, finish: "Normal", count: 1, name: "Gone Card")],
                                     game: "riftbound", in: root)
        }
        let status = app.staticTexts["status-line"]
        let started = waitUntil(timeout: 40) {
            let line = status.exists ? self.text(status) : ""
            guard let range = line.range(of: #"Riftbound: \d+ / 14 sets"#, options: .regularExpression) else { return false }
            let done = Int(line[range].split(separator: " ")[1]) ?? 0
            return done >= 1 && done <= 10
        }
        XCTAssertTrue(started, "Riftbound's download was not seen running: \(text(status))")
        element(app, "game-picker").click()
        XCTAssertTrue(app.menuItems["Riftbound"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["Riftbound"].firstMatch.click()
        XCTAssertTrue(app.buttons["collection-cell-721334-Foil"].waitForExistence(timeout: 5), "the product that is in is no link")
        let gone = element(app, "collection-cell-999999-Normal")
        XCTAssertTrue(gone.exists)
        XCTAssertFalse(app.buttons["collection-cell-999999-Normal"].exists, "a row not in the catalog yet is a link")
        XCTAssertEqual(gone.label, "Gone Card, ×1, Normal, no price")
        XCTAssertEqual(text(element(app, "collection-catalog-note")),
                       "The catalog is still downloading. Pictures and prices come when it is ready.")
        XCTAssertTrue(text(status).contains("Riftbound:"), "the download ended before the check: \(text(status))")
        shot("collection-24-catalog-downloading")

        // The step has ended: now the missing product is "not in the catalog any more".
        XCTAssertTrue(app.buttons["collection-cell-999999-Normal"].waitForExistence(timeout: 40), "the step did not end")
        XCTAssertFalse(element(app, "collection-catalog-note").exists)
        app.buttons["collection-cell-999999-Normal"].click()
        let sentence = NSPredicate(format: "label == %@ OR value == %@", "This printing is not in the catalog any more.",
                                   "This printing is not in the catalog any more.")
        XCTAssertTrue(app.staticTexts.matching(sentence).firstMatch.waitForExistence(timeout: 5))
    }

    /// Fix round 1, item 2: offline on an empty catalog (no fixtures), a pre-filled collection is listed by the rows'
    /// saved names and counts, with the totals and one line that says the catalog is empty. Nothing says "not in the
    /// catalog any more", and a cell opens nothing.
    func testAnEmptyCatalogListsTheRowsByTheirSavedNames() throws {
        let app = try launch(game: "riftbound", extra: ["-offline", "YES", "-screen", "collection"], fixtures: false) { root in
            try self.writeCollection([StoredRow(productID: 721334, finish: "Foil", count: 2, name: "Dockside Lock-Up"),
                                      StoredRow(productID: 722282, finish: "Normal", count: 1, name: "Calm Rune (R02a)")],
                                     game: "riftbound", in: root)
        }
        let note = element(app, "collection-catalog-note")
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        XCTAssertEqual(text(note), "The catalog is empty. Pictures and prices need the catalog.")
        let cells = collectionCells(app)
        XCTAssertEqual(identifiersInOrder(cells), ["collection-cell-722282-Normal", "collection-cell-721334-Foil"])
        XCTAssertEqual(element(app, "collection-cell-721334-Foil").label, "Dockside Lock-Up, ×2, Foil, no price")
        XCTAssertEqual(element(app, "collection-cell-722282-Normal").label, "Calm Rune (R02a), ×1, Normal, no price")
        XCTAssertTrue(app.windows.firstMatch.title.hasSuffix("3 copies · 2 printings"), app.windows.firstMatch.title)
        let gone = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "not in the catalog", "not in the catalog")
        XCTAssertEqual(app.staticTexts.matching(gone).count, 0)
        XCTAssertFalse(app.buttons["collection-cell-721334-Foil"].exists, "a cell is a link without a catalog")
        shot("collection-25-empty-catalog")
        element(app, "collection-cell-721334-Foil").click()
        XCTAssertFalse(app.staticTexts["card-title"].waitForExistence(timeout: 2), "a cell opened a page")
        XCTAssertEqual(app.staticTexts.matching(gone).count, 0)
    }

    // MARK: CSV import (phase 2B task 7)

    /// The fixture `collection-riftbound.csv` against the two rows of the Task 6 test: New 2 (722282 +4, 721337 +3),
    /// Count changes 1 (721334 Foil 1 → 3), In your collection, not in this file 1 ("Only Here", product 555, ×2). The
    /// fixture catalog has no plain basic rune, so lines 5 (900001) and 6 (999999) are both "not in the catalog". Import
    /// writes the new and changed rows and keeps "Only Here"; the Collection then shows Riftbound with the four printings,
    /// and the status line says the summary.
    func testImportShowsTheComparisonAndAppliesIt() throws {
        let app = try launchImport("collection-riftbound.csv") { try self.writeTask6Rows($0) }
        let sheet = try waitForTheComparison(app)
        XCTAssertEqual(text(element(app, "import-title")), "Import collection-riftbound.csv")
        XCTAssertEqual(text(element(app, "import-new-riftbound")), "New · 2")
        XCTAssertEqual(text(element(app, "import-changed-riftbound")), "Count changes · 1")
        XCTAssertEqual(text(element(app, "import-missing-riftbound")), "In your collection, not in this file · 1")
        XCTAssertEqual(text(element(app, "import-summary")), "2 new, 1 changed, 1 not in the file (kept)")
        XCTAssertEqual(text(element(app, "import-count-722282-Normal")), "+4")
        XCTAssertEqual(text(element(app, "import-count-721337-Normal")), "+3")
        XCTAssertEqual(text(element(app, "import-count-721334-Foil")), "1 → 3")
        XCTAssertEqual(text(element(app, "import-count-555-Normal")), "×2")
        XCTAssertFalse(isOn(element(app, "import-remove-555-Normal")), "Remove is on by default")
        XCTAssertEqual(element(app, "import-missing-all-riftbound").label, "Remove all")
        // The numbers are right-aligned in one column.
        let counts = ["722282-Normal", "721337-Normal", "721334-Foil", "555-Normal"].map { element(app, "import-count-\($0)").frame.maxX }
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1, "the counts are not right-aligned: \(counts)")
        XCTAssertFalse(element(app, "import-skipped-line-5").exists, "Not imported is open at first")
        XCTAssertTrue(element(app, "import-apply").isEnabled)
        XCTAssertTrue(waitUntilSynced(app))                     // the status line is the sync's before the import
        shot("import-01-comparison", of: sheet)

        element(app, "import-skipped").click()
        let line5 = element(app, "import-skipped-line-5"), line6 = element(app, "import-skipped-line-6")
        XCTAssertTrue(line5.waitForExistence(timeout: 5))
        // One static text per line (its parts combined): "Line 5, Calm Rune, not in the catalog".
        XCTAssertTrue(text(line5).contains("Calm Rune") && text(line5).contains("not in the catalog"), text(line5))
        XCTAssertTrue(text(line6).contains("Not In The Catalog") && text(line6).contains("not in the catalog"), text(line6))
        shot("import-02-not-imported-open", of: sheet)

        element(app, "import-apply").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        let cells = collectionCells(app)
        let four = ["collection-cell-555-Normal", "collection-cell-721334-Foil", "collection-cell-721337-Normal", "collection-cell-722282-Normal"]
        XCTAssertTrue(waitUntil { self.identifiers(cells) == four }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("12 copies · 4 printings") }, app.windows.firstMatch.title)
        XCTAssertTrue(waitUntil { self.element(app, "collection-cell-555-Normal").label == "Only Here, ×2, Normal, no price" },
                      element(app, "collection-cell-555-Normal").label)
        XCTAssertTrue(element(app, "collection-cell-721334-Foil").label.hasPrefix("Dockside Lock-Up, ×3, Foil, "))
        XCTAssertEqual(text(app.staticTexts["status-line"]), "Imported: 2 new, 1 changed, 1 not in the file (kept)")
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound")) == Self.importedRows(keepingOnlyHere: true) },
                      "\(String(describing: try? storedCollection(game: "riftbound")))")
        shot("import-03-collection-after-import")

        // Fix round 1, item 2: the same file again (a second launch on the same root). Only the kept "Only Here" differs:
        // Import would write nothing, so the sheet says so, shows the kept row, and offers only Close until Remove is on.
        quit(app)
        app.launch()
        let missing = element(app, "import-missing-riftbound")
        XCTAssertTrue(missing.waitForExistence(timeout: 40), sheet.debugDescription)
        XCTAssertEqual(text(element(app, "import-summary")), "Nothing to import: this file adds nothing to your collection.")
        XCTAssertFalse(element(app, "import-new-riftbound").exists || element(app, "import-changed-riftbound").exists)
        XCTAssertTrue(element(app, "import-close").exists)
        XCTAssertFalse(element(app, "import-apply").exists || element(app, "import-cancel").exists)
        shot("import-08-nothing-to-import", of: sheet)
        element(app, "import-remove-555-Normal").click()
        XCTAssertTrue(element(app, "import-apply").waitForExistence(timeout: 5), "Remove did not offer Import")
        XCTAssertTrue(element(app, "import-apply").isEnabled)
        XCTAssertEqual(text(element(app, "import-summary")), "1 not in the file (removed)")
        element(app, "import-cancel").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertEqual(try storedCollection(game: "riftbound"), Self.importedRows(keepingOnlyHere: true))
    }

    /// The same start; "Remove" on "Only Here" (the header control then says "Keep all", and turns it off and on again).
    /// Import removes that row and nothing else.
    func testImportRemovesOnlyWhatIsChosen() throws {
        let app = try launchImport("collection-riftbound.csv") { try self.writeTask6Rows($0) }
        let sheet = try waitForTheComparison(app)
        let remove = element(app, "import-remove-555-Normal"), all = element(app, "import-missing-all-riftbound")
        remove.click()
        XCTAssertTrue(waitUntil { self.isOn(remove) }, "Remove did not switch on")
        XCTAssertEqual(text(element(app, "import-summary")), "2 new, 1 changed, 1 not in the file (removed)")
        XCTAssertTrue(waitUntil { all.label == "Keep all" }, all.label)
        all.click()                                              // Keep all
        XCTAssertTrue(waitUntil { !self.isOn(remove) && all.label == "Remove all" })
        XCTAssertEqual(text(element(app, "import-summary")), "2 new, 1 changed, 1 not in the file (kept)")
        all.click()                                              // Remove all
        XCTAssertTrue(waitUntil { self.isOn(remove) && all.label == "Keep all" })
        XCTAssertTrue(waitUntilSynced(app))
        shot("import-04-remove-chosen", of: sheet)

        element(app, "import-apply").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        let three = ["collection-cell-721334-Foil", "collection-cell-721337-Normal", "collection-cell-722282-Normal"]
        XCTAssertTrue(waitUntil { self.identifiers(self.collectionCells(app)) == three }, "\(identifiers(collectionCells(app)))")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("10 copies · 3 printings") }, app.windows.firstMatch.title)
        XCTAssertTrue(element(app, "collection-cell-721334-Foil").label.hasPrefix("Dockside Lock-Up, ×3, Foil, "))
        XCTAssertEqual(text(app.staticTexts["status-line"]), "Imported: 2 new, 1 changed, 1 not in the file (removed)")
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound")) == Self.importedRows(keepingOnlyHere: false) },
                      "\(String(describing: try? storedCollection(game: "riftbound")))")
        shot("import-05-collection-after-removal")
    }

    /// Cancel writes nothing: the file is byte for byte what it was, after Cmd+Q (which waits for queued writes) and
    /// after a second launch without the import.
    func testImportCancelChangesNothing() throws {
        var before = Data()
        let app = try launchImport("collection-riftbound.csv") { root in
            try self.writeTask6Rows(root)
            before = try Data(contentsOf: root.appending(path: "user/riftbound.json"))
        }
        let sheet = try waitForTheComparison(app)
        element(app, "import-cancel").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        let two = ["collection-cell-555-Normal", "collection-cell-721334-Foil"]
        XCTAssertTrue(waitUntil { self.identifiers(self.collectionCells(app)) == two }, "\(identifiers(collectionCells(app)))")
        quit(app)
        let file = try XCTUnwrap(root).appending(path: "user/riftbound.json")
        XCTAssertEqual(try Data(contentsOf: file), before, "Cancel changed the file")

        app.launchArguments = withoutImport(app.launchArguments)
        app.launch()
        XCTAssertTrue(waitUntil(timeout: 20) { self.identifiers(self.collectionCells(app)) == two }, "\(identifiers(collectionCells(app)))")
        XCTAssertFalse(sheet.exists)
        XCTAssertEqual(element(app, "collection-cell-721334-Foil").label.hasPrefix("Dockside Lock-Up, ×1, Foil"), true)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// A text file that is not an export: one sentence and Close, and the collection is as it was.
    func testImportOfAFileThatIsNotAnExport() throws {
        let app = try launchImport("not-an-export.txt") { try self.writeTask6Rows($0) }
        let sheet = element(app, "import-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        let sentence = element(app, "import-sentence")
        XCTAssertTrue(waitUntil { sentence.exists && self.text(sentence) == "This is not a TCGplayer collection export." },
                      sheet.debugDescription)
        XCTAssertEqual(text(element(app, "import-title")), "Import not-an-export.txt")
        XCTAssertTrue(element(app, "import-close").exists)
        XCTAssertFalse(element(app, "import-apply").exists)
        XCTAssertFalse(element(app, "import-cancel").exists)
        shot("import-06-not-an-export", of: sheet)
        element(app, "import-close").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "Close did not close the sheet")
        let two = ["collection-cell-555-Normal", "collection-cell-721334-Foil"]
        XCTAssertTrue(waitUntil { self.identifiers(self.collectionCells(app)) == two }, "\(identifiers(collectionCells(app)))")
    }

    /// The dispatch's ruling: while Riftbound's catalog step runs (`-fixtureDelay 2000`: 14 sets, 4 at a time), the sheet
    /// says the catalog is still downloading and offers only Close, not a comparison of lines it cannot know yet. When the
    /// step has ended, the comparison comes without a new import, with Import.
    func testImportWaitsForTheCatalog() throws {
        let app = try launchImport("collection-riftbound.csv", extra: ["-fixtureDelay", "2000"]) { try self.writeTask6Rows($0) }
        let sheet = element(app, "import-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        let blocked = element(app, "import-blocked-riftbound")
        XCTAssertTrue(blocked.waitForExistence(timeout: 10), sheet.debugDescription)
        XCTAssertEqual(text(blocked), "The catalog is still downloading. This game can be imported when it is ready.")
        XCTAssertEqual(text(element(app, "import-summary")), "Nothing in this file can be imported now.")
        XCTAssertFalse(element(app, "import-new-riftbound").exists)
        XCTAssertFalse(element(app, "import-apply").exists)
        XCTAssertFalse(element(app, "import-skipped").exists, "lines of a catalog that is not ready are listed as unknown")
        XCTAssertTrue(element(app, "import-close").exists)
        shot("import-07-catalog-downloading", of: sheet)

        XCTAssertTrue(element(app, "import-new-riftbound").waitForExistence(timeout: 60), "the comparison did not come")
        XCTAssertFalse(blocked.exists)
        XCTAssertEqual(text(element(app, "import-summary")), "2 new, 1 changed, 1 not in the file (kept)")
        XCTAssertTrue(element(app, "import-apply").isEnabled)
    }

    // MARK: Helpers

    /// Launches on the Collection with `-importCSV <Fixtures>/<file>`, after `prepare` has written into the fresh root.
    private func launchImport(_ file: String, extra: [String] = [], prepare: (URL) throws -> Void) throws -> XCUIApplication {
        let path = Self.fixturesDirectory.appending(path: file).path
        return try launch(game: "riftbound", extra: ["-screen", "collection", "-importCSV", path] + extra, prepare: prepare)
    }

    /// The two rows of the Task 6 test: Dockside Lock-Up Foil ×1, and "Only Here" (product 555, not in the catalog) ×2.
    private func writeTask6Rows(_ root: URL) throws {
        try writeCollection([StoredRow(productID: 721334, finish: "Foil", count: 1, name: "Dockside Lock-Up"),
                             StoredRow(productID: 555, finish: "Normal", count: 2, condition: "Mint", name: "Only Here")],
                            game: "riftbound", in: root)
    }

    /// The file after importing `collection-riftbound.csv` onto `writeTask6Rows`: the changed row keeps its place, new rows
    /// follow in the comparison's order.
    private static func importedRows(keepingOnlyHere: Bool) -> [StoredRow] {
        var rows = [StoredRow(productID: 721334, finish: "Foil", count: 3, condition: "Near Mint, Lightly Played", name: "Dockside Lock-Up")]
        if keepingOnlyHere { rows.append(StoredRow(productID: 555, finish: "Normal", count: 2, condition: "Mint", name: "Only Here")) }
        rows.append(StoredRow(productID: 722282, finish: "Normal", count: 4, condition: "Near Mint", name: "Calm Rune (R02a)"))
        rows.append(StoredRow(productID: 721337, finish: "Normal", count: 3, condition: "Near Mint", name: "Kai'Sa, Rebel"))
        return rows
    }

    /// Waits for the sheet and for Riftbound's groups (they come once the fixture catalog's Riftbound step has ended).
    private func waitForTheComparison(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let sheet = element(app, "import-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "no import sheet", file: file, line: line)
        XCTAssertTrue(element(app, "import-new-riftbound").waitForExistence(timeout: 40), sheet.debugDescription, file: file, line: line)
        return sheet
    }

    /// A checkbox's state: its value is 1 when it is on.
    private func isOn(_ checkbox: XCUIElement) -> Bool {
        (checkbox.value as? NSNumber)?.intValue == 1 || (checkbox.value as? String) == "1"
    }

    /// The launch arguments without `-importCSV` and its value.
    private func withoutImport(_ arguments: [String]) -> [String] {
        guard let i = arguments.firstIndex(of: "-importCSV"), i + 1 < arguments.count else { return arguments }
        return Array(arguments[..<i] + arguments[(i + 2)...])
    }

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
