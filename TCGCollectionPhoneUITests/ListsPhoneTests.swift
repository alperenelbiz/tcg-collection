import XCTest

/// Phase 6A task 3: the list tabs on the iPhone (A50, A51): Collection and For Sale behind one switch, Sold as an action
/// sheet, each list screen's "…" menu, the PDF through the system's share sheet. The fixture prices give Dockside Lock-Up
/// (721334) Normal $5.12; Calm Rune (R02a) (722282) has none.
final class ListsPhoneTests: PhoneUITestCase {
    /// Two printings owned (Dockside Lock-Up ×2, Calm Rune ×1), one copy of Dockside Lock-Up for sale.
    private static let saleFile = """
        {"version": 1,
         "collection": [{"productID": 721334, "finish": "Normal", "count": 2, "condition": "", "name": "Dockside Lock-Up"},
                        {"productID": 722282, "finish": "Normal", "count": 1, "condition": "", "name": "Calm Rune (R02a)"}],
         "forSale": [{"productID": 721334, "finish": "Normal", "count": 1, "name": "Dockside Lock-Up"}]}
        """

    /// Two cards wanted: Dockside Lock-Up (priced) and Calm Rune (no price): by name Calm Rune is first.
    private static let wantedFile = """
        {"version": 1, "collection": [],
         "wanted": [{"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "count": 3},
                    {"cardKey": "calm rune", "name": "Calm Rune", "count": 2}]}
        """

