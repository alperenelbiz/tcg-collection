import XCTest

/// The CSV import of two real collection exports against a copy of a real catalog (phase 2B task 9). Skipped unless the
/// environment has `TCG_REAL_STORE` (a store root that holds `support/catalog.store`, as for `RealCatalogTests`) and
/// `TCG_REAL_CSV_DIR` (a folder with `riftbound.csv` and `yu-gi-oh.csv`). `TCG_REAL_STORE=<root>
/// TCG_REAL_CSV_DIR=<dir> scripts/ui-test.sh <out>` forwards both to the test runner. Give it copies: the app writes
/// `<root>/user/<game>.json`, and the root stays after the test.
/// - The app runs offline on the root (`launch(storeRoot:)`): its catalog counts as settled, so the import is offered, and
///   no set is fetched again (the copy keeps the rules version its sets were stored with).
/// - `<root>/user` must hold no collection file of the two games, so that every printing is New. The test removes
///   nothing: it fails and says so.
/// - Each file has a launch of its own (`-importCSV` opens one sheet at launch); the second runs on the same root, so the
///   first game's file is there already, and it must not change.
/// - The numbers come from the sheet and from the file the app wrote, never from the owner's collection; the comparison
///   with the old app's numbers is a step outside the test.
final class RealCollectionTests: UITestCase {
    func testTheTwoFilesImportOnTheRealCatalog() throws {
        let root = try realStoreRoot()
        let files = try realCSVDirectory()
        for game in Self.games {
            let file = root.appending(path: "user").appending(path: "\(game).json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "\(file.path) exists: remove <root>/user of this copy before the run (a first import is all New)")
        }

        let (first, riftbound) = try importFile(game: "riftbound", from: files, root: root)
        quit(first)
        let (app, yugioh) = try importFile(game: "yu-gi-oh", from: files, root: root)
        XCTAssertEqual(try storedCollection(game: "riftbound"), riftbound, "the Yu-Gi-Oh! import changed the Riftbound file")

        // Both games in one run: each game switch on the Collection joins that game's rows with the catalog again.
        let toRiftbound = switchGame(app, to: "Riftbound", totals: totals(riftbound))
        shot("real-collection-4-riftbound-after-switch")
        let toYugioh = switchGame(app, to: "Yu-Gi-Oh!", totals: totals(yugioh))
        let attachment = XCTAttachment(string: "game switch -> Collection totals: Riftbound \(toRiftbound), Yu-Gi-Oh! \(toYugioh)")
        attachment.name = "real-collection-game-switch-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests game switch -> Collection totals: Riftbound \(toRiftbound), Yu-Gi-Oh! \(toYugioh)")
        quit(app)
        XCTAssertEqual(try storedCollection(game: "riftbound"), riftbound)
        XCTAssertEqual(try storedCollection(game: "yu-gi-oh"), yugioh)
    }

    /// The two games, in the order they are imported.
    private static let games = ["riftbound", "yu-gi-oh"]

