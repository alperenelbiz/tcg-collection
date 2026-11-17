import XCTest

/// Phase 6A task 6: the card page on the iPhone (A51; the look's "Card page" and "Touch targets"): one scrolling column,
/// each finish as two rows (the name and the price; then the Owned and For sale controls), 44 pt controls, the price
/// history full width with its 180 pt plot, and the page's last content reachable above the tab bar and the status line.
final class CardPagePhoneTests: PhoneUITestCase {
    private static let panther = 719834, dockside = 721334

    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    /// Opens the card of `cardKey` from the search tab (All cards).
    private func openFromSearch(_ app: XCUIApplication, _ cardKey: String, file: StaticString = #filePath, line: UInt = #line) {
        let search = tab(app, "Search")
        XCTAssertTrue(search.waitForExistence(timeout: 20), "no search tab", file: file, line: line)
        search.tap()
        let cell = app.buttons["card-cell-\(cardKey)"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "no catalog cell \(cardKey)", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 30) { cell.isHittable }, "the catalog cell is not hittable", file: file, line: line)
        cell.tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page", file: file, line: line)
    }

    /// Opens a Collection cell's card page (`collection-cell-<productID>-<finish>`).
    private func openFromCollection(_ app: XCUIApplication, _ cell: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[cell].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30), "no \(cell)", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 30) { button.isHittable }, "\(cell) is not hittable", file: file, line: line)
        button.tap()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page", file: file, line: line)
    }

    /// Scrolls the card page to its end: swipes until `last` stops moving.
    private func scrollToEnd(_ app: XCUIApplication, last: XCUIElement) {
        let page = element(app, "card-page")
        var previous = CGFloat.infinity
        for _ in 0..<8 {
            page.swipeUp(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let y = last.frame.maxY
            if abs(y - previous) < 1 { break }
            previous = y
        }
    }

    /// The carried concern of tasks 2 and 5: at the end of the page its last element is wholly above the tab bar and,
    /// when it shows, the status line.
    private func assertAboveTheBars(_ app: XCUIApplication, _ last: XCUIElement, file: StaticString = #filePath,
                                    line: UInt = #line) {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.exists, "no tab bar", file: file, line: line)
        var limit = bar.frame.minY
        let status = app.staticTexts["status-inset"].firstMatch
        if status.exists, status.frame.height > 0 { limit = min(limit, status.frame.minY) }
        XCTAssertLessThanOrEqual(last.frame.maxY, limit + 0.5,
                                 "the page's last content \(last.frame) is under the bars (top \(limit))", file: file, line: line)
    }

    /// All cards → Calm Rune: the picture, `card-owned`, a 44 pt `+`, the price history below them, and at the end of the
    /// page the block (Calm Rune's last content: no rules text, one printing) above the tab bar.
    func testACardPageOnTheIPhone() {
        let app = launch(game: "riftbound")
        openFromSearch(app, "calm rune")
        let owned = app.staticTexts["card-owned"].firstMatch
        XCTAssertTrue(owned.waitForExistence(timeout: 10), "no card-owned")
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(owned) == "In your collection: 0" }, text(owned))
        let plus = app.buttons["count-plus-Normal"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no count control")
        XCTAssertGreaterThanOrEqual(plus.frame.height, 44, "the + is not a 44 pt target: \(plus.frame)")
        XCTAssertGreaterThanOrEqual(plus.frame.width, 44, "the + is not a 44 pt target: \(plus.frame)")
        let sale = app.buttons["sale-plus-Normal"].firstMatch
        XCTAssertGreaterThanOrEqual(sale.frame.height, 44, "the for-sale + is not a 44 pt target: \(sale.frame)")
        // Two rows: the finish name above its controls.
        let name = element(app, "card-finish-Normal")
        XCTAssertTrue(name.exists, "no finish name")
        XCTAssertLessThanOrEqual(name.frame.maxY, plus.frame.minY, "the finish name is not above its controls")
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(sale.frame.maxX, screen.maxX, "the for-sale control leaves the screen")
        let block = element(app, "price-history")
        XCTAssertTrue(block.waitForExistence(timeout: 10), "no price history")
        XCTAssertGreaterThanOrEqual(block.frame.minY, plus.frame.maxY, "the price history is not below the controls")
        shot("card-01")
        scrollToEnd(app, last: block)
        XCTAssertTrue(waitUntil(timeout: 5) { block.isHittable }, "the price history is not on screen")
        // Full width: the block spans the column (the screen less the margins).
        XCTAssertGreaterThanOrEqual(block.frame.width, screen.width - 2 * 16 - 1, "the block is not full width: \(block.frame)")
        assertAboveTheBars(app, block)
        shot("card-02-chart")
    }

    /// Review Focus 4: the Mac's long made-up finish ("1st Edition Holofoil", no price) on the phone: every control of
    /// its row is inside the screen, the window is the screen's width, and the other printings (the page's last content)
    /// end above the tab bar.
    func testALongFinishFitsThePhone() throws {
        let long = "1st Edition Holofoil"
        let app = launch(game: "yu-gi-oh", prepare: { root in
            try self.writePinPrices(in: root, longFinish: true)
            try self.writeCollection([["productID": Self.panther, "finish": "Unlimited", "count": 1, "condition": "",
                                       "name": "Swiftwind Panther Warrior"]], game: "yu-gi-oh")
        })
        openFromCollection(app, "collection-cell-\(Self.panther)-Unlimited")
        let name = element(app, "card-finish-\(long)")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no long finish line")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.width, app.frame.width, accuracy: 1, "the window is not the screen's width")
        for finish in ["1st Edition", "Unlimited", long] {
            for control in ["count-minus-", "count-plus-", "sale-minus-", "sale-plus-"].map({ $0 + finish }) {
                let element = app.buttons[control].firstMatch
                XCTAssertTrue(element.exists, "no \(control)")
                XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX, "\(control) leaves the screen: \(element.frame)")
                XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX, "\(control) leaves the screen: \(element.frame)")
                XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(control) is not 44 pt tall: \(element.frame)")
            }
        }
        XCTAssertLessThanOrEqual(name.frame.maxX, window.maxX, "the finish name leaves the screen: \(name.frame)")
        let page = element(app, "card-page")
        page.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["count-plus-\(long)"].firstMatch.isHittable },
                      "the long finish's + is not hittable")
        shot("card-03-long-finish")
        let other = app.buttons["printing-row-719835"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), "no other printing")
        scrollToEnd(app, last: other)
        XCTAssertTrue(waitUntil(timeout: 5) { other.isHittable }, "the last printing row is not on screen")
        assertAboveTheBars(app, other)
        shot("card-04-end")
    }

    /// iOS: a tap on the plot (`chartXSelection`) shows that day in the summary line.
    func testTheChartTapShowsADay() throws {
        let day = Self.wantedDay()
        let prices = (0..<30).map { Double(1000 + 10 * $0) / 100 }    // $10.00 … $12.90
        let app = launch(game: "riftbound", prepare: { root in
            try self.writePinPrices(in: root)
            try self.writeCollection([["productID": Self.dockside, "finish": "Normal", "count": 1, "condition": "",
                                       "name": "Dockside Lock-Up"]], game: "riftbound")
            try self.writeHistory(game: "riftbound", productID: Self.dockside, finish: "Normal", prices: prices,
                                  endingOn: day)
        })
        openFromCollection(app, "collection-cell-\(Self.dockside)-Normal")
        let chart = element(app, "price-history-chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 20), "no chart")
        let summary = app.staticTexts["price-history-summary"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(summary) == "$12.90  +$2.90 in 30 days" }, text(summary))
        let page = element(app, "card-page")
        for _ in 0..<4 where !(chart.isHittable && chart.frame.maxY < app.tabBars.firstMatch.frame.minY) {
            page.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(chart.isHittable, "the chart is not on screen")
        XCTAssertEqual(chart.frame.height, 180, accuracy: 1, "the plot is not 180 pt tall: \(chart.frame)")
        // The plot's right part: the last ten days.
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(summary).contains(" · ") }, text(summary))
        let shown = text(summary)
        let labels = (0..<30).map { Self.dayLabel(Self.day(day, movedBy: -$0)) }
        XCTAssertTrue(labels.contains { shown.hasSuffix("· \($0)") }, "no day of the history in the summary: \(shown)")
        shot("card-05-chart-tap")
    }
}
