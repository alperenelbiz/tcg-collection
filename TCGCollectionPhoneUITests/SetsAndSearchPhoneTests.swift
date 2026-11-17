import XCTest

/// Phase 6A task 7: the Sets tab (the list's two-line rows, `sets-more` with the scope and Sort, a set's page with
/// `set-more` and All / Missing / Owned, R3's totals lines) and the search tab (the tab's search field, the Set / Rarity /
/// Type menus in `catalog-more`, "Clear" in the bar while a filter is on).
///
/// As the Mac's `SetsFlowTests`, the Sets tests serve a copy of the fixtures with one more Riftbound card, in Origins
/// (24344), from `<root>/fixtures`, and their own price files (day 2099-12-31: the price step downloads nothing): Riftbound
/// Dockside Lock-Up Normal $5.12 and Foil $9.50, Kai'Sa Normal $1.00. With Calm Rune owned, Radiance's targets are Kai'Sa
/// Normal, Dockside Normal and Foil, Calm Rune Normal (owned): `1 / 4`.
final class SetsAndSearchPhoneTests: PhoneUITestCase {
    private static let radiance = 24819, origins = 24344
    private static let kaisa = 721337, calmRune = 722282
    /// A set name of 68 characters: wider than the iPhone 17's row, so it must be cut (final fix wave item 9; 40
    /// characters fit and proved nothing).
    private static let longName = "Origins of the Very Long Riftbound Expansions and Their Many Friends"

    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    /// Copies the fixtures into `<root>/fixtures` with the Origins card (named `originsName` in the group list), and
    /// writes the price files.
    private func prepareSets(in root: URL, originsName: String? = nil) throws {
        let fixtures = root.appending(path: "fixtures", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: Self.fixturesDirectory, to: fixtures)
        let file = fixtures.appending(path: "products-89.json")
        var products = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var results = try XCTUnwrap(products["results"] as? [[String: Any]])
        var card = try XCTUnwrap(results.first { $0["productId"] as? Int == Self.kaisa })
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

        if let originsName {
            let groupsFile = fixtures.appending(path: "groups-89.json")
            var groups = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: groupsFile)) as? [String: Any])
            groups["results"] = try XCTUnwrap(groups["results"] as? [[String: Any]]).map { group in
                var group = group
                if group["groupId"] as? Int == Self.origins { group["name"] = originsName }
                return group
            }
            try JSONSerialization.data(withJSONObject: groups).write(to: groupsFile)
        }

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

    /// Launches Riftbound on the copied fixtures with `rows`.
    private func launchSets(owning rows: [[String: Any]], originsName: String? = nil) -> XCUIApplication {
        launch(game: "riftbound", fixtures: { $0.appending(path: "fixtures") }) { root in
            try self.prepareSets(in: root, originsName: originsName)
            if !rows.isEmpty { try self.writeCollection(rows, game: "riftbound") }
        }
    }

    private static let calmRuneRow: [String: Any] = ["productID": calmRune, "finish": "Normal", "count": 1,
                                                     "condition": "", "name": "Calm Rune (R02a)"]

    /// Opens a screen's "…" menu.
    private func openMore(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let more = element(app, identifier)
        XCTAssertTrue(more.waitForExistence(timeout: 20), "no \(identifier)", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 10) { more.isHittable }, "\(identifier) is not hittable", file: file, line: line)
        more.tap()
    }

    /// Taps a menu item by its title.
    private func choose(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no menu item \(title)", file: file, line: line)
        item.tap()
    }

    /// Swipes the screen up until `target` is hittable.
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, in container: XCUIElement) {
        for _ in 0..<6 where !target.isHittable {
            container.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// Sets → "My sets" (Radiance alone, `1 / 4`, its date and cost under the name) → Radiance's page (`1 of 4` above the
    /// cost line) → `set-more` → Missing → `+` on Kai'Sa's faded cell → `2 of 4`, and the list says `2 / 4`.
    func testTheSetsTab() {
        let app = launchSets(owning: [Self.calmRuneRow])
        let sets = tab(app, "Sets")
        XCTAssertTrue(sets.waitForExistence(timeout: 20), "no Sets tab")
        sets.tap()
        let row = app.buttons["sets-row-\(Self.radiance)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Radiance row")
        XCTAssertFalse(app.buttons["sets-row-\(Self.origins)"].exists, "My sets lists Origins")
        let totals = element(app, "sets-totals")
        XCTAssertTrue(waitUntil(timeout: 20) { totals.exists && self.text(totals) == "1 set" }, text(totals))
        let count = element(app, "sets-count-\(Self.radiance)")
        XCTAssertTrue(waitUntil(timeout: 20) { count.exists && self.text(count) == "1 / 4" }, text(count))
        // Two lines: the name and the count on line 1, the date and the cost on line 2.
        let date = element(app, "sets-date-\(Self.radiance)"), cost = element(app, "sets-cost-\(Self.radiance)")
        XCTAssertTrue(date.exists && cost.exists, "no date or cost")
        XCTAssertGreaterThanOrEqual(date.frame.minY, count.frame.maxY - 0.5, "the date is not under the count line")
        XCTAssertGreaterThanOrEqual(cost.frame.minY, count.frame.maxY - 0.5, "the cost is not under the count line")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(row.frame), "the row leaves the screen: \(row.frame)")
        XCTAssertTrue(screen.contains(cost.frame), "the cost leaves the screen: \(cost.frame)")
        // The scope and Sort are in the "…" menu.
        openMore(app, "sets-more")
        XCTAssertTrue(app.buttons["All sets"].firstMatch.waitForExistence(timeout: 5), "no All sets in the menu")
        XCTAssertTrue(element(app, "sets-sort").exists, "no Sort in the menu")
        choose(app, "All sets")
        XCTAssertTrue(app.buttons["sets-row-\(Self.origins)"].firstMatch.waitForExistence(timeout: 10), "All sets lacks Origins")
        XCTAssertTrue(waitUntil(timeout: 10) { self.text(totals) == "2 sets" }, text(totals))
        openMore(app, "sets-more")
        choose(app, "My sets")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["sets-row-\(Self.origins)"].exists }, "My sets lists Origins")
        shot("sets-01-list")

        row.tap()
        XCTAssertTrue(element(app, "set-screen").waitForExistence(timeout: 10), "no set page")
        let pageTotals = element(app, "set-totals")
        XCTAssertTrue(waitUntil(timeout: 20) { pageTotals.exists && self.text(pageTotals) == "1 of 4" }, text(pageTotals))
        let pageCost = element(app, "set-cost")
        XCTAssertTrue(waitUntil(timeout: 10) { pageCost.exists && self.text(pageCost) == "$15.62 to complete" },
                      text(pageCost))
        XCTAssertLessThanOrEqual(pageTotals.frame.maxY, pageCost.frame.minY + 0.5, "the totals are not above the cost line")
        openMore(app, "set-more")
        choose(app, "Missing")
        let calm = app.buttons["set-cell-\(Self.calmRune)-Normal"]
        XCTAssertTrue(waitUntil(timeout: 10) { !calm.exists }, "Missing shows an owned cell")
        let kaisa = app.buttons["set-cell-\(Self.kaisa)-Normal"].firstMatch
        XCTAssertTrue(kaisa.waitForExistence(timeout: 10), "no Kai'Sa cell")
        XCTAssertEqual(kaisa.label, "Kai'Sa, Rebel, missing, $1.00")
        let plus = app.buttons["set-cell-plus-\(Self.kaisa)-Normal"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no + on Kai'Sa")
        reveal(app, plus, in: element(app, "set-screen"))
        XCTAssertGreaterThanOrEqual(plus.frame.height, 43.5, "the + is not a 44 pt target: \(plus.frame)")
        shot("sets-02-page")
        plus.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.text(pageTotals) == "2 of 4" }, text(pageTotals))
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["set-cell-\(Self.kaisa)-Normal"].exists },
                      "Kai'Sa stays under Missing")
        shot("sets-03-page-after-plus")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.text(count) == "2 / 4" }, text(count))
    }

    /// The search tab: type "rune" → Calm Rune's cell → its card page → back: the text is kept. `catalog-more` → Rarity →
    /// Epic: no card matches; "Clear" in the bar brings Calm Rune back.
    func testTheSearchTab() {
        let app = launch(game: "riftbound")
        let search = tab(app, "Search")
        XCTAssertTrue(search.waitForExistence(timeout: 20), "no search tab")
        search.tap()
        XCTAssertTrue(app.buttons["card-cell-dockside lock up"].firstMatch.waitForExistence(timeout: 30), "no catalog")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        field.tap()
        field.typeText("rune")
        let calm = app.buttons["card-cell-calm rune"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["card-cell-dockside lock up"].exists }, "rune did not filter")
        XCTAssertTrue(calm.waitForExistence(timeout: 10), "no Calm Rune")
        let totals = element(app, "catalog-totals")
        XCTAssertTrue(waitUntil(timeout: 10) { totals.exists && self.text(totals) == "1 card" }, text(totals))
        shot("search-01")
        // The keyboard can cover the cell: dismiss it first.
        if app.keyboards.firstMatch.exists { app.buttons["Search"].firstMatch.tap() }
        XCTAssertTrue(waitUntil(timeout: 10) { calm.isHittable }, "Calm Rune is not hittable")
        calm.tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "card-page").exists }, "the card page stays")
        XCTAssertTrue(calm.waitForExistence(timeout: 10), "Calm Rune is gone after Back")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "rune", "the search text is not kept")
        XCTAssertFalse(app.buttons["card-cell-dockside lock up"].exists, "the search is not applied after Back")

        XCTAssertFalse(element(app, "catalog-clear-filters").exists, "Clear without a filter")
        // The "…" menu stays in the bar while the search is presented (`searchPresentationToolbarBehavior`).
        openMore(app, "catalog-more")
        let rarity = app.buttons["filter-rarity"].firstMatch
        XCTAssertTrue(rarity.waitForExistence(timeout: 5), "no Rarity in the menu")
        XCTAssertTrue(app.buttons["filter-set"].firstMatch.exists, "no Set in the menu")
        XCTAssertTrue(app.buttons["filter-type"].firstMatch.exists, "no Type in the menu")
        rarity.tap()
        choose(app, "Epic")
        let empty = element(app, "empty-state")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "Epic did not filter")
        XCTAssertFalse(calm.exists, "Calm Rune under Epic")
        let clear = element(app, "catalog-clear-filters")
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "no Clear while a filter is on")
        shot("search-02-filter")
        clear.tap()
        XCTAssertTrue(calm.waitForExistence(timeout: 10), "Clear did not bring Calm Rune back")
        XCTAssertFalse(element(app, "catalog-clear-filters").exists, "Clear stays")
    }

    /// A 68-character set name: the name is cut before the count (its frame ends left of `sets-count-<id>`), and the row,
    /// its count and its cost stay inside the screen.
    func testALongSetNameTruncates() {
        let app = launchSets(owning: [], originsName: Self.longName)
        XCTAssertGreaterThanOrEqual(Self.longName.count, 60)
        tab(app, "Sets").tap()
        let row = app.buttons["sets-row-\(Self.origins)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no long-named row")
        XCTAssertTrue(row.label.hasPrefix(Self.longName), row.label)
        let count = element(app, "sets-count-\(Self.origins)"), cost = element(app, "sets-cost-\(Self.origins)")
        XCTAssertTrue(waitUntil(timeout: 20) { count.exists && self.text(count) == "0 / 1" }, text(count))
        let name = element(app, "sets-name-\(Self.origins)")
        XCTAssertTrue(name.exists, "no set name")
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(name.frame.maxX, count.frame.minX,
                                 "the name \(name.frame) runs into the count \(count.frame)")
        XCTAssertTrue(screen.contains(name.frame), "the name leaves the screen: \(name.frame) in \(screen)")
        XCTAssertTrue(screen.contains(row.frame), "the row leaves the screen: \(row.frame) in \(screen)")
        XCTAssertTrue(screen.contains(count.frame), "the count leaves the screen: \(count.frame)")
        XCTAssertTrue(cost.exists && screen.contains(cost.frame), "the cost leaves the screen: \(cost.frame)")
        shot("sets-04-long-name")
    }
}