    private func writeUserFile(_ json: String, game: String, root: URL) throws {
        let folder = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "\(game).json"))
    }

    /// The JSON object of `<root>/user/<game>.json` as the app last wrote it; nil with no file.
    private func storedUserFile(game: String) throws -> [String: Any]? {
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "\(game).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    }

    /// The cells whose identifier starts with `prefix` (minus the count controls' and Sold's), in reading order: top to
    /// bottom, then left to right, from one snapshot.
    private func cells(_ app: XCUIApplication, _ prefix: String, excluding: [String] = []) -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        var found: [(String, CGRect)] = []
        func walk(_ element: any XCUIElementSnapshot) {
            let id = element.identifier
            if id.hasPrefix(prefix), !excluding.contains(where: { id.hasPrefix($0) }), element.elementType == .button {
                found.append((id, element.frame))
            }
            element.children.forEach(walk)
        }
        walk(snapshot)
        var seen = Set<String>()
        return found
            .sorted { abs($0.1.minY - $1.1.minY) > 8 ? $0.1.minY < $1.1.minY : $0.1.minX < $1.1.minX }
            .map(\.0)
            .filter { seen.insert($0).inserted }
    }

    private func collectionCells(_ app: XCUIApplication) -> [String] { cells(app, "collection-cell-") }

    private func forSaleCells(_ app: XCUIApplication) -> [String] {
        cells(app, "for-sale-cell-")
    }

    private func wantedCells(_ app: XCUIApplication) -> [String] {
        cells(app, "wanted-cell-", excluding: ["wanted-cell-minus-", "wanted-cell-value-", "wanted-cell-plus-"])
    }

    /// R3: the totals line `<screen>-totals` is hittable, wholly inside the screen, and says `expected`.
    private func assertTotals(_ app: XCUIApplication, _ identifier: String, _ expected: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let totals = app.staticTexts[identifier].firstMatch
        XCTAssertTrue(totals.waitForExistence(timeout: 20), "no \(identifier)", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(totals) == expected }, "\(identifier): \(text(totals))",
                      file: file, line: line)
        XCTAssertTrue(totals.isHittable, "\(identifier) is not hittable", file: file, line: line)
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(totals.frame), "\(identifier) \(totals.frame) is not inside \(screen)",
                      file: file, line: line)
    }

    /// Opens a list screen's "…" menu.
    private func openMore(_ app: XCUIApplication, _ screen: String) {
        let more = element(app, "\(screen)-more")
        XCTAssertTrue(more.waitForExistence(timeout: 20), "no \(screen)-more")
        XCTAssertTrue(waitUntil(timeout: 10) { more.isHittable }, "\(screen)-more is not hittable")
        more.tap()
    }

    /// A50: the Collection tab's switch shows For Sale with its one cell and the Collection with two. Each root has its
    /// title, the game menu, the "…" menu and the gear.
    func testCollectionAndForSaleShareOneTab() throws {
        let app = launch(prepare: { root in try self.writeUserFile(Self.saleFile, game: "riftbound", root: root) })
        let switcher = element(app, "collection-switch")
        XCTAssertTrue(switcher.waitForExistence(timeout: 20), "no Collection / For Sale switch")
        XCTAssertTrue(waitUntil(timeout: 30) { self.collectionCells(app).count == 2 }, "\(collectionCells(app))")
        XCTAssertEqual(Set(collectionCells(app)), ["collection-cell-721334-Normal", "collection-cell-722282-Normal"])
        XCTAssertTrue(app.navigationBars.staticTexts["Collection"].firstMatch.waitForExistence(timeout: 10), "no title Collection")
        XCTAssertTrue(element(app, "game-menu").exists, "no game menu")
        XCTAssertTrue(element(app, "collection-more").exists, "no … menu")
        XCTAssertTrue(element(app, "settings-button").exists, "no gear")
        assertTotals(app, "collection-totals", "3 copies · 2 printings")
        shot("lists-01-collection")

        switcher.buttons["For Sale"].tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.forSaleCells(app) == ["for-sale-cell-721334-Normal"] }, "\(forSaleCells(app))")
        XCTAssertTrue(element(app, "for-sale-sold-721334-Normal").exists, "no Sold")
        XCTAssertTrue(app.navigationBars.staticTexts["For Sale"].firstMatch.waitForExistence(timeout: 10), "no title For Sale")
        XCTAssertTrue(element(app, "for-sale-more").exists, "no … menu")
        assertTotals(app, "for-sale-totals", "1 copy · 1 printing · $5.12")
        XCTAssertTrue(app.tabBars.buttons["Collection"].firstMatch.isSelected, "For Sale is not in the Collection tab")
        shot("lists-02-for-sale")

        element(app, "collection-switch").buttons["Collection"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.collectionCells(app).count == 2 }, "\(collectionCells(app))")
    }

    /// C7 on the iPhone: For Sale → "Sold" → the action sheet's "Sold 1": the file has one sold record.
    func testSoldOnTheIPhone() throws {
        let app = launch(extra: ["-screen", "for-sale"],
                         prepare: { root in try self.writeUserFile(Self.saleFile, game: "riftbound", root: root) })
        let sold = element(app, "for-sale-sold-721334-Normal")
        XCTAssertTrue(sold.waitForExistence(timeout: 30), "no Sold")
        XCTAssertTrue(waitUntil(timeout: 20) { sold.isHittable }, "Sold is not hittable")
        sold.tap()
        let one = app.buttons["Sold 1"].firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 10), "no Sold 1")
        shot("lists-05-sold-dialog")
        one.tap()
        XCTAssertTrue(waitUntil(timeout: 20) {
            ((try? self.storedUserFile(game: "riftbound"))?["sold"] as? [[String: Any]])?.count == 1
        }, "\(String(describing: try? storedUserFile(game: "riftbound")))")
        let record = try XCTUnwrap((try storedUserFile(game: "riftbound"))?["sold"] as? [[String: Any]]).first
        XCTAssertEqual(record?["productID"] as? Int, 721334)
        XCTAssertEqual(record?["count"] as? Int, 1)
        XCTAssertTrue(waitUntil(timeout: 10) { self.forSaleCells(app).isEmpty }, "\(forSaleCells(app))")
    }

    /// Wanted's "…" menu: Sort → "Price high to low" puts the priced card first (by name it is second).
    func testWantedAndItsMenu() throws {
        let app = launch(extra: ["-screen", "wanted"],
                         prepare: { root in try self.writeUserFile(Self.wantedFile, game: "riftbound", root: root) })
        let dockside = app.buttons["wanted-cell-dockside lock up"].firstMatch
        XCTAssertTrue(dockside.waitForExistence(timeout: 30), "no Wanted cell")
        XCTAssertTrue(waitUntil(timeout: 30) { dockside.label.contains("$5.12") }, dockside.label)
        XCTAssertEqual(wantedCells(app), ["wanted-cell-calm rune", "wanted-cell-dockside lock up"])
        XCTAssertTrue(app.navigationBars.staticTexts["Wanted"].firstMatch.waitForExistence(timeout: 10), "no title Wanted")
        assertTotals(app, "wanted-totals", "5 copies · 2 cards · $15.36 + 1 without a price")
        openMore(app, "wanted")
        let sort = app.buttons["wanted-sort"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5), "no Sort in the menu")
        XCTAssertTrue(app.buttons["wanted-pdf"].firstMatch.exists, "no Make PDF… in the menu")
        sort.tap()
        let high = app.buttons["Price high to low"].firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 5), "no Price high to low")
        high.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            self.wantedCells(app) == ["wanted-cell-dockside lock up", "wanted-cell-calm rune"]
        }, "\(wantedCells(app))")
        shot("lists-03-wanted")
    }

    /// C10 on the iPhone: "Make PDF…" in Wanted's "…" menu makes the PDF, then the system's share sheet opens with it.
    func testMakeAPDFOpensTheShareSheet() throws {
        let app = launch(extra: ["-screen", "wanted"],
                         prepare: { root in try self.writeUserFile(Self.wantedFile, game: "riftbound", root: root) })
        let dockside = app.buttons["wanted-cell-dockside lock up"].firstMatch
        XCTAssertTrue(dockside.waitForExistence(timeout: 30), "no Wanted cell")
        XCTAssertTrue(waitUntil(timeout: 30) { dockside.label.contains("$5.12") }, dockside.label)
        openMore(app, "wanted")
        let pdf = app.buttons["wanted-pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5), "no Make PDF… in the menu")
        XCTAssertTrue(waitUntil(timeout: 10) { pdf.isEnabled }, "Make PDF… is off")
        pdf.tap()
        // The system's share sheet on iOS 27: UIActivityViewController's view, `ActivityListView`.
        let share = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 30), "no share sheet: \(app.debugDescription)")
        shot("lists-04-share")
        // The sheet's own close button (an "×", label "Close").
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.exists, "no Close on the share sheet")
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !share.exists }, "the share sheet did not close")
        XCTAssertTrue(element(app, "wanted-more").waitForExistence(timeout: 5))
    }
}
