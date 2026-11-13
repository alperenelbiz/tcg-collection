import XCTest

/// The click paths of the lists of phase 2C (For Sale, Wanted), on the fixture catalog. The fixture prices give Dockside
/// Lock-Up (721334) Normal $5.12 and Foil ~$9.50; Calm Rune (R02a) (722282) has none; Yu-Gi-Oh! has none (the pin test
/// writes its own).
final class ListsFlowTests: UITestCase {
    /// On a card page, "For sale" of Normal twice: its `+` is then off at the owned count 2. For Sale has one cell with
    /// its count control and "Sold"; the subtitle sums the copies' prices; the file has `forSale` 2.
    func testMarkForSaleOnTheCardPageShowsOnForSale() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: 721334, finish: "Normal", count: 2, name: "Dockside Lock-Up"),
                                      StoredRow(productID: 721334, finish: "Foil", count: 1, name: "Dockside Lock-Up")],
                                     game: "riftbound", in: root)
        }
        XCTAssertTrue(waitUntilSynced(app))                     // the prices are in
        let cell = app.buttons["collection-cell-721334-Normal"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the cell is not a link")
        cell.click()
        let plus = element(app, "sale-plus-Normal")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Owned"].exists && app.staticTexts["For sale"].exists, "no column titles")
        XCTAssertEqual(text(element(app, "sale-value-Normal")), "0")
        XCTAssertEqual(text(element(app, "sale-value-Foil")), "0")
        XCTAssertFalse(element(app, "sale-minus-Normal").isEnabled, "− is on at 0")
        XCTAssertTrue(element(app, "sale-plus-Foil").isEnabled)
        shot("lists-01-card-page-for-sale-column")
        plus.click()
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "sale-value-Normal")) == "2" }, text(element(app, "sale-value-Normal")))
        XCTAssertFalse(plus.isEnabled, "+ is on at the owned count")
        XCTAssertTrue(element(app, "sale-minus-Normal").isEnabled)
        XCTAssertEqual(text(element(app, "count-value-Normal")), "2")    // the owned count is not touched
        shot("lists-02-card-page-two-for-sale")

        element(app, "sidebar-for-sale").click()
        let saleCell = app.buttons["for-sale-cell-721334-Normal"]
        XCTAssertTrue(saleCell.waitForExistence(timeout: 10))
        XCTAssertEqual(identifiers(forSaleCells(app)), ["for-sale-cell-721334-Normal"])
        XCTAssertEqual(saleCell.label, "Dockside Lock-Up, ×2, Normal, Radiance, $5.12")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("2 copies · 1 printing · $10.24") }, app.windows.firstMatch.title)
        XCTAssertEqual(text(element(app, "for-sale-value-721334-Normal")), "2")
        XCTAssertFalse(element(app, "for-sale-plus-721334-Normal").isEnabled, "+ is on at the owned count")
        XCTAssertTrue(element(app, "for-sale-minus-721334-Normal").isEnabled)
        XCTAssertTrue(element(app, "for-sale-sold-721334-Normal").isEnabled)
        XCTAssertTrue(element(app, "for-sale-sort").exists)
        assertAccentFill(app, row: "sidebar-for-sale")
        shot("lists-03-for-sale-one-cell")
        XCTAssertTrue(waitUntil { (try? self.storedForSale(game: "riftbound"))
                == [StoredSale(productID: 721334, finish: "Normal", count: 2, name: "Dockside Lock-Up")] },
                      "\(String(describing: try? storedForSale(game: "riftbound")))")
    }

    /// C7: "Sold" asks once; Cancel changes nothing (the file's bytes stay). "Sold all 2" takes both copies out of the
    /// collection and the list, and writes one sold record with today's day and the printing's price. For Sale is then
    /// empty, with its one action; the Collection keeps ×1. "Sold" is off while its dialog is open, so the copies are sold
    /// once (Review Focus 3).
    func testSoldTakesTheCopiesOutOnce() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.saleFile(owned: 3, forSale: 2))
        }
        let sold = element(app, "for-sale-sold-721334-Normal")
        XCTAssertTrue(sold.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { self.element(app, "for-sale-cell-721334-Normal").label == "Dockside Lock-Up, ×2, Normal, Radiance, $5.12" },
                      element(app, "for-sale-cell-721334-Normal").label)
        XCTAssertTrue(app.windows.firstMatch.title.hasSuffix("2 copies · 1 printing · $10.24"), app.windows.firstMatch.title)
        shot("lists-04-for-sale-before-sold")
        let file = try XCTUnwrap(root).appending(path: "user/riftbound.json")
        let before = try Data(contentsOf: file)
        sold.click()
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        cancel.click()
        XCTAssertTrue(waitUntil { !app.sheets.firstMatch.exists }, "Cancel did not close the dialog")
        XCTAssertTrue(waitUntil { sold.isEnabled }, "Sold stayed off after Cancel")
        XCTAssertEqual(text(element(app, "for-sale-value-721334-Normal")), "2")
        XCTAssertEqual(try Data(contentsOf: file), before, "Cancel changed the file")
        sold.click()
        let all = app.sheets.buttons["Sold all 2"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        XCTAssertTrue(app.sheets.buttons["Sold 1"].firstMatch.exists)
        XCTAssertTrue(app.sheets.buttons["Cancel"].firstMatch.exists)
        XCTAssertTrue(app.sheets.staticTexts.matching(Self.showing("Sold 2 of Dockside Lock-Up?")).firstMatch.exists,
                      app.sheets.firstMatch.debugDescription)
        XCTAssertFalse(sold.isEnabled, "Sold is on while its dialog is open")
        shot("lists-05-sold-dialog")
        all.click()

        let screen = element(app, "for-sale-screen")
        XCTAssertTrue(screen.descendants(matching: .staticText).matching(Self.showing("Nothing for sale.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(forSaleCells(app).count, 0)
        XCTAssertFalse(sold.exists)
        let open = element(app, "for-sale-open-collection")
        XCTAssertTrue(open.exists && open.isHittable)
        shot("lists-06-for-sale-empty")
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound"))
                == [StoredRow(productID: 721334, finish: "Normal", count: 1, name: "Dockside Lock-Up")] },
                      "\(String(describing: try? storedCollection(game: "riftbound")))")
        XCTAssertEqual(try storedForSale(game: "riftbound"), [])
        XCTAssertEqual(try storedSold(game: "riftbound"),
                       [StoredSold(productID: 721334, finish: "Normal", count: 2, name: "Dockside Lock-Up", day: Self.today(),
                                   price: 5.12, priceIsLow: false)])

        open.click()                                             // "Open the collection"
        let owned = element(app, "collection-cell-721334-Normal")
        XCTAssertTrue(owned.waitForExistence(timeout: 10))
        XCTAssertTrue(owned.label.hasPrefix("Dockside Lock-Up, ×1, Normal"), owned.label)
        assertAccentFill(app, row: "sidebar-collection")
        shot("lists-07-collection-after-sold")
    }

    /// One owned, one for sale: the dialog offers "Sold 1" only. After it the printing is gone from the Collection.
    func testSoldOneOfOne() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.saleFile(owned: 1, forSale: 1, calmRune: true))
        }
        let sold = element(app, "for-sale-sold-721334-Normal")
        XCTAssertTrue(sold.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        sold.click()
        let one = app.sheets.buttons["Sold 1"].firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        let soldAll = NSPredicate(format: "label BEGINSWITH %@", "Sold all")
        XCTAssertEqual(app.sheets.buttons.matching(soldAll).count, 0, "Sold all is offered for one copy")
        XCTAssertTrue(app.sheets.staticTexts.matching(Self.showing("Sold 1 of Dockside Lock-Up?")).firstMatch.exists)
        shot("lists-08-sold-one-dialog")
        one.click()
        XCTAssertTrue(waitUntil { self.forSaleCells(app).count == 0 })
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound"))
                == [StoredRow(productID: 722282, finish: "Normal", count: 1, name: "Calm Rune (R02a)")] },
                      "\(String(describing: try? storedCollection(game: "riftbound")))")
        XCTAssertEqual(try storedSold(game: "riftbound").map(\.count), [1])

        element(app, "sidebar-collection").click()
        XCTAssertTrue(waitUntil { self.identifiers(self.collectionCells(app)) == ["collection-cell-722282-Normal"] },
                      "\(identifiers(collectionCells(app)))")
        shot("lists-09-collection-without-the-sold-printing")
    }

    /// Fix round 1, D4: a double click on "Sold 1" sells one copy once: one record, one copy less owned and for sale.
    func testADoubleClickOnSoldOneSellsOne() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.saleFile(owned: 3, forSale: 2))
        }
        let sold = element(app, "for-sale-sold-721334-Normal")
        XCTAssertTrue(sold.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        sold.click()
        let one = app.sheets.buttons["Sold 1"].firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        one.doubleClick()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "for-sale-value-721334-Normal")) == "1" },
                      text(element(app, "for-sale-value-721334-Normal")))
        XCTAssertTrue(waitUntil { (try? self.storedSold(game: "riftbound"))?.map(\.count) == [1] },
                      "\(String(describing: try? storedSold(game: "riftbound")))")
        XCTAssertEqual(try storedCollection(game: "riftbound"), [StoredRow(productID: 721334, finish: "Normal", count: 2, name: "Dockside Lock-Up")])
        XCTAssertEqual(try storedForSale(game: "riftbound"), [StoredSale(productID: 721334, finish: "Normal", count: 1, name: "Dockside Lock-Up")])
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    /// Fix round 1, item B: the dialog follows the live for-sale count. Another device lowers it from 2 to 1 while the
    /// dialog is open (a coordinated write the app reads again): the title says 1 and "Sold all" goes. When nothing is for
    /// sale any more, the dialog closes and nothing was sold.
    func testTheSoldDialogFollowsTheLiveCount() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.saleFile(owned: 2, forSale: 2))
        }
        let sold = element(app, "for-sale-sold-721334-Normal")
        XCTAssertTrue(sold.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        sold.click()
        XCTAssertTrue(app.sheets.buttons["Sold all 2"].firstMatch.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        XCTAssertTrue(app.sheets.staticTexts.matching(Self.showing("Sold 2 of Dockside Lock-Up?")).firstMatch.exists)
        shot("lists-13-sold-dialog-two-for-sale")

        try changeUserFile(game: "riftbound", json: Self.saleFile(owned: 2, forSale: 1))
        XCTAssertTrue(waitUntil { self.text(self.element(app, "for-sale-value-721334-Normal")) == "1" },
                      "the reload did not reach the app: \(text(element(app, "for-sale-value-721334-Normal")))")
        XCTAssertTrue(app.sheets.staticTexts.matching(Self.showing("Sold 1 of Dockside Lock-Up?")).firstMatch.waitForExistence(timeout: 10),
                      app.sheets.firstMatch.debugDescription)
        let soldAll = NSPredicate(format: "label BEGINSWITH %@", "Sold all")
        XCTAssertTrue(waitUntil { app.sheets.buttons.matching(soldAll).count == 0 }, app.sheets.firstMatch.debugDescription)
        XCTAssertTrue(app.sheets.buttons["Sold 1"].firstMatch.exists)
        shot("lists-14-sold-dialog-after-a-reload")

        try changeUserFile(game: "riftbound", json: Self.saleFile(owned: 2, forSale: 0))
        XCTAssertTrue(waitUntil { !app.sheets.firstMatch.exists }, "the dialog stayed open with nothing for sale")
        let screen = element(app, "for-sale-screen")
        XCTAssertTrue(screen.descendants(matching: .staticText).matching(Self.showing("Nothing for sale.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try storedSold(game: "riftbound"), [])
        shot("lists-15-dialog-closed-nothing-for-sale")
    }

    /// Fix round 1, D5: two printings for sale, one without a price. The search narrows the cells and the subtitle (the
    /// Collection's "x of y" form, the sum of the shown printings); `−` at 1 takes a printing off the list.
    func testSearchAndMinusToZeroOnForSale() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1,
             "collection": [{"productID": 721334, "finish": "Normal", "count": 1, "condition": "", "name": "Dockside Lock-Up"},
                            {"productID": 722282, "finish": "Normal", "count": 1, "condition": "", "name": "Calm Rune (R02a)"}],
             "forSale": [{"productID": 721334, "finish": "Normal", "count": 1, "name": "Dockside Lock-Up"},
                         {"productID": 722282, "finish": "Normal", "count": 1, "name": "Calm Rune (R02a)"}]}
            """)
        }
        let cells = forSaleCells(app)
        XCTAssertTrue(waitUntil(timeout: 20) { cells.count == 2 }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntilSynced(app))
        let title = { app.windows.firstMatch.title }
        XCTAssertTrue(waitUntil { title().hasSuffix("2 copies · 2 printings · $5.12 + 1 without a price") }, title())
        let search = searchField(app)
        search.click()
        search.typeText("rune")
        XCTAssertTrue(waitUntil { self.identifiers(cells) == ["for-sale-cell-722282-Normal"] }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntil { title().hasSuffix("1 of 2 copies · 1 of 2 printings · 1 without a price") }, title())
        shot("lists-16-for-sale-search")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil { cells.count == 2 }, "\(identifiers(cells))")

        element(app, "for-sale-minus-721334-Normal").click()
        XCTAssertTrue(waitUntil { self.identifiers(cells) == ["for-sale-cell-722282-Normal"] }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntil { title().hasSuffix("1 copy · 1 printing · 1 without a price") }, title())
        XCTAssertTrue(waitUntil { (try? self.storedForSale(game: "riftbound"))
                == [StoredSale(productID: 722282, finish: "Normal", count: 1, name: "Calm Rune (R02a)")] },
                      "\(String(describing: try? storedForSale(game: "riftbound")))")
        XCTAssertEqual(try storedCollection(game: "riftbound").map(\.count), [1, 1], "the owned counts changed")
        shot("lists-17-for-sale-minus-to-zero")
    }

    /// C8: 3 owned, 3 for sale; `−` of the owned count on the card page takes the for-sale count down with it, and the
    /// status line says so once.
    func testOwnedBelowForSaleFollows() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.saleFile(owned: 3, forSale: 3))
        }
        XCTAssertTrue(waitUntilSynced(app))                     // a later status line would replace the notice
        let cell = app.buttons["for-sale-cell-721334-Normal"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the cell is not a link")
        cell.click()
        let minus = element(app, "count-minus-Normal")
        XCTAssertTrue(minus.waitForExistence(timeout: 10))
        XCTAssertEqual(text(element(app, "count-value-Normal")), "3")
        XCTAssertEqual(text(element(app, "sale-value-Normal")), "3")
        XCTAssertFalse(element(app, "sale-plus-Normal").isEnabled)
        minus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "sale-value-Normal")) == "2" }, text(element(app, "sale-value-Normal")))
        XCTAssertEqual(text(element(app, "count-value-Normal")), "2")
        let status = app.staticTexts["status-line"]
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(status) == "1 copy is no longer for sale." }, text(status))
        shot("lists-10-owned-below-for-sale")
        XCTAssertTrue(waitUntil { (try? self.storedForSale(game: "riftbound"))
                == [StoredSale(productID: 721334, finish: "Normal", count: 2, name: "Dockside Lock-Up")] },
                      "\(String(describing: try? storedForSale(game: "riftbound")))")
        XCTAssertEqual(try storedCollection(game: "riftbound"), [StoredRow(productID: 721334, finish: "Normal", count: 2, name: "Dockside Lock-Up")])

        goBack(app)
        XCTAssertTrue(waitUntil { self.element(app, "for-sale-cell-721334-Normal").label == "Dockside Lock-Up, ×2, Normal, Radiance, $5.12" },
                      element(app, "for-sale-cell-721334-Normal").label)
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("2 copies · 1 printing · $10.24") }, app.windows.firstMatch.title)
    }

    /// A game file this app must not rewrite (here: a newer version) is read-only for the run. For Sale lists nothing (the
    /// file's lists cannot be read, so no cell carries a control) and is not "Nothing for sale.": its problem line says
    /// why. On a card page the for-sale controls are off with the owned ones and show no number.
    func testARefusedFileTurnsTheSaleControlsOff() throws {
        let newer = Self.saleFile(owned: 2, forSale: 1, version: 9)
        let app = try launch(game: "riftbound", extra: ["-screen", "for-sale"]) { _ in
            try self.writeUserFile(game: "riftbound", json: newer)
        }
        let problem = app.staticTexts["collection-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 20))
        XCTAssertEqual(text(problem), "riftbound.json was written by a newer version of the app.")
        XCTAssertTrue(element(app, "for-sale-screen").exists)
        XCTAssertEqual(forSaleCells(app).count, 0)
        XCTAssertFalse(app.staticTexts.matching(Self.showing("Nothing for sale.")).firstMatch.exists,
                       "a refused file is not an empty list")
        shot("lists-11-for-sale-refused-file")

        element(app, "sidebar-all-cards").click()
        let card = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        card.click()
        let plus = element(app, "sale-plus-Normal")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        for control in ["sale-plus-Normal", "sale-minus-Normal", "sale-plus-Foil", "sale-minus-Foil", "count-plus-Normal",
                        "wanted-plus", "wanted-minus"] {
            XCTAssertFalse(element(app, control).isEnabled, "\(control) is on for a refused file")
        }
        XCTAssertEqual(text(element(app, "sale-value-Normal")), "—")
        XCTAssertEqual(text(element(app, "sale-value-Foil")), "—")
        XCTAssertEqual(text(element(app, "wanted-value")), "—")         // the wanted count is not known either
        XCTAssertFalse(element(app, "wanted-pin").exists)
        XCTAssertEqual(text(element(app, "card-counts-locked")),
                       "The counts cannot change: riftbound.json was written by a newer version of the app.")
        shot("lists-12-card-page-refused-file")
        let file = try XCTUnwrap(root).appending(path: "user/riftbound.json")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), newer, "the refused file was rewritten")
    }

    // MARK: Wanted (phase 2C task 4)

    /// All cards → Dockside Lock-Up → `wanted-plus` twice: the pin is offered from 1 (not at 0), the owned count is not
    /// touched (C5). Wanted has one cell, `×2` with the card's cheapest price ($5.12, its Normal market price; its Foil is
    /// ~$9.50), and the count control under it; the file has one wanted entry, count 2, no pin.
    func testAddToWantedFromTheCardPage() throws {
        let app = launch(game: "riftbound")
        let card = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))                     // the prices are in
        card.click()
        let plus = element(app, "wanted-plus")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertEqual(text(element(app, "wanted-value")), "0")
        XCTAssertFalse(element(app, "wanted-minus").isEnabled, "− is on at 0")
        XCTAssertFalse(element(app, "wanted-pin").exists, "the pin is offered at 0")
        shot("lists-18-card-page-wanted-zero")
        plus.click()
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "wanted-value")) == "2" }, text(element(app, "wanted-value")))
        XCTAssertTrue(element(app, "wanted-minus").isEnabled)
        let pin = element(app, "wanted-pin")
        XCTAssertTrue(pin.exists && pin.label == "Want this printing", pin.label)
        XCTAssertEqual(text(element(app, "count-value-Normal")), "0")    // owning and wanting are apart (C5)
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: 0")
        shot("lists-19-card-page-wanted-two")

        element(app, "sidebar-wanted").click()
        let cell = app.buttons["wanted-cell-dockside lock up"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the cell is not a link")
        XCTAssertEqual(identifiers(wantedCells(app)), ["wanted-cell-dockside lock up"])
        XCTAssertEqual(cell.label, "Dockside Lock-Up, ×2, $5.12")
        XCTAssertEqual(text(element(app, "wanted-cell-value-dockside lock up")), "2")
        XCTAssertTrue(element(app, "wanted-cell-minus-dockside lock up").isEnabled)
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("2 copies · 1 card · $10.24") }, app.windows.firstMatch.title)
        XCTAssertTrue(element(app, "wanted-sort").exists)
        assertAccentFill(app, row: "sidebar-wanted")
        shot("lists-20-wanted-one-card")
        XCTAssertTrue(waitUntil { (try? self.storedWanted(game: "riftbound"))
                == [StoredWanted(cardKey: "dockside lock up", name: "Dockside Lock-Up", count: 2)] },
                      "\(String(describing: try? storedWanted(game: "riftbound")))")
        XCTAssertEqual(try storedCollection(game: "riftbound"), [])
    }

    /// C2, C12: a pin is the printing on screen and its first finish line. Yu-Gi-Oh!'s Swiftwind Panther Warrior has two
    /// printings; its page opens on 719835 (Starlight Rare, the newest: one set, the higher id). "Other printings" →
    /// 719834 (Super Rare), `wanted-plus`, "Want this printing": the entry saves the card's name (not "(Starlight Rare)")
    /// and pins 719834 1st Edition. Wanted shows that printing's set and that finish's price ($14.50: not its cheapest
    /// finish, $9.00, nor the card's cheapest, $3.10). On the pinned page "Any printing" takes the pin away, and the cell
    /// shows the cheapest again. The prices are this test's own (`writePinPrices`).
    func testPinAPrinting() throws {
        let app = try launch(game: "yu-gi-oh") { root in try self.writePinPrices(in: root) }
        let card = element(app, "card-cell-swiftwind panther warrior")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(card.label.hasSuffix("$3.10"), "the fixture prices replaced the test's own: \(card.label)")
        card.click()
        let facts = app.staticTexts["card-facts-line"]
        XCTAssertTrue(facts.waitForExistence(timeout: 10))
        XCTAssertTrue(text(facts).contains("Starlight Rare"), text(facts))
        let row = element(app, "printing-row-719834")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // The printing rows are below the test window's edge: scroll down, then click on the row's text (see
        // CatalogFlowTests.testPrintingSwitchByRowText).
        let page = element(app, "card-page")
        page.scroll(byDeltaX: 0, deltaY: -2000)
        XCTAssertTrue(waitUntil { row.isHittable }, "the printing row is not on screen")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).click()
        XCTAssertTrue(waitUntil { self.text(facts).contains("Super Rare") }, text(facts))
        page.scroll(byDeltaX: 0, deltaY: 2000)
        let plus = element(app, "wanted-plus")
        XCTAssertTrue(waitUntil { plus.isHittable }, "the Wanted line is not on screen")
        plus.click()
        let pin = element(app, "wanted-pin")
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertEqual(pin.label, "Want this printing")
        pin.click()
        XCTAssertTrue(waitUntil { pin.label == "Any printing" }, pin.label)
        XCTAssertEqual(text(element(app, "wanted-value")), "1")
        shot("lists-21-card-page-pinned")
        XCTAssertTrue(waitUntil { (try? self.storedWanted(game: "yu-gi-oh"))
                == [StoredWanted(cardKey: "swiftwind panther warrior", name: "Swiftwind Panther Warrior", count: 1,
                                 pinProductID: 719834, pinFinish: "1st Edition")] },
                      "\(String(describing: try? storedWanted(game: "yu-gi-oh")))")

        element(app, "sidebar-wanted").click()
        let cell = app.buttons["wanted-cell-swiftwind panther warrior"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the cell is not a link")
        XCTAssertTrue(waitUntil { cell.label == "Swiftwind Panther Warrior, ×1, Beyond the Brave, $14.50" }, cell.label)
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix("1 copy · 1 card · $14.50") }, app.windows.firstMatch.title)
        shot("lists-22-wanted-pinned")

        cell.click()                                             // the page opens on the pinned printing
        XCTAssertTrue(waitUntil { self.text(facts).contains("Super Rare") }, text(facts))
        XCTAssertTrue(waitUntil { pin.exists && pin.label == "Any printing" }, pin.label)
        pin.click()
        XCTAssertTrue(waitUntil { pin.label == "Want this printing" }, pin.label)
        goBack(app)
        XCTAssertTrue(waitUntil { cell.label == "Swiftwind Panther Warrior, ×1, $3.10" }, cell.label)
        XCTAssertTrue(app.windows.firstMatch.title.hasSuffix("1 copy · 1 card · $3.10"), app.windows.firstMatch.title)
        shot("lists-23-wanted-any-printing")
        XCTAssertTrue(waitUntil { (try? self.storedWanted(game: "yu-gi-oh"))
                == [StoredWanted(cardKey: "swiftwind panther warrior", name: "Swiftwind Panther Warrior", count: 1)] },
                      "\(String(describing: try? storedWanted(game: "yu-gi-oh")))")
        // No pin key is left behind (not even null).
        let entry = try XCTUnwrap((try storedUserFile(game: "yu-gi-oh")?["wanted"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["cardKey", "name", "count"])
    }

    /// C6: change and remove on the row. Two wanted cards; `+` then `−` twice on Dockside Lock-Up: at 0 its cell goes,
    /// Calm Rune stays; the file and the subtitle agree.
    func testChangeAndRemoveOnTheRow() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "wanted"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1, "collection": [],
             "wanted": [{"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "count": 1},
                        {"cardKey": "calm rune", "name": "Calm Rune", "count": 2}]}
            """)
        }
        let cells = wantedCells(app)
        XCTAssertTrue(waitUntil(timeout: 20) { cells.count == 2 }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntilSynced(app))
        let title = { app.windows.firstMatch.title }
        XCTAssertTrue(waitUntil { title().hasSuffix("3 copies · 2 cards · $5.12 + 1 without a price") }, title())
        XCTAssertEqual(element(app, "wanted-cell-calm rune").label, "Calm Rune, ×2, no price")
        shot("lists-24-wanted-two-cards")
        let value = element(app, "wanted-cell-value-dockside lock up")
        element(app, "wanted-cell-plus-dockside lock up").click()
        XCTAssertTrue(waitUntil { self.text(value) == "2" }, text(value))
        XCTAssertTrue(waitUntil { title().hasSuffix("4 copies · 2 cards · $10.24 + 1 without a price") }, title())
        let minus = element(app, "wanted-cell-minus-dockside lock up")
        minus.click()
        XCTAssertTrue(waitUntil { self.text(value) == "1" }, text(value))
        minus.click()
        XCTAssertTrue(waitUntil { self.identifiers(cells) == ["wanted-cell-calm rune"] }, "\(identifiers(cells))")
        XCTAssertTrue(waitUntil { title().hasSuffix("2 copies · 1 card · 1 without a price") }, title())
        XCTAssertEqual(text(element(app, "wanted-cell-value-calm rune")), "2")
        shot("lists-25-wanted-minus-to-zero")
        XCTAssertTrue(waitUntil { (try? self.storedWanted(game: "riftbound"))
                == [StoredWanted(cardKey: "calm rune", name: "Calm Rune", count: 2)] },
                      "\(String(describing: try? storedWanted(game: "riftbound")))")
    }

    /// Review Focus 4: a wanted card whose key the catalog does not have stays on the list with its saved name, no picture
    /// and no price. Once the catalog is settled, its cell opens a small page that says so and has its count; `−` on the
    /// cell takes it off the list, and Wanted is empty with its one action. "Search a card" opens All cards, where a new
    /// entry saves the card's name, not the printing's bracketed product name ("Calm Rune (R02a)").
    func testAWantedCardThatLeftTheCatalogStays() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "wanted"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1, "collection": [], "wanted": [{"cardKey": "gone card", "name": "Gone Card", "count": 1}]}
            """)
        }
        XCTAssertTrue(waitUntilSynced(app))
        let cell = app.buttons["wanted-cell-gone card"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the cell of a card that left a settled catalog is not a link")
        XCTAssertEqual(cell.label, "Gone Card, ×1, no price")
        XCTAssertTrue(app.windows.firstMatch.title.hasSuffix("1 copy · 1 card · 1 without a price"), app.windows.firstMatch.title)
        XCTAssertFalse(element(app, "wanted-catalog-note").exists, "a settled catalog has nothing to say")
        shot("lists-26-wanted-card-not-in-catalog")

        cell.click()
        let sentence = app.staticTexts.matching(Self.showing("This card is not in the catalog any more.")).firstMatch
        XCTAssertTrue(sentence.waitForExistence(timeout: 10))
        XCTAssertEqual(text(app.staticTexts["card-title"]), "Gone Card")
        XCTAssertEqual(text(element(app, "wanted-value")), "1")
        XCTAssertFalse(element(app, "wanted-pin").exists, "a card without a printing has nothing to pin")
        shot("lists-27-unknown-card-page")
        goBack(app)

        let minus = element(app, "wanted-cell-minus-gone card")
        XCTAssertTrue(minus.waitForExistence(timeout: 10))
        minus.click()
        let screen = element(app, "wanted-screen")
        XCTAssertTrue(screen.descendants(matching: .staticText).matching(Self.showing("Nothing on your wanted list.")).firstMatch
            .waitForExistence(timeout: 10))
        XCTAssertEqual(wantedCells(app).count, 0)
        XCTAssertTrue(element(app, "wanted-search-catalog").isHittable)
        shot("lists-28-wanted-empty")
        XCTAssertTrue(waitUntil { (try? self.storedWanted(game: "riftbound")) == [] },
                      "\(String(describing: try? storedWanted(game: "riftbound")))")

        element(app, "wanted-search-catalog").click()           // "Search a card"
        let rune = element(app, "card-cell-calm rune")
        XCTAssertTrue(rune.waitForExistence(timeout: 10))
        assertAccentFill(app, row: "sidebar-all-cards")
        rune.click()
        let plus = element(app, "wanted-plus")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.click()
        XCTAssertTrue(waitUntil { (try? self.storedWanted(game: "riftbound"))
                == [StoredWanted(cardKey: "calm rune", name: "Calm Rune", count: 1)] },
                      "\(String(describing: try? storedWanted(game: "riftbound")))")
    }

    // MARK: Helpers

    /// One entry of a stored `wanted` list.
    struct StoredWanted: Equatable {
        var cardKey: String
        var name: String
        var count: Int
        var pinProductID: Int?
        var pinFinish: String?
    }

    /// The `wanted` list of the stored file; [] with no file or no list.
    private func storedWanted(game: String) throws -> [StoredWanted] {
        let list = try storedUserFile(game: game)?["wanted"] as? [[String: Any]] ?? []
        return try list.map { entry in
            StoredWanted(cardKey: try XCTUnwrap(entry["cardKey"] as? String), name: entry["name"] as? String ?? "",
                         count: try XCTUnwrap(entry["count"] as? Int), pinProductID: entry["pinProductID"] as? Int,
                         pinFinish: entry["pinFinish"] as? String)
        }
    }

    /// Every cell of Wanted's gallery (`wanted-cell-<card key>`), not the controls under them (`wanted-cell-minus-…`).
    /// A card key has no hyphen (`CardName.searchKey`).
    private func wantedCells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: """
            identifier BEGINSWITH 'wanted-cell-' AND NOT (identifier BEGINSWITH 'wanted-cell-minus-' \
            OR identifier BEGINSWITH 'wanted-cell-value-' OR identifier BEGINSWITH 'wanted-cell-plus-')
            """))
    }

    /// Writes this test's own price files into `<root>/support` before the launch, for every game, with a day far ahead:
    /// the price step then has that day and downloads nothing, so the fixture archive (which has no Yu-Gi-Oh! price) does
    /// not replace them. Yu-Gi-Oh!: Swiftwind Panther Warrior 719834 (Super Rare) 1st Edition $14.50, Unlimited $9.00;
    /// 719835 (Starlight Rare) 1st Edition $3.10. The other games have none. The form is the app's `GamePrices`.
    private func writePinPrices(in root: URL) throws {
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let none = #"{"day": "2099-12-31", "finishes": [], "rows": {}}"#
        let yugioh = """
        {"day": "2099-12-31", "finishes": ["1st Edition", "Unlimited"],
         "rows": {"719834": {"0": {"market": 14.5}, "1": {"market": 9}}, "719835": {"0": {"market": 3.1}}}}
        """
        for game in ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"] {
            try Data((game == "yu-gi-oh" ? yugioh : none).utf8).write(to: support.appending(path: "prices-\(game).json"))
        }
    }

    /// One entry of a stored `forSale` list.
    struct StoredSale: Equatable {
        var productID: Int
        var finish: String
        var count: Int
        var name: String
    }

    /// One stored `sold` record.
    struct StoredSold: Equatable {
        var productID: Int
        var finish: String
        var count: Int
        var name: String
        var day: String
        var price: Double?
        var priceIsLow: Bool
    }

    /// A Riftbound game file: Dockside Lock-Up Normal, `owned` copies and `forSale` of them for sale; with `calmRune`, also
    /// one Calm Rune (R02a).
    private static func saleFile(owned: Int, forSale: Int, calmRune: Bool = false, version: Int = 1) -> String {
        let calm = calmRune ? #", {"productID": 722282, "finish": "Normal", "count": 1, "condition": "", "name": "Calm Rune (R02a)"}"# : ""
        return """
        {"version": \(version),
         "collection": [{"productID": 721334, "finish": "Normal", "count": \(owned), "condition": "", "name": "Dockside Lock-Up"}\(calm)],
         "forSale": [{"productID": 721334, "finish": "Normal", "count": \(forSale), "name": "Dockside Lock-Up"}]}
        """
    }

    /// The `forSale` list of the stored file; [] with no file or no list.
    private func storedForSale(game: String) throws -> [StoredSale] {
        let list = try storedUserFile(game: game)?["forSale"] as? [[String: Any]] ?? []
        return try list.map { entry in
            StoredSale(productID: try XCTUnwrap(entry["productID"] as? Int), finish: try XCTUnwrap(entry["finish"] as? String),
                       count: try XCTUnwrap(entry["count"] as? Int), name: entry["name"] as? String ?? "")
        }
    }

    /// The `sold` records of the stored file; [] with no file or no log.
    private func storedSold(game: String) throws -> [StoredSold] {
        let list = try storedUserFile(game: game)?["sold"] as? [[String: Any]] ?? []
        return try list.map { record in
            StoredSold(productID: try XCTUnwrap(record["productID"] as? Int), finish: try XCTUnwrap(record["finish"] as? String),
                       count: try XCTUnwrap(record["count"] as? Int), name: record["name"] as? String ?? "",
                       day: try XCTUnwrap(record["day"] as? String), price: record["price"] as? Double,
                       priceIsLow: try XCTUnwrap(record["priceIsLow"] as? Bool))
        }
    }

    /// The device's calendar day, as the app writes it in a sold record.
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// A static text that shows `text` (macOS keeps it in `value` or `label`).
    private static func showing(_ text: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR value == %@", text, text)
    }

    /// Every cell of For Sale's gallery (`for-sale-cell-<productID>-<finish>`).
    private func forSaleCells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'for-sale-cell-'"))
    }

    /// The back button of a page pushed on a list screen.
    private func goBack(_ app: XCUIApplication) {
        let back = app.toolbars.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button: \(app.toolbars.firstMatch.debugDescription)")
        back.click()
    }
}