    /// Launches on the Collection with `-importCSV <directory>/<game>.csv`, reads the comparison, imports it, and checks
    /// the Collection's totals against the sheet and the written file. Returns the running app and the rows it wrote.
    /// Keeps pictures of the sheet's top, of its end and of the gallery, and one text attachment with what the sheet said
    /// and how long each step took (each time includes XCUITest's own waits and polling: an upper bound).
    private func importFile(game: String, from directory: URL, root: URL) throws -> (XCUIApplication, [StoredRow]) {
        let csv = directory.appending(path: "\(game).csv")
        let launched = Date()
        let app = launch(storeRoot: root, game: game, extra: ["-screen", "collection", "-importCSV", csv.path])
        // `waitUntil` polls every 0.2 s; `waitForExistence` checks first after about 1 s, too coarse for these times.
        let sheet = element(app, "import-sheet")
        XCTAssertTrue(waitUntil(timeout: 60) { sheet.exists }, "no import sheet for \(game)")
        let sheetShown = Date()
        let newGroup = element(app, "import-new-\(game)")
        XCTAssertTrue(waitUntil(timeout: 120) { newGroup.exists }, "no New group for \(game): \(sheet.debugDescription)")
        let apply = element(app, "import-apply")
        XCTAssertTrue(waitUntil(timeout: 60) { apply.exists && apply.isEnabled }, "Import is not on for \(game)")
        let ready = Date()

        // A first import: every printing is New; no count changes and no row offered for removal.
        let printings = try number(in: text(newGroup), after: "New · ")
        XCTAssertGreaterThan(printings, 0)
        XCTAssertFalse(element(app, "import-blocked-\(game)").exists, "\(game) is blocked: \(text(element(app, "import-blocked-\(game)")))")
        XCTAssertFalse(element(app, "import-changed-\(game)").exists, "a count change on a first import")
        XCTAssertFalse(element(app, "import-missing-\(game)").exists, "a row offered for removal on a first import")
        let summary = text(element(app, "import-summary"))
        XCTAssertEqual(summary, "\(printings) new")
        shot("real-collection-\(game)-1-sheet", of: sheet)

        // The end of the table, and "Not imported · N" opened when the file has such lines. The rows are in a lazy stack:
        // the button exists only once it is scrolled near.
        let scrollView = sheet.scrollViews.firstMatch
        let skipped = element(app, "import-skipped")
        for _ in 0..<(printings * 30 / 2000 + 3) where !(skipped.exists && skipped.isHittable) {
            scrollView.scroll(byDeltaX: 0, deltaY: -2000)
        }
        var notImported: (count: Int, lines: [String]) = (0, [])
        if skipped.exists {
            notImported.count = try number(in: skipped.label, after: "Not imported · ")
            skipped.click()
            let lines = sheet.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'import-skipped-line-'"))
            XCTAssertTrue(waitUntil { lines.count > 0 }, "no line under \(skipped.label)")
            scrollView.scroll(byDeltaX: 0, deltaY: -2000)
            notImported.lines = lines.allElementsBoundByIndex.map { text($0) }
            for line in notImported.lines {
                XCTAssertTrue(line.hasSuffix("basic rune") || line.hasSuffix("not in the catalog"), "unexpected reason: \(line)")
            }
        }
        shot("real-collection-\(game)-2-sheet-end", of: sheet)

        let clicked = Date()
        apply.click()
        XCTAssertTrue(waitUntil(timeout: 30) { !sheet.exists }, "the sheet stayed open")
        let window = app.windows.firstMatch
        let printingsText = "\(printings) \(printings == 1 ? "printing" : "printings")"
        XCTAssertTrue(waitUntil(timeout: 60) { window.title.hasSuffix(" · " + printingsText) }, window.title)
        let totalsShown = Date()
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.storedCollection(game: game).count) == printings },
                      "the file does not hold \(printings) rows")
        let rows = try storedCollection(game: game)
        XCTAssertTrue(window.title.hasSuffix(" " + totals(rows)), "\(window.title) does not match the file: \(totals(rows))")
        XCTAssertEqual(Set(rows.map { "\($0.productID)-\($0.finish)" }).count, rows.count, "two rows of one printing")
        // Said once the write has run (final fix A2).
        let status = app.staticTexts["status-line"]
        XCTAssertTrue(waitUntil { self.text(status) == "Imported: \(summary)" }, text(status))
        XCTAssertTrue(collectionCells(app).firstMatch.waitForExistence(timeout: 10), "no cell in the gallery")
        shot("real-collection-\(game)-3-gallery")

        let seconds = { (from: Date, to: Date) in String(format: "%.1f s", to.timeIntervalSince(from)) }
        let report = """
            \(game): \(window.title); file: \(totals(rows))
            summary: \(summary); not imported: \(notImported.count)\(notImported.lines.map { "\n  \($0)" }.joined())
            launch -> sheet shown: \(seconds(launched, sheetShown))
            launch -> comparison ready, Import on: \(seconds(launched, ready)) (sheet shown -> ready: \(seconds(sheetShown, ready)))
            Import -> Collection totals: \(seconds(clicked, totalsShown))
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-collection-\(game)-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests \(report)")
        return (app, rows)
    }

    /// Picks `game` in the game picker while the Collection shows, and waits for the window's subtitle to say `totals`.
    /// Returns how long that took (an upper bound of the join, as the times of `importFile`).
    private func switchGame(_ app: XCUIApplication, to game: String, totals: String) -> String {
        element(app, "game-picker").click()
        let item = app.menuItems[game].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(game) in the game picker")
        let clicked = Date()
        item.click()
        let window = app.windows.firstMatch
        XCTAssertTrue(waitUntil(timeout: 60) { window.title.hasSuffix(" " + totals) }, "\(window.title), not \(totals)")
        return String(format: "%.1f s", Date().timeIntervalSince(clicked))
    }

    /// The Collection's subtitle for these rows: `120 copies · 74 printings` (as `CollectionList.totals`).
    private func totals(_ rows: [StoredRow]) -> String {
        let copies = rows.reduce(0) { $0 + $1.count }
        return "\(copies) \(copies == 1 ? "copy" : "copies") · \(rows.count) \(rows.count == 1 ? "printing" : "printings")"
    }

    /// The whole number after `prefix` in `text` ("New · 12" → 12). The prefix may stand after other words (a button's
    /// label can start with its icon's name).
    private func number(in text: String, after prefix: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: prefix), "\"\(text)\" has no \"\(prefix)\"")
        return try XCTUnwrap(Int(text[range.upperBound...]), "no number after \"\(prefix)\" in \"\(text)\"")
    }

    /// `TCG_REAL_CSV_DIR`, or a skip when it is not set. A folder without both files fails before the app starts.
    private func realCSVDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TCG_REAL_CSV_DIR"], !path.isEmpty else {
            throw XCTSkip("TCG_REAL_CSV_DIR is not set: this test runs only on copies of real collection exports")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        for game in Self.games where !FileManager.default.fileExists(atPath: directory.appending(path: "\(game).csv").path) {
            return try XCTUnwrap(nil, "TCG_REAL_CSV_DIR has no \(game).csv: \(directory.path)")
        }
        return directory
    }
}
