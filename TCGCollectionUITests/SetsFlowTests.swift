import XCTest

/// The Sets list (phase 4A task 3): "My sets" and "All sets" (A27), the numbers of a master set (A26), the sort, the
/// search, and the list kept across a sidebar switch.
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
    private func launchSets(owning rows: [StoredRow]) throws -> XCUIApplication {
        try launch(game: "riftbound", extra: { root in
            ["-fixtures", root.appending(path: "fixtures").path, "-screen", "sets"]
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

    /// The list's scope, sort and open set page survive a visit to another screen; Back returns to the list as it was.
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

        element(app, "sidebar-collection").click()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        element(app, "sidebar-sets").click()
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the set's page was not kept")
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Radiance") }, title)
        shot("sets-07-page-kept")

        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(row(app, Self.origins).waitForExistence(timeout: 10), "All sets was not kept")
        XCTAssertEqual(rowOrder(app), ["sets-row-\(Self.origins)", "sets-row-\(Self.radiance)"], "the Name sort was not kept")
        XCTAssertEqual(scope(app, "All sets").value as? Int, 1)
    }
}
