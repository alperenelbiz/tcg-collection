import XCTest

/// The Sets list (phase 4A task 3): "My sets" and "All sets" (A27), the numbers of a master set (A26), the sort, the
/// search, and the list kept across a sidebar switch. A set's page (task 4, F8): its targets in card-number order, the
/// missing ones faded, an owned count control per cell, the filter and the search, and a cell's card page.
///
/// The fixture catalog has one set with cards per game, so these tests serve a copy of the fixtures with one more
/// Riftbound card, in Origins (24344), from `<root>/fixtures` (`-fixtures`): the index then has Radiance (24819: Kai'Sa,
/// Dockside Lock-Up, Calm Rune) and Origins (one card). The tests' own price files (day 2099-12-31, so the price step
/// downloads nothing) give Riftbound Dockside Lock-Up Normal $5.12 and Foil $9.50, Kai'Sa Normal $1.00, nothing else. With
/// Dockside Lock-Up Normal owned, Radiance's targets are Kai'Sa Normal, Dockside Normal (owned) and Foil, Calm Rune
/// Normal: `1 / 4`, `$10.50 + 1 without a price`; Origins: `0 / 1`, `1 without a price`.
final class SetsFlowTests: UITestCase {
    private static let radiance = 24819, origins = 24344

    /// Copies the fixtures into `<root>/fixtures` with the Origins card, and writes the price files.
    private func prepareSets(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtures = root.appending(path: "fixtures", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: Self.fixturesDirectory, to: fixtures)
        let file = fixtures.appending(path: "products-89.json")
        var products = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var results = try XCTUnwrap(products["results"] as? [[String: Any]])
        var card = try XCTUnwrap(results.first { $0["productId"] as? Int == 721337 })
        card["productId"] = 799001
        card["groupId"] = Self.origins
        card["name"] = "Origins Test Card"
        card["cleanName"] = "Origins Test Card"
        card["extendedData"] = (card["extendedData"] as? [[String: Any]] ?? []).map { field in
            field["name"] as? String == "Number" ? ["name": "Number", "displayName": "Number", "value": "001/298"] : field
        }
        results.append(card)
        products["results"] = results
        try JSONSerialization.data(withJSONObject: products).write(to: file)

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let none = #"{"day": "2099-12-31", "finishes": [], "rows": {}}"#
        let riftbound = """
        {"day": "2099-12-31", "finishes": ["Normal", "Foil"],
         "rows": {"721334": {"0": {"market": 5.12}, "1": {"market": 9.5}}, "721337": {"0": {"market": 1}}}}
        """
        for game in ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"] {
            try Data((game == "riftbound" ? riftbound : none).utf8).write(to: support.appending(path: "prices-\(game).json"))
        }
    }

    /// Launches on Sets with the copied fixtures and `rows` of Riftbound.
    private func launchSets(owning rows: [StoredRow], extra: [String] = []) throws -> XCUIApplication {
        try launch(game: "riftbound", extra: { root in
            ["-fixtures", root.appending(path: "fixtures").path, "-screen", "sets"] + extra
        }, fixtures: false) { root in
            try self.prepareSets(in: root)
            try self.writeCollection(rows, game: "riftbound", in: root)
        }
    }

    private static let dockside = StoredRow(productID: 721334, finish: "Normal", count: 1, condition: "", name: "Dockside Lock-Up")

    private var title: String { XCUIApplication(bundleIdentifier: Self.debugBundleID).windows.firstMatch.title }

    private func row(_ app: XCUIApplication, _ groupID: Int) -> XCUIElement { app.buttons["sets-row-\(groupID)"] }

    /// A segment of "My sets" / "All sets".
    private func scope(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let radio = app.radioButtons[title].firstMatch
        return radio.exists ? radio : element(app, "sets-scope").buttons[title].firstMatch
    }

    /// A segment of the set page's All / Missing / Owned.
    private func filter(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let radio = app.radioButtons[title].firstMatch
        return radio.exists ? radio : element(app, "set-filter").buttons[title].firstMatch
    }

    /// A set page's cell (the link over the picture and the texts).
    private func cell(_ app: XCUIApplication, _ productID: Int, _ finish: String = "Normal") -> XCUIElement {
        app.buttons["set-cell-\(productID)-\(finish)"]
    }

    /// The identifiers of the set page's cells, in reading order (the count controls left out).
    private func cellOrder(_ app: XCUIApplication) -> [String] {
        identifiersInOrder(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'set-cell-' AND NOT identifier "
            + "BEGINSWITH 'set-cell-minus-' AND NOT identifier BEGINSWITH 'set-cell-plus-'")))
    }

    private static let kaisa = 721337, docksideID = 721334, calmRune = 722282, originsCard = 799001

    /// The set page's cost line says `expected`, whole: its frame inside the window (the 900 pt test window).
    private func costIsWhole(_ app: XCUIApplication, _ expected: String) -> Bool {
        let cost = element(app, "set-cost")
        guard cost.exists, text(cost) == expected else { return false }
        return app.windows.firstMatch.frame.contains(cost.frame) && cost.frame.width > 0
    }

    /// A set cell's control, scrolled whole into the 450 pt window (the cost line puts the first row's controls at its
    /// bottom edge) and at rest, so a click lands on it.
    private func revealControl(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath,
                               line: UInt = #line) -> XCUIElement {
        // The page's container: XCUITest does not find the scroll view itself.
        let target = element(app, identifier), page = element(app, "set-screen"), window = app.windows.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no \(identifier)", file: file, line: line)
        for _ in 0..<15 where !window.frame.insetBy(dx: 0, dy: 8).contains(target.frame) {
            page.scroll(byDeltaX: 0, deltaY: -60)
        }
        var last = CGRect.null
        XCTAssertTrue(waitUntil {
            defer { last = target.frame }
            return target.frame == last
        }, "\(identifier) keeps moving", file: file, line: line)
        XCTAssertTrue(window.frame.contains(target.frame) && target.isHittable, "\(identifier) is not in the window",
                      file: file, line: line)
        return target
    }

    /// Opens Radiance's page from the list (My sets) and waits for its cells.
    private func openRadiance(_ app: XCUIApplication) {
        let radiance = row(app, Self.radiance)
        XCTAssertTrue(radiance.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntilSynced(app))
        radiance.click()
        XCTAssertTrue(element(app, "set-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(cell(app, Self.kaisa).waitForExistence(timeout: 10))
    }

    /// The group ids of the shown rows, top to bottom.
    private func rowOrder(_ app: XCUIApplication) -> [String] {
        identifiersInOrder(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sets-row-'")))
    }

    /// A27: one owned printing → "My sets" lists its set alone with `1 / 4` and the missing targets' cost; "All sets" lists
    /// Origins too; the subtitle follows; every text whole and the numbers in one right-aligned column. Then, with an
    /// empty collection, the list opens on all sets.
    func testTheSetsListShowsMySetsThenAll() throws {
        let app = try launchSets(owning: [Self.dockside])
        let radiance = row(app, Self.radiance)
        XCTAssertTrue(radiance.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { radiance.label == "Radiance, 1 of 4, $10.50 + 1 without a price" }, radiance.label)
        XCTAssertFalse(row(app, Self.origins).exists, "My sets lists a set with nothing owned")
        XCTAssertTrue(waitUntil { self.title.hasSuffix("1 set") }, title)
        XCTAssertFalse(element(app, "sets-note").exists, "a note on a settled catalog with its index")
        XCTAssertEqual(text(element(app, "sets-count-\(Self.radiance)")), "1 / 4")
        XCTAssertEqual(text(element(app, "sets-cost-\(Self.radiance)")), "$10.50 + 1 without a price")
        XCTAssertEqual(text(element(app, "sets-date-\(Self.radiance)")), "October 2026")
        XCTAssertEqual(scope(app, "My sets").value as? Int, 1, "the picker does not show My sets")
        shot("sets-01-my-sets")

        scope(app, "All sets").click()
        let origins = row(app, Self.origins)
        XCTAssertTrue(origins.waitForExistence(timeout: 10))
        XCTAssertEqual(origins.label, "Origins, 0 of 1, 1 without a price")
        XCTAssertTrue(waitUntil { self.title.hasSuffix("2 sets") }, title)
        XCTAssertEqual(rowOrder(app), ["sets-row-\(Self.radiance)", "sets-row-\(Self.origins)"])     // Newest first
        XCTAssertEqual(text(element(app, "sets-count-\(Self.origins)")), "0 / 1")
        XCTAssertEqual(text(element(app, "sets-cost-\(Self.origins)")), "1 without a price")
        XCTAssertEqual(text(element(app, "sets-date-\(Self.origins)")), "October 2025")
        // One column each: the counts end at one x, and so do the costs; both inside the window.
        let counts = [Self.radiance, Self.origins].map { element(app, "sets-count-\($0)").frame }
        let costs = [Self.radiance, Self.origins].map { element(app, "sets-cost-\($0)").frame }
        XCTAssertEqual(counts[0].maxX, counts[1].maxX, accuracy: 0.5, "\(counts)")
        XCTAssertEqual(costs[0].maxX, costs[1].maxX, accuracy: 0.5, "\(costs)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(costs[0].maxX, window.maxX)
        XCTAssertEqual(window.width, 900, accuracy: 0.5)
        shot("sets-02-all-sets")

        // Nothing owned: the list opens on all sets (A27), whatever was asked.
        quit(app)
        let root = try XCTUnwrap(self.root)
        try writeCollection([], game: "riftbound", in: root)
        let again = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "sets"])
        addTeardownBlock { @MainActor in
            again.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(row(again, Self.origins).waitForExistence(timeout: 20))
        XCTAssertTrue(row(again, Self.radiance).exists)
        XCTAssertEqual(row(again, Self.radiance).label, "Radiance, 0 of 4, $15.62 + 1 without a price")
        XCTAssertTrue(waitUntil { self.title.hasSuffix("2 sets") }, title)
        XCTAssertEqual(scope(again, "All sets").value as? Int, 1, "the picker does not show All sets")
        shot("sets-03-nothing-owned")
    }

    /// The sorts (Newest by default, Name, Most complete), a search by abbreviation with the subtitle `1 of 2 sets`, and
    /// the sentence when no set matches.
    func testSetsSortAndSearch() throws {
        let app = try launchSets(owning: [Self.dockside])
        XCTAssertTrue(row(app, Self.radiance).waitForExistence(timeout: 30))
        scope(app, "All sets").click()
        XCTAssertTrue(row(app, Self.origins).waitForExistence(timeout: 10))
        XCTAssertEqual(rowOrder(app), ["sets-row-\(Self.radiance)", "sets-row-\(Self.origins)"])
        element(app, "sets-sort").click()
        app.menuItems["Name"].firstMatch.click()
        XCTAssertTrue(waitUntil { self.rowOrder(app) == ["sets-row-\(Self.origins)", "sets-row-\(Self.radiance)"] },
                      "\(rowOrder(app))")
        shot("sets-04-by-name")
        element(app, "sets-sort").click()
        app.menuItems["Most complete"].firstMatch.click()
        XCTAssertTrue(waitUntil { self.rowOrder(app) == ["sets-row-\(Self.radiance)", "sets-row-\(Self.origins)"] },
                      "\(rowOrder(app))")

        let search = searchField(app)
        search.click()
        search.typeText("ogn")
        XCTAssertTrue(waitUntil { self.rowOrder(app) == ["sets-row-\(Self.origins)"] }, "\(rowOrder(app))")
        XCTAssertTrue(waitUntil { self.title.hasSuffix("1 of 2 sets") }, title)
        shot("sets-05-search-abbreviation")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("zzz")
        let empty = element(app, "empty-state")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(text(empty), "No set matches \"zzz\".")
        XCTAssertTrue(rowOrder(app).isEmpty)
        shot("sets-06-no-match")
    }

    /// The list's scope, sort and open set page survive a visit to another screen; Back returns to the list as it was; the
    /// set opened again starts on "All" (final fix A5).
    func testTheSetsScreenIsKeptAcrossASidebarSwitch() throws {
        let app = try launchSets(owning: [Self.dockside])
        XCTAssertTrue(row(app, Self.radiance).waitForExistence(timeout: 30))
        scope(app, "All sets").click()
        XCTAssertTrue(row(app, Self.origins).waitForExistence(timeout: 10))
        element(app, "sets-sort").click()
        app.menuItems["Name"].firstMatch.click()
        XCTAssertTrue(waitUntil { self.rowOrder(app) == ["sets-row-\(Self.origins)", "sets-row-\(Self.radiance)"] })
        row(app, Self.radiance).click()
        let page = element(app, "set-screen")
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Radiance") }, title)
        XCTAssertTrue(cell(app, Self.kaisa).waitForExistence(timeout: 10))
        filter(app, "Missing").click()
        XCTAssertTrue(waitUntil { !self.cell(app, Self.docksideID).exists }, "Missing still shows the owned printing")

        element(app, "sidebar-collection").click()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        element(app, "sidebar-sets").click()
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the set's page was not kept")
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Radiance") }, title)
        XCTAssertEqual(filter(app, "Missing").value as? Int, 1, "the page's filter was not kept")
        XCTAssertTrue(cell(app, Self.kaisa).exists)
        XCTAssertFalse(cell(app, Self.docksideID).exists)
        shot("sets-07-page-kept")

        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(row(app, Self.origins).waitForExistence(timeout: 10), "All sets was not kept")
        XCTAssertEqual(rowOrder(app), ["sets-row-\(Self.origins)", "sets-row-\(Self.radiance)"], "the Name sort was not kept")
        XCTAssertEqual(scope(app, "All sets").value as? Int, 1)

        // Final fix A5: the set opened again from the list starts on "All" with no search text.
        row(app, Self.radiance).click()
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue(cell(app, Self.docksideID).waitForExistence(timeout: 10), "the set did not start on All")
        XCTAssertEqual(filter(app, "All").value as? Int, 1, "the set did not start on All")
        shot("sets-07b-reopened-on-all")
    }

    /// A26, F8: Radiance's targets in card-number order (Kai'Sa 063, Dockside Lock-Up 136 Normal and Foil side by side,
    /// Calm Rune R02a); the owned one says `×1`, the missing ones `missing` (faded); the subtitle counts targets, the
    /// cost line (`set-cost`, whole at 900 pt) prices the missing ones. `+` on a missing cell makes it owned at once
    /// (label, subtitle, cost), the file has the row, and the list behind the page shows the new count after Back.
    func testASetPageFadesWhatIsMissing() throws {
        let app = try launchSets(owning: [Self.dockside])
        openRadiance(app)
        XCTAssertTrue(waitUntil { self.title == "Radiance – 1 of 4" }, title)
        XCTAssertTrue(waitUntil { self.costIsWhole(app, "$10.50 to complete + 1 without a price") },
                      "\(text(element(app, "set-cost"))) \(element(app, "set-cost").frame)")
        XCTAssertEqual(cellOrder(app), ["set-cell-\(Self.kaisa)-Normal", "set-cell-\(Self.docksideID)-Normal",
                                        "set-cell-\(Self.docksideID)-Foil", "set-cell-\(Self.calmRune)-Normal"])
        XCTAssertEqual(cell(app, Self.docksideID).label, "Dockside Lock-Up, ×1, $5.12")
        XCTAssertEqual(cell(app, Self.kaisa).label, "Kai'Sa, Rebel, missing, $1.00")
        XCTAssertEqual(cell(app, Self.docksideID, "Foil").label, "Dockside Lock-Up, missing, Foil, $9.50")
        XCTAssertEqual(cell(app, Self.calmRune).label, "Calm Rune (R02a), missing, no price")
        XCTAssertEqual(text(element(app, "set-cell-value-\(Self.docksideID)-Normal")), "1")
        XCTAssertEqual(text(element(app, "set-cell-value-\(Self.docksideID)-Foil")), "0")
        XCTAssertFalse(element(app, "set-note").exists, "a note on a settled catalog")
        XCTAssertEqual(filter(app, "All").value as? Int, 1)
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, accuracy: 0.5)
        shot("sets-08-set-page")

        revealControl(app, "set-cell-plus-\(Self.docksideID)-Foil").click()
        let foil = cell(app, Self.docksideID, "Foil")
        XCTAssertTrue(waitUntil { foil.label == "Dockside Lock-Up, ×1, Foil, $9.50" }, foil.label)
        XCTAssertTrue(waitUntil { self.title == "Radiance – 2 of 4" }, title)
        XCTAssertTrue(waitUntil { self.costIsWhole(app, "$1.00 to complete + 1 without a price") },
                      text(element(app, "set-cost")))
        XCTAssertEqual(text(element(app, "set-cell-value-\(Self.docksideID)-Foil")), "1")
        let added = StoredRow(productID: Self.docksideID, finish: "Foil", count: 1, name: "Dockside Lock-Up")
        XCTAssertTrue(waitUntil { (try? self.storedCollection(game: "riftbound"))?.contains(added) == true },
                      "\(String(describing: try? storedCollection(game: "riftbound")))")
        shot("sets-09-set-page-after-plus")

        app.toolbars.buttons["Back"].click()
        let radiance = row(app, Self.radiance)
        XCTAssertTrue(radiance.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { radiance.label == "Radiance, 2 of 4, $1.00 + 1 without a price" }, radiance.label)
        XCTAssertEqual(text(element(app, "sets-count-\(Self.radiance)")), "2 / 4")
    }

    /// All / Missing / Owned and the search (the product's name), with their sentences: `No card matches "<text>".`; on
    /// Origins (nothing owned) "No card of this set in your collection yet.", and once its one card is added, "This set
    /// is complete.".
    func testASetPagesFilterAndSearch() throws {
        let app = try launchSets(owning: [Self.dockside])
        openRadiance(app)
        filter(app, "Missing").click()
        XCTAssertTrue(waitUntil {
            self.cellOrder(app) == ["set-cell-\(Self.kaisa)-Normal", "set-cell-\(Self.docksideID)-Foil",
                                    "set-cell-\(Self.calmRune)-Normal"]
        }, "\(cellOrder(app))")
        shot("sets-10-missing")
        filter(app, "Owned").click()
        XCTAssertTrue(waitUntil { self.cellOrder(app) == ["set-cell-\(Self.docksideID)-Normal"] }, "\(cellOrder(app))")
        // The subtitle and the cost line are the set's, whatever the filter.
        XCTAssertTrue(title.hasSuffix("1 of 4"), title)
        XCTAssertTrue(costIsWhole(app, "$10.50 to complete + 1 without a price"), text(element(app, "set-cost")))

        let search = searchField(app)
        search.click()
        search.typeText("calm")
        let empty = element(app, "empty-state")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(text(empty), "No card matches \"calm\".")
        XCTAssertTrue(cellOrder(app).isEmpty)
        // With the search field active, the cost line is still whole, and still the set's.
        XCTAssertTrue(costIsWhole(app, "$10.50 to complete + 1 without a price"),
                      "\(text(element(app, "set-cost"))) \(element(app, "set-cost").frame)")
        shot("sets-11-no-match")
        // While the search field is active the picker is in the toolbar's overflow (900 pt): the text changes instead.
        search.typeKey("a", modifierFlags: .command)
        search.typeText("lock")
        XCTAssertTrue(waitUntil { self.cellOrder(app) == ["set-cell-\(Self.docksideID)-Normal"] }, "\(cellOrder(app))")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])

        // Origins: nothing owned.
        app.toolbars.buttons["Back"].click()
        scope(app, "All sets").click()
        let origins = row(app, Self.origins)
        XCTAssertTrue(origins.waitForExistence(timeout: 10))
        origins.click()
        XCTAssertTrue(cell(app, Self.originsCard).waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.title == "Origins – 0 of 1" }, title)
        XCTAssertTrue(waitUntil { self.costIsWhole(app, "1 without a price") }, text(element(app, "set-cost")))
        filter(app, "Owned").click()
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(text(empty), "No card of this set in your collection yet.")
        shot("sets-12-nothing-owned")
        filter(app, "All").click()
        let plus = revealControl(app, "set-cell-plus-\(Self.originsCard)-Normal")
        plus.click()
        XCTAssertTrue(waitUntil { self.title == "Origins – 1 of 1" }, title)
        XCTAssertFalse(element(app, "set-cost").exists, "a cost line on a complete set")
        filter(app, "Missing").click()
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(text(empty), "This set is complete.")
        shot("sets-13-complete")
    }

    /// Review Focus 4: five fast `+` on a set cell and Cmd+Q at once (`-writeDelay 1500`): the quit waits for the writes,
    /// and the file has 5. The cell's state follows the count at once.
    func testFastClicksOnASetCellAndAQuitReachTheFile() throws {
        let app = try launchSets(owning: [Self.dockside], extra: ["-writeDelay", "1500"])
        openRadiance(app)
        let plus = revealControl(app, "set-cell-plus-\(Self.kaisa)-Normal")
        plus.doubleClick()
        plus.click()
        plus.click()
        plus.click()
        XCTAssertTrue(waitUntil(timeout: 3) { self.text(self.element(app, "set-cell-value-\(Self.kaisa)-Normal")) == "5" },
                      text(element(app, "set-cell-value-\(Self.kaisa)-Normal")))
        XCTAssertEqual(cell(app, Self.kaisa).label, "Kai'Sa, Rebel, ×5, $1.00")
        let five = StoredRow(productID: Self.kaisa, finish: "Normal", count: 5, name: "Kai'Sa, Rebel")
        XCTAssertFalse(try storedCollection(game: "riftbound").contains(five), "the write was done before the quit")
        quit(app)                                                // at once: the last write is still waiting
        XCTAssertEqual(try storedCollection(game: "riftbound"), [Self.dockside, five])
    }

    /// A click on a cell opens the card page on that printing in Sets' stack; Back returns to the set at its filter.
    func testASetCellOpensItsCardPage() throws {
        let app = try launchSets(owning: [Self.dockside])
        openRadiance(app)
        filter(app, "Missing").click()
        let foil = cell(app, Self.docksideID, "Foil")
        XCTAssertTrue(waitUntil { !self.cell(app, Self.docksideID).exists })
        foil.click()
        let cardTitle = app.staticTexts["card-title"]
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(text(cardTitle), "Dockside Lock-Up")
        let facts = app.staticTexts["card-facts-line"]
        XCTAssertTrue(waitUntil { self.text(facts).contains("136/167") }, text(facts))
        XCTAssertTrue(element(app, "count-plus-Foil").exists)
        shot("sets-14-card-page")

        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(foil.waitForExistence(timeout: 10))
        XCTAssertEqual(filter(app, "Missing").value as? Int, 1, "the page's filter was not kept")
        XCTAssertFalse(cell(app, Self.docksideID).exists)
    }
}
