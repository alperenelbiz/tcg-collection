import XCTest

/// The price chart on the card page (phase 5A task 6: A38–A41, H3, H16). The history file is written into the fresh root
/// before the launch (`writeHistory`), its days counted back from the day the app's window ends on (`wantedDay()`, taken
/// once per test and passed to the writer and the assertions).
/// Tests that must not depend on the fixture archive write their own price files (`writePinPrices`, a price day far ahead:
/// no archive is downloaded, so no day file is written: their chart is the history file's alone). Without them the price
/// step's fixture archive becomes the wanted day's day file (phase 5B), and every printing's block reads it. Yu-Gi-Oh!'s 719834 (Swiftwind Panther Warrior,
/// Super Rare) has two finish lines there, 1st Edition and Unlimited; 719835 (Starlight Rare) has one.
final class PriceHistoryFlowTests: UITestCase {
    private static let panther = 719834, starlight = 719835, dockside = 721334
    private static let noPrice = "No price in the last 90 days."

    func testTheChartOfAnOwnedPrinting() throws {
        let prices = (0..<30).map { Double(1000 + 10 * $0) / 100 }    // $10.00 … $12.90
        let day = Self.wantedDay()
        let app = try launch(game: "yu-gi-oh") { root in
            try self.writePinPrices(in: root)
            try self.writeCollection([StoredRow(productID: Self.panther, finish: "1st Edition", count: 1,
                                                name: "Swiftwind Panther Warrior")], game: "yu-gi-oh", in: root)
            try self.writeHistory(game: "yu-gi-oh", productID: Self.panther, finish: "1st Edition", prices: prices,
                                  endingOn: day)
        }
        openCard(app, "swiftwind panther warrior", product: Self.panther)
        let chart = element(app, "price-history-chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 20), "no chart")
        let summary = element(app, "price-history-summary")
        XCTAssertTrue(waitUntil { self.text(summary) == "$12.90  +$2.90 in 30 days" }, shown(summary))
        XCTAssertFalse(element(app, "price-history-note").exists, "a note beside the chart")
        // The finish control: two finish lines, the owned one chosen.
        XCTAssertTrue(element(app, "price-history-finish").exists)
        XCTAssertEqual(app.radioButtons["1st Edition"].value as? Int, 1)

        // A39: under the Wanted line and the Decks block, above the rules text.
        let block = element(app, "price-history")
        XCTAssertGreaterThanOrEqual(block.frame.minY, element(app, "wanted-plus").frame.maxY)
        XCTAssertGreaterThanOrEqual(block.frame.minY, element(app, "card-add-to-deck").frame.maxY)
        let rules = element(app, "card-rules-text")
        XCTAssertTrue(rules.exists, "the fixture card has no rules text")
        XCTAssertLessThanOrEqual(block.frame.maxY, rules.frame.minY)
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, "the window grew")

        let page = element(app, "card-page")
        page.scroll(byDeltaX: 0, deltaY: -260)
        XCTAssertTrue(waitUntil { chart.isHittable }, "the chart is not on screen")
        shot("history-01-chart")

        // Hover: the summary line shows the day under the pointer.
        chart.hover()
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(summary).contains(" · ") }, shown(summary))
        shot("history-02-hover")
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, "the window grew")
    }

    func testTheFinishControlSwitchesTheSeries() throws {
        let day = Self.wantedDay()
        let app = try launch(game: "yu-gi-oh") { root in
            try self.writePinPrices(in: root)
            try self.writeCollection([StoredRow(productID: Self.panther, finish: "Unlimited", count: 1,
                                                name: "Swiftwind Panther Warrior")], game: "yu-gi-oh", in: root)
            try self.writeHistory(game: "yu-gi-oh", productID: Self.panther,
                                  finishes: ["1st Edition": [14, 14.5], "Unlimited": [8, 9, 9.5, 9]],
                                  low: ["Unlimited": [2]], endingOn: day) // one low day: two dashed segments
        }
        openCard(app, "swiftwind panther warrior", product: Self.panther)
        let summary = element(app, "price-history-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "no summary")
        // A38: the owned finish first.
        XCTAssertTrue(waitUntil { app.radioButtons["Unlimited"].value as? Int == 1 })
        XCTAssertTrue(waitUntil { self.text(summary) == "$9.00  +$1.00 in 4 days" }, shown(summary))
        let page = element(app, "card-page")
        page.scroll(byDeltaX: 0, deltaY: -260)
        let first = app.radioButtons["1st Edition"]
        XCTAssertTrue(waitUntil { first.isHittable }, "the control is not on screen")
        shot("history-03-unlimited")
        settled(first).click()
        XCTAssertTrue(waitUntil { self.text(summary) == "$14.50  +$0.50 in 2 days" }, shown(summary))
        shot("history-04-first-edition")

        // A printing with one finish line has no control; no day file and nothing in the history file: its sentence.
        let row = element(app, "printing-row-\(Self.starlight)")
        page.scroll(byDeltaX: 0, deltaY: -2000)
        XCTAssertTrue(waitUntil { row.isHittable }, "the printing row is not on screen")
        settled(row).coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "card-facts-line")).contains("Starlight Rare") })
        let note = element(app, "price-history-note")
        XCTAssertTrue(waitUntil { note.exists && self.text(note) == Self.noPrice }, shown(note))
        XCTAssertFalse(element(app, "price-history-finish").exists, "a control for one finish")
        XCTAssertFalse(summary.exists)
    }

    /// Phase 5B (A45, K6): a card in no list has its block from the day file the price step wrote (the fixture archive
    /// under the wanted day's name: one day, Normal $5.12, Foil low $9.50), with no history file.
    func testACardNotInTheCollectionHasItsChart() throws {
        let day = Self.wantedDay()
        let app = launch(game: "riftbound")
        let note = element(app, "price-history-note")
        openCard(app, "dockside lock up")
        let starts = "Price history starts on \(Self.dayLabel(day))."
        XCTAssertTrue(waitUntil(timeout: 20) { note.exists && self.text(note) == starts }, shown(note))
        XCTAssertFalse(element(app, "price-history-chart").exists)
        XCTAssertEqual(text(element(app, "card-owned")), "In your collection: 0")
        // The sentence is the shown finish's: two finish lines, so the control is there.
        XCTAssertTrue(element(app, "price-history-finish").exists, "no control above a per-finish sentence")
        let page = element(app, "card-page")
        page.scroll(byDeltaX: 0, deltaY: -260)
        XCTAssertTrue(waitUntil { note.isHittable }, "the note is not on screen")
        shot("history-05-not-owned-one-day")
    }

    func testANewerHistoryFileSaysSo() throws {
        let newer = Data(#"{"days": [], "products": {}, "version": 2}"#.utf8)
        var file: URL?
        let app = try launch(game: "riftbound") { root in
            // No archive is downloaded, so no day file gives the printing a price: the history file's state shows (K6).
            try self.writePinPrices(in: root)
            try self.writeCollection([StoredRow(productID: Self.dockside, finish: "Normal", count: 1, name: "Dockside Lock-Up")],
                                     game: "riftbound", in: root)
            try self.writeHistoryFile(game: "riftbound", data: newer)
            file = root.appending(path: "user").appending(path: "riftbound.prices.json")
        }
        openCard(app, "dockside lock up")
        let note = element(app, "price-history-note")
        XCTAssertTrue(waitUntil(timeout: 20) {
            note.exists && self.text(note) == "The price history was written by a newer version of the app." }, shown(note))
        element(app, "card-page").scroll(byDeltaX: 0, deltaY: -260)
        XCTAssertTrue(waitUntil { note.isHittable })
        shot("history-07-newer")
        quit(app)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(file)), newer, "the newer file was rewritten")
    }

    func testTheFirstLaunchWritesOnlyTheHistoryFile() throws {
        let day = Self.wantedDay()
        var folder: URL?
        var before: [String: Data] = [:]
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { root in
            try self.writeCollection([StoredRow(productID: Self.dockside, finish: "Normal", count: 1, name: "Dockside Lock-Up")],
                                     game: "riftbound", in: root)
            let user = root.appending(path: "user", directoryHint: .isDirectory)
            try Data(#"{"version": 1}"#.utf8).write(to: user.appending(path: "settings.json"))
            folder = user
            before = try Self.files(in: user)
        }
        let user = try XCTUnwrap(folder)
        let history = user.appending(path: "riftbound.prices.json")
        XCTAssertTrue(waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: history.path) }, "no history file")
        quit(app)
        var after = try Self.files(in: user)
        let written = try XCTUnwrap(after.removeValue(forKey: "riftbound.prices.json"))
        XCTAssertEqual(after, before, "a file of the folder changed, or another one appeared")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(object["days"] as? [String], [day])
        XCTAssertNotNil((object["products"] as? [String: Any])?[String(Self.dockside)])
    }

    /// Review 1, finding 1: three finish lines, one of them long ("1st Edition Holofoil", 113 pt): the control takes a form
    /// that fits the 306 pt column, so the window stays 900 pt; it is on screen and a pick changes the summary.
    func testThreeFinishesKeepTheWindowWidth() throws {
        let day = Self.wantedDay()
        let app = try launch(game: "yu-gi-oh") { root in
            try self.writePinPrices(in: root, longFinish: true)
            try self.writeCollection([StoredRow(productID: Self.panther, finish: "Unlimited", count: 1,
                                                name: "Swiftwind Panther Warrior")], game: "yu-gi-oh", in: root)
            try self.writeHistory(game: "yu-gi-oh", productID: Self.panther,
                                  finishes: ["1st Edition": [14, 14.5], "Unlimited": [8, 9]], endingOn: day)
        }
        openCard(app, "swiftwind panther warrior", product: Self.panther)
        let summary = element(app, "price-history-summary")
        XCTAssertTrue(waitUntil(timeout: 20) { summary.exists && self.text(summary) == "$9.00  +$1.00 in 2 days" },
                      shown(summary))
        let control = element(app, "price-history-finish")
        XCTAssertTrue(control.exists, "no finish control")
        let page = element(app, "card-page")
        page.scroll(byDeltaX: 0, deltaY: -260)
        XCTAssertTrue(waitUntil { control.isHittable }, "the control is not on screen")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.width, 900, accuracy: 1, "the control widened the window")
        XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX, "the control leaves the window: \(control.frame)")
        shot("history-08-three-finishes")
        // Whatever form fits: segments are radio buttons; the menu is a pop-up button with menu items.
        let segment = app.radioButtons["1st Edition"]
        if segment.exists {
            settled(segment).click()
        } else {
            settled(control).click()
            let item = app.menuItems["1st Edition"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "no menu item")
            shot("history-09-finish-menu")
            item.click()
        }
        XCTAssertTrue(waitUntil { self.text(summary) == "$14.50  +$0.50 in 2 days" }, shown(summary))
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, accuracy: 1, "the window grew")
    }

    /// Waits until `element` stops moving (a scroll's deceleration), so a click lands on it: once its frame was the same
    /// on two reads 0.3 s apart (the helper of DecksFlowTests). Returns the element.
    @discardableResult
    private func settled(_ element: XCUIElement) -> XCUIElement {
        var last = element.frame
        _ = waitUntil(timeout: 3) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            defer { last = element.frame }
            return element.frame == last
        }
        return element
    }

    /// Waits for the fixture sync, opens the card's page from All cards and, with `product`, shows that printing (its row
    /// is below the 450 pt window's edge), then scrolls back to the top.
    private func openCard(_ app: XCUIApplication, _ cardKey: String, product: Int? = nil,
                          file: StaticString = #filePath, line: UInt = #line) {
        let cell = element(app, "card-cell-\(cardKey)")
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "no cell \(cardKey)", file: file, line: line)
        XCTAssertTrue(waitUntilSynced(app), "the sync did not end", file: file, line: line)
        cell.click()
        XCTAssertTrue(element(app, "card-page").waitForExistence(timeout: 10), "no card page", file: file, line: line)
        guard let product else { return }
        let page = element(app, "card-page")
        let row = element(app, "printing-row-\(product)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        page.scroll(byDeltaX: 0, deltaY: -2000)
        XCTAssertTrue(waitUntil { row.isHittable }, "the printing row is not on screen", file: file, line: line)
        settled(row).coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "card-facts-line")).contains("Super Rare") }, file: file, line: line)
        page.scroll(byDeltaX: 0, deltaY: 2000)
    }

    /// What a static text shows, or a word for one that is not there (a failure message must not fail on its own).
    private func shown(_ element: XCUIElement) -> String {
        element.exists ? text(element) : "(not there)"
    }

    /// Every file of `folder` by name with its bytes.
    private static func files(in folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appending(path: name))
        }
        return result
    }
}
