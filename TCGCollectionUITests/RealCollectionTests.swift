import AppKit
import PDFKit
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
/// The lists of phase 2C on the same kind of root: `testWantedForSaleSoldAndPDFsOnTheRealCollection`, which needs only
/// `TCG_REAL_STORE` and an imported Riftbound file. XCTest runs a class's tests in name order, so with both variables
/// it runs after the import, on the files the import wrote.
final class RealCollectionTests: UITestCase {
    /// The decks `testSharedCopiesOnTheRealCollection` made and set active: its teardown block sets them not active again,
    /// also after a failure (final fix A7).
    private var sharingDecks: [String] = []

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
                XCTAssertTrue(line.hasSuffix("not in the catalog"), "unexpected reason: \(line)")
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

    // MARK: The lists (phase 2C task 6)

    /// Wanted, For Sale, Sold and the two PDFs on a real Riftbound collection, offline. Skipped unless `TCG_REAL_STORE` is
    /// set and its root has `user/riftbound.json` (a collection the import wrote; `TCG_REAL_CSV_DIR` is not needed). The
    /// file's `wanted`, `forSale` and `sold` must be empty and the root must hold no PDF of an earlier run: the test fails
    /// and says so (give it a fresh copy each run). Three launches:
    /// 1. The Collection: its first printings in reading order (at most 12), each opened on its card page. Three get one
    ///    copy "For sale": the first one owned more than once, when there is one, and the first others; the first two
    ///    distinct cards get one "Wanted". For Sale and Wanted list them, and their subtitles and the Collection's agree
    ///    with the file.
    /// 2. `-exportPDF` on For Sale (three printings): the PDF's page count, title, total, names and page number. Then
    ///    "Sold 1" on the printing owned more than once (else the first marked): the collection loses exactly that copy
    ///    (the row stays, one copy fewer, when it had more), every other row stays as it was, the record is appended, and
    ///    the subtitles agree with the file again.
    /// 3. `-exportPDF` on Wanted (two cards), checked as the first.
    /// Every number and name comes from the screen and the file, never from the owner's collection. The PDFs stay in the
    /// root (`lists-check-for-sale.pdf`, `lists-check-wanted.pdf`) for the checks outside the test; one text attachment
    /// keeps the times and sizes (`real-lists-timings`; each time is measured from outside, an upper bound).
    func testWantedForSaleSoldAndPDFsOnTheRealCollection() throws {
        let root = try realStoreRoot()
        let file = root.appending(path: "user").appending(path: "riftbound.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("\(file.path) is not there: this test runs on a root whose Riftbound collection is imported")
        }
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], file.path)
        for list in ["wanted", "forSale", "sold"] {
            XCTAssertTrue((initial[list] as? [Any])?.isEmpty ?? true, "\(file.path) has a \(list) list: give the test a fresh copy")
        }
        // In the root itself: the sandboxed test runner can read the root but not make a folder in it; the app writes.
        let salePDF = root.appending(path: "lists-check-for-sale.pdf"), wantedPDF = root.appending(path: "lists-check-wanted.pdf")
        for pdf in [salePDF, wantedPDF] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path), "\(pdf.path) is there: give the test a fresh copy")
        }
        // Without a price file of the game every item is without a price, and the subtitles and totals are known in full.
        let unpriced = !FileManager.default.fileExists(atPath: root.appending(path: "support/prices-riftbound.json").path)
        let bytesBefore = try Data(contentsOf: file).count
        var times: [String] = []
        let seconds = { (from: Date) in String(format: "%.1f s", Date().timeIntervalSince(from)) }

        // 1. Mark and want on the card pages of the Collection's first printings.
        var launched = Date()
        var app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        let before = try storedCollection(game: "riftbound")
        XCTAssertTrue(waitUntil(timeout: 60) { app.windows.firstMatch.title.hasSuffix(" " + self.totals(before)) },
                      app.windows.firstMatch.title)
        times.append("launch -> Collection totals: \(seconds(launched))")
        let cells = collectionCells(app)
        XCTAssertTrue(waitUntil(timeout: 30) { cells.count >= 3 }, "\(identifiers(cells))")
        // `<productID>-<finish>`, as in the cells' identifiers.
        let candidates = identifiersInOrder(cells).prefix(12).map { String($0.dropFirst("collection-cell-".count)) }
        let owned = Dictionary(before.map { ("\($0.productID)-\($0.finish)", $0.count) }, uniquingKeysWith: +)
        // Its sale leaves its row in the collection with one copy fewer.
        let several = candidates.first { (owned[$0] ?? 0) >= 2 }
        let toMark = Set(([several].compactMap { $0 } + candidates.filter { $0 != several }).prefix(3))
        var marked: [String] = []                                // the printings marked for sale, in the order of marking
        var wantedNames: [String] = []                           // the card pages' titles
        for key in candidates where marked.count < toMark.count || wantedNames.count < 2 {
            if !toMark.contains(key) && wantedNames.count >= 2 { continue }
            let finish = try printing(key).finish
            let cell = app.buttons["collection-cell-\(key)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "\(key) is not a link")
            // A cell of a lower row can be under the window's edge.
            for _ in 0..<10 where !cell.isHittable {
                element(app, "collection-gallery").scroll(byDeltaX: 0, deltaY: -150)
            }
            XCTAssertTrue(cell.isHittable, "\(key) is not on screen")
            cell.click()
            let salePlus = element(app, "sale-plus-\(finish)")
            XCTAssertTrue(salePlus.waitForExistence(timeout: 10), "no For sale control of \(finish) on the page of \(key)")
            let title = text(app.staticTexts["card-title"])
            if toMark.contains(key) {
                XCTAssertEqual(text(element(app, "sale-value-\(finish)")), "0")
                XCTAssertTrue(waitUntil { salePlus.isHittable }, "the For sale control of \(finish) is not on screen")
                salePlus.click()
                XCTAssertTrue(waitUntil { self.text(self.element(app, "sale-value-\(finish)")) == "1" },
                              text(element(app, "sale-value-\(finish)")))
                marked.append(key)
            }
            if wantedNames.count < 2 && !wantedNames.contains(title) {
                let plus = element(app, "wanted-plus")
                XCTAssertTrue(waitUntil { plus.isHittable }, "the Wanted line is not on screen")
                XCTAssertEqual(text(element(app, "wanted-value")), "0")
                plus.click()
                XCTAssertTrue(waitUntil { self.text(self.element(app, "wanted-value")) == "1" }, text(element(app, "wanted-value")))
                wantedNames.append(title)
                if wantedNames.count == 1 { shot("real-lists-1-card-page") }
            }
            let back = app.toolbars.buttons["Back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button")
            back.click()
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "Back did not show the Collection")
        }
        XCTAssertEqual(marked.count, 3, "three printings were not marked for sale: \(candidates)")
        XCTAssertEqual(wantedNames.count, 2, "two distinct cards were not found in the first 12 printings")

        // The file: one copy of each for sale, under the collection row's name; two cards wanted by their names, no pin.
        XCTAssertTrue(waitUntil { (try? self.storedList("forSale").count) == 3 && (try? self.storedList("wanted").count) == 2 },
                      "\(String(describing: try? storedList("forSale"))) \(String(describing: try? storedList("wanted")))")
        let forSale = try storedList("forSale")
        XCTAssertEqual(try forSale.map(entryKey), marked)
        let namesOf = Dictionary(before.map { ("\($0.productID)-\($0.finish)", $0.name) }, uniquingKeysWith: { first, _ in first })
        for entry in forSale {
            XCTAssertEqual(entry["count"] as? Int, 1)
            XCTAssertEqual(entry["name"] as? String, namesOf[try entryKey(entry)], "\(entry)")
        }
        let wanted = try storedList("wanted")
        XCTAssertEqual(wanted.map { $0["name"] as? String ?? "" }, wantedNames)
        for entry in wanted {
            XCTAssertEqual(entry["count"] as? Int, 1)
            XCTAssertEqual(Set(entry.keys), ["cardKey", "name", "count"], "a pin or an unknown key: \(entry)")
        }
        XCTAssertEqual(try storedCollection(game: "riftbound"), before, "marking and wanting changed the collection")

        element(app, "sidebar-for-sale").click()
        var saleCells = forSaleCells(app)
        XCTAssertTrue(waitUntil { Set(self.identifiers(saleCells)) == Set(marked.map { "for-sale-cell-\($0)" }) },
                      "\(identifiers(saleCells))")
        assertListSubtitle(app, copies: 3, items: 3, item: "printing", unpriced: unpriced)
        shot("real-lists-2-for-sale")
        element(app, "sidebar-wanted").click()
        let wantedIDs = Set(wanted.map { "wanted-cell-\($0["cardKey"] as? String ?? "")" })
        XCTAssertTrue(waitUntil { Set(self.identifiers(self.wantedCells(app))) == wantedIDs },
                      "\(identifiers(wantedCells(app))), not \(wantedIDs)")
        assertListSubtitle(app, copies: 2, items: 2, item: "card", unpriced: unpriced)
        shot("real-lists-3-wanted")
        quit(app)

        // 2. For Sale's PDF, then one copy sold in the same run.
        launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "for-sale", "-exportPDF", salePDF.path])
        XCTAssertTrue(waitUntil(timeout: 120) { FileManager.default.fileExists(atPath: salePDF.path) }, "no PDF at \(salePDF.path)")
        let saleWritten = seconds(launched)
        let saleNames = try forSale.map { entry in
            let finish = try printing(entryKey(entry)).finish
            let name = entry["name"] as? String ?? ""
            return finish.caseInsensitiveCompare("Normal") == .orderedSame ? name : "\(name) · \(finish)"
        }
        let saleMade = try checkPDF(salePDF, list: "For Sale", names: saleNames, copies: 3, unpriced: unpriced, picture: "real-lists-pdf-for-sale")
        times.append("launch -> For Sale PDF written (3 printings, 3 copies): \(saleWritten), \(saleMade.bytes) bytes, \(saleMade.pages) page(s)")

        saleCells = forSaleCells(app)                            // a query of the running app, not of the one that quit
        XCTAssertTrue(waitUntil(timeout: 30) { saleCells.count == 3 }, "\(identifiers(saleCells))")
        let sold = several ?? marked[0]
        let soldName = try XCTUnwrap(forSale.first { (try? entryKey($0)) == sold }?["name"] as? String)
        let soldButton = element(app, "for-sale-sold-\(sold)")
        XCTAssertTrue(waitUntil { soldButton.isEnabled }, "Sold is off")
        soldButton.click()
        let one = app.sheets.buttons["Sold 1"].firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        XCTAssertEqual(app.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sold all'")).count, 0,
                       "Sold all is offered for one copy")
        let question = "Sold 1 of \(soldName)?"
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", question, question))
            .firstMatch.exists, app.sheets.firstMatch.debugDescription)
        shot("real-lists-4-sold-dialog")
        let clicked = Date()
        one.click()
        XCTAssertTrue(waitUntil { saleCells.count == 2 }, "\(identifiers(saleCells))")
        assertListSubtitle(app, copies: 2, items: 2, item: "printing", unpriced: unpriced)
        times.append("Sold 1 click -> For Sale subtitle: \(seconds(clicked))")
        shot("real-lists-5-for-sale-after-sold")

        // The file: exactly one copy fewer of the sold printing (its row goes at 0), every other row as before, one record.
        times.append("sold: one copy of a printing owned \((owned[sold] ?? 0) > 1 ? "more than once" : "once")")
        XCTAssertTrue(waitUntil { (try? self.storedList("sold").count) == 1 }, "\(String(describing: try? storedList("sold")))")
        let expected = before.compactMap { row -> StoredRow? in
            guard "\(row.productID)-\(row.finish)" == sold else { return row }
            var row = row
            row.count -= 1
            return row.count > 0 ? row : nil
        }
        XCTAssertEqual(try storedCollection(game: "riftbound"), expected)
        XCTAssertEqual(try storedList("forSale").map(entryKey), marked.filter { $0 != sold })
        let record = try XCTUnwrap(storedList("sold").first)
        XCTAssertEqual(try entryKey(record), sold)
        XCTAssertEqual(record["count"] as? Int, 1)
        XCTAssertEqual(record["name"] as? String, soldName)
        XCTAssertEqual(record["day"] as? String, Self.today())
        XCTAssertEqual(record["priceIsLow"] as? Bool, false)
        if unpriced { XCTAssertNil(record["price"], "a price without a price file: \(record)") }
        element(app, "sidebar-collection").click()
        XCTAssertTrue(waitUntil(timeout: 30) { app.windows.firstMatch.title.hasSuffix(" " + self.totals(expected)) },
                      "\(app.windows.firstMatch.title), not \(totals(expected))")
        shot("real-lists-6-collection-after-sold")
        quit(app)

        // 3. Wanted's PDF.
        launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "wanted", "-exportPDF", wantedPDF.path])
        XCTAssertTrue(waitUntil(timeout: 120) { FileManager.default.fileExists(atPath: wantedPDF.path) }, "no PDF at \(wantedPDF.path)")
        let wantedWritten = seconds(launched)
        let wantedMade = try checkPDF(wantedPDF, list: "Wanted", names: wantedNames, copies: 2, unpriced: unpriced, picture: "real-lists-pdf-wanted")
        times.append("launch -> Wanted PDF written (2 cards, 2 copies): \(wantedWritten), \(wantedMade.bytes) bytes, \(wantedMade.pages) page(s)")
        XCTAssertTrue(waitUntil { Set(self.identifiers(self.wantedCells(app))) == wantedIDs }, "\(identifiers(wantedCells(app)))")
        assertListSubtitle(app, copies: 2, items: 2, item: "card", unpriced: unpriced)
        quit(app)

        // After the last quit: the lists as left, and nothing else of the collection changed.
        XCTAssertEqual(try storedCollection(game: "riftbound"), expected)
        XCTAssertEqual(try storedList("wanted").map { $0["name"] as? String ?? "" }, wantedNames)
        XCTAssertEqual(try storedList("sold").count, 1)
        times.append("riftbound.json: \(bytesBefore) bytes before, \(try Data(contentsOf: file).count) bytes after")
        let report = times.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-lists-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests lists\n\(report)")
    }

    /// Fails unless the window's subtitle is a list's totals for `copies` and `items` (`printing` or `card`), as
    /// `SaleList.totals` and `WantedList.totals` make them: on a root without a price file every item is "without a
    /// price"; with one, only the counts are checked.
    private func assertListSubtitle(_ app: XCUIApplication, copies: Int, items: Int, item: String, unpriced: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let counts = "\(copies) \(copies == 1 ? "copy" : "copies") · \(items) \(items == 1 ? item : item + "s")"
        let window = app.windows.firstMatch
        let matches: () -> Bool = unpriced
            ? { window.title.hasSuffix(" \(counts) · \(items) without a price") }
            : { window.title.contains(" \(counts)") }
        XCTAssertTrue(waitUntil(timeout: 30, matches), "\(window.title), not \(counts)", file: file, line: line)
    }

    /// Checks a PDF the app wrote for a list of `names` with `copies` in all, and returns its size in bytes and its pages:
    /// 12 cells a page (`ListPDF.itemsPerPage`, every page), the title "Riftbound — <list> — <day>" and the total on page 1
    /// (on a root without a price file "<copies> copies · <n> without a price"), "1 / <pages>" at the foot, and the start
    /// of every name (whitespace aside: a name may take two lines). Keeps a picture of page 1 as `picture`.
    private func checkPDF(_ url: URL, list: String, names: [String], copies: Int, unpriced: Bool,
                          picture: String) throws -> (bytes: Int, pages: Int) {
        let data = try Data(contentsOf: url)
        let pdf = try XCTUnwrap(PDFDocument(data: data), "not a PDF: \(url.path)")
        XCTAssertEqual(pdf.pageCount, max(1, (names.count + 11) / 12), "pages of \(names.count) items")
        let first = try XCTUnwrap(pdf.page(at: 0))
        let text = first.string ?? ""
        XCTAssertTrue(text.contains("Riftbound — \(list) — "), text)
        XCTAssertTrue(text.contains(unpriced ? "\(copies) copies · \(names.count) without a price" : "\(copies) copies"), text)
        XCTAssertTrue(text.contains("1 / \(pdf.pageCount)"), text)
        let all = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined().filter { !$0.isWhitespace }
        for name in names {
            let start = String(name.filter { !$0.isWhitespace }.prefix(12))
            XCTAssertTrue(all.contains(start), "\(name) is not in the PDF")
        }
        let image = XCTAttachment(image: first.thumbnail(of: NSSize(width: 1190, height: 1684), for: .mediaBox))
        image.name = "\(picture)-page-1"
        image.lifetime = .keepAlways
        add(image)
        return (data.count, pdf.pageCount)
    }

    /// The list `key` (`wanted`, `forSale`, `sold`) of the running root's Riftbound file as the app wrote it; [] without.
    private func storedList(_ key: String) throws -> [[String: Any]] {
        try storedUserFile(game: "riftbound")?[key] as? [[String: Any]] ?? []
    }

    /// `<productID>-<finish>` of a for-sale entry or a sold record, as in the cells' identifiers.
    private func entryKey(_ entry: [String: Any]) throws -> String {
        "\(try XCTUnwrap(entry["productID"] as? Int, "\(entry)"))-\(try XCTUnwrap(entry["finish"] as? String, "\(entry)"))"
    }

    /// The product id and the finish of `<productID>-<finish>` (a finish keeps its spaces and hyphens).
    private func printing(_ key: String) throws -> (productID: Int, finish: String) {
        let dash = try XCTUnwrap(key.firstIndex(of: "-"), key)
        return (try XCTUnwrap(Int(key[..<dash]), key), String(key[key.index(after: dash)...]))
    }

    // MARK: A deck (phase 3A task 8)

    /// The section names of Riftbound's one format (`GameDecks.riftbound`), by id: the deck page's section titles.
    private static let riftboundSections = ["legend": "Legend", "champion": "Champion", "main": "Main Deck", "runes": "Runes",
                                            "battlefields": "Battlefields", "sideboard": "Sideboard"]

    /// The paste's counts: five card lines and one misspelt line, 55 copies, so the deck holds 60 with the five cards added
    /// from the search (rule checks warn and never block: the copy limit's warning is expected).
    private static let pastedCounts = [9, 9, 9, 9, 9, 10]

    /// A deck on a real Riftbound collection, offline (D7–D11, A14, A16). Skipped unless `TCG_REAL_STORE` is set and its root
    /// has `user/riftbound.json`; the file must hold no deck (else it fails at once: give it a fresh copy each run). Three launches:
    /// 1. The Collection: the names of its first 11 distinct cards, read from the cells' labels (never constants). "New
    ///    Deck…" → Create: an empty deck, not active. "Add cards": the first five names searched one after the other, `+`
    ///    once on each card's cell. The file: one deck, five cards of one copy.
    /// 2. `-pasteDeck` on that deck with a text the test writes into its own temporary folder: the next five names (9 copies each) and the
    ///    eleventh with its third letter dropped (10 copies). Read: one line not recognised; its first suggestion is picked
    ///    (whether it is the card the line came from is recorded, not asserted); "Add to Deck". The file: 60 cards; the deck
    ///    page's subtitle and section titles agree with it.
    /// 3. The deck page again: how long until its sections show (the first join, from outside), and one `+` click on a cell
    ///    until its new count shows, then `−` back.
    /// After the last quit: `collection`, `wanted`, `forSale` and `sold` as before, one deck of 60 cards. The byte comparison
    /// of those four lists before and after is a step outside the test (the report's "Decks, phase 3A check"). One text
    /// attachment keeps the times (`real-deck-timings`).
    func testADeckOnTheRealCollection() throws {
        let root = try realStoreRoot()
        let file = root.appending(path: "user").appending(path: "riftbound.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("\(file.path) is not there: this test runs on a root whose Riftbound collection is imported")
        }
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], file.path)
        XCTAssertTrue((initial["decks"] as? [Any])?.isEmpty ?? true, "\(file.path) has decks: give the test a fresh copy")
        // The sandboxed test runner cannot write into the root (macOS refuses with "You don't have permission"); the app,
        // which has no sandbox, reads the text from the runner's own temporary folder.
        let pasteFile = FileManager.default.temporaryDirectory.appending(path: "deck-check-paste-\(UUID().uuidString).txt")
        let bytesBefore = try Data(contentsOf: file).count
        var times: [String] = []
        let seconds = { (from: Date) in String(format: "%.1f s", Date().timeIntervalSince(from)) }

        // 1. Names from the Collection, a new deck, five cards from "Add cards".
        var app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        let rows = try storedCollection(game: "riftbound")
        XCTAssertTrue(waitUntil(timeout: 60) { app.windows.firstMatch.title.hasSuffix(" " + self.totals(rows)) },
                      app.windows.firstMatch.title)
        let names = try collectionNames(app, count: 11)
        let newDeck = element(app, "sidebar-new-deck")
        XCTAssertTrue(waitUntil { newDeck.exists && newDeck.isEnabled }, "New Deck… is off")
        newDeck.click()
        XCTAssertTrue(element(app, "new-deck-sheet").waitForExistence(timeout: 5), "no New Deck sheet")
        element(app, "new-deck-create").click()
        let addCards = element(app, "deck-empty-add-cards")
        XCTAssertTrue(addCards.waitForExistence(timeout: 10), "the new deck is not empty, or its page did not open")
        var decks: [[String: Any]] = []
        XCTAssertTrue(waitUntil { decks = self.storedDecks(); return decks.count == 1 }, "\(decks)")
        let deckID = try XCTUnwrap(decks.first?["id"] as? String)
        XCTAssertEqual(decks.first?["active"] as? Bool, false, "a new deck is active")
        addCards.click()
        XCTAssertTrue(element(app, "deck-add-screen").waitForExistence(timeout: 10), "no deck search")
        var searched: [String] = []                              // the card keys added from the search
        for name in names.prefix(5) {
            let key = try addFromSearch(app, name: name)
            searched.append(key)
            XCTAssertTrue(waitUntil { self.deckCount(self.storedDecks()) == searched.count },
                          "the file does not hold \(searched.count) cards: \(self.storedDecks())")
        }
        shot("real-deck-1-search")
        app.toolbars.buttons["Back"].firstMatch.click()
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10), "Back did not show the deck")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.contains(" 5 cards") }, app.windows.firstMatch.title)
        quit(app)
        XCTAssertEqual(Set(cards(of: storedDecks()).map(\.key)), Set(searched))

        // 2. A paste into the deck: five names and one misspelt.
        let misspelt = try XCTUnwrap(Self.withoutThirdLetter(names[10]), names[10])
        let pasted = Array(names[5..<10]) + [misspelt]
        let pasteText = zip(Self.pastedCounts, pasted).map { "\($0) \($1)" }.joined(separator: "\n") + "\n"
        try Data(pasteText.utf8).write(to: pasteFile)
        var launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "deck:\(deckID)", "-pasteDeck", pasteFile.path])
        let sheet = element(app, "paste-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no paste sheet")
        let read = element(app, "paste-read")
        XCTAssertTrue(waitUntil(timeout: 30) { read.isEnabled }, "Read stays off")
        let readClicked = Date()
        read.click()
        let summary = element(app, "paste-summary")
        XCTAssertTrue(waitUntil(timeout: 60) { summary.exists }, "no table")
        times.append("Read -> the table (6 lines, 1 misspelt): \(seconds(readClicked))")
        let unknown = element(app, "paste-unknown-6")
        XCTAssertTrue(unknown.waitForExistence(timeout: 5), "the misspelt line is not unknown: \(text(summary))")
        XCTAssertEqual(text(element(app, "paste-unknown-count")), "1 line not recognised: pick a name or drop the line.")
        shot("real-deck-2-paste-table", of: sheet)
        unknown.click()
        let firstSuggestion = unknown.menuItems.firstMatch
        XCTAssertTrue(firstSuggestion.waitForExistence(timeout: 5), "no menu")
        let suggested = firstSuggestion.title
        XCTAssertNotEqual(suggested, "No near names in the catalog", "no suggestion for \(misspelt)")
        XCTAssertNotEqual(suggested, "Drop this line", "no suggestion for \(misspelt)")
        shot("real-deck-3-suggestions")
        firstSuggestion.click()
        let apply = element(app, "paste-apply")
        XCTAssertTrue(waitUntil { apply.isEnabled }, "Add to Deck stays off")
        XCTAssertEqual(text(element(app, "paste-note-6")), "as written: \(misspelt)")
        XCTAssertEqual(text(summary), "55 cards on 6 lines")
        times.append("misspelt \"\(misspelt)\" for \"\(names[10])\": first suggestion \"\(suggested)\" "
                     + "(\(suggested == names[10] ? "the right card" : "another card"))")
        apply.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertTrue(waitUntil { self.deckCount(self.storedDecks()) == 60 }, "\(storedDecks())")
        try assertDeckPage(app)
        shot("real-deck-4-deck")
        quit(app)

        // 3. The deck page's first join, and one `+` click.
        launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "deck:\(deckID)"])
        let stored = cards(of: storedDecks())
        let target = try XCTUnwrap(stored.first)
        let sectionTitle = element(app, "deck-section-\(target.section)")
        XCTAssertTrue(waitUntil(timeout: 60) { sectionTitle.exists && app.windows.firstMatch.title.contains(" 60 cards") },
                      app.windows.firstMatch.title)
        times.append("launch -> the deck page's section title and subtitle (60 cards, \(stored.count) lines): \(seconds(launched))")
        let suffix = "\(target.key)-\(target.section)"
        // A group's cells are in a lazy grid: the cell exists once it is scrolled near the window.
        let cell = reveal(app, "deck-cell-\(suffix)")
        XCTAssertTrue(waitUntil(timeout: 60) { cell.isEnabled }, "\(suffix) is not a link: the join did not end")
        times.append("launch -> the cell scrolled into the window and a link (the join ended): \(seconds(launched))")
        let plus = reveal(app, "deck-cell-plus-\(suffix)")
        let value = element(app, "deck-cell-value-\(suffix)")
        XCTAssertEqual(text(value), "\(target.count)")
        let clicked = Date()
        plus.click()
        XCTAssertTrue(waitUntil { self.text(value) == "\(target.count + 1)" }, text(value))
        times.append("+ click -> the new count on a 60-card deck: \(seconds(clicked))")
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.contains(" 61 cards") }, app.windows.firstMatch.title)
        element(app, "deck-cell-minus-\(suffix)").click()
        XCTAssertTrue(waitUntil { self.text(value) == "\(target.count)" }, text(value))
        XCTAssertTrue(waitUntil { self.deckCount(self.storedDecks()) == 60 }, "\(storedDecks())")
        try assertDeckPage(app)
        quit(app)

        // After the last quit: one deck of 60 cards, the other lists as before.
        let final = try XCTUnwrap(storedUserFile(game: "riftbound"))
        for list in ["collection", "wanted", "forSale", "sold"] {
            XCTAssertEqual(final[list] as? NSArray, initial[list] as? NSArray, "\(list) changed")
        }
        XCTAssertEqual(storedDecks().count, 1)
        XCTAssertEqual(deckCount(storedDecks()), 60)
        try? FileManager.default.removeItem(at: pasteFile)
        times.append("riftbound.json: \(bytesBefore) bytes before, \(try Data(contentsOf: file).count) bytes after")
        let report = times.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-deck-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests deck\n\(report)")
    }

    /// Shared copies on a real Riftbound collection, offline (phase 3B: E2–E8, A22, A24). Skipped unless `TCG_REAL_STORE` is
    /// set and its root has `user/riftbound.json`. The file must hold no active deck, no `sharing` answer and no `wanted`
    /// entry, else it fails at once (give it a fresh copy). A deck that is not active is allowed: in a full run
    /// `testADeckOnTheRealCollection` (name order: first) leaves one. Four launches:
    /// 1. The Collection: its first 16 distinct card names from the cells' labels (never constants). For the first name that
    ///    is no rune (a basic card is never shared), the search for that name: when every shown printing has that name, the
    ///    subtitle's copies are the copies owned of the card (`a of b copies`); else the next name.
    /// 2. and 3. `-pasteDeck` with a text the test writes into its own temporary folder, for a new deck each: the card at its
    ///    owned count and four other cards of the Collection at 1 copy (other four in each deck), "Read", "Create deck",
    ///    Deck ▸ Active. After the second: the second deck's sidebar count is the owned count (E4: the first deck takes every
    ///    owned copy), the first deck has none.
    /// 4. Wanted (`-screen wanted`): one cell, the card, `<name>, ×<owned>, <owned> for decks, …` (E5, A24), "Decision
    ///    pending", "Decisions (1)…"; "Share" → the cell goes (shared: the largest use equals the owned count), the file's
    ///    `sharing` is `[<card key>: true]`, the second deck's count goes. Then both decks are set not active again, so a
    ///    later test of this class on the same root (the lists test sells a printing of the Collection's first cells) sees
    ///    no deck's need.
    /// After the last quit: `collection`, `wanted`, `forSale` and `sold` as before; two more decks, not active; the answer.
    /// The byte comparison of those four lists is a step outside the test (the report's "Sharing, phase 3B check").
    /// Attachment `real-sharing-timings`: launch → Wanted's cell with its decks' part, and the "Share" click → the cell's
    /// change (each measured from outside, polled every 0.2 s: an upper bound).
    func testSharedCopiesOnTheRealCollection() throws {
        let root = try realStoreRoot()
        let file = root.appending(path: "user").appending(path: "riftbound.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("\(file.path) is not there: this test runs on a root whose Riftbound collection is imported")
        }
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], file.path)
        let decksBefore = (initial["decks"] as? [[String: Any]]) ?? []
        XCTAssertFalse(decksBefore.contains { $0["active"] as? Bool == true }, "\(file.path) has an active deck: give the test a fresh copy")
        XCTAssertTrue((initial["sharing"] as? [Any])?.isEmpty ?? true, "\(file.path) has sharing answers: give the test a fresh copy")
        XCTAssertTrue((initial["wanted"] as? [Any])?.isEmpty ?? true, "\(file.path) has wanted cards: give the test a fresh copy")
        let bytesBefore = try Data(contentsOf: file).count
        var times: [String] = []
        let seconds = { (from: Date) in String(format: "%.1f s", Date().timeIntervalSince(from)) }

        // 1. A card he owns, and how many copies.
        var app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        let rows = try storedCollection(game: "riftbound")
        XCTAssertTrue(waitUntil(timeout: 60) { app.windows.firstMatch.title.hasSuffix(" " + self.totals(rows)) },
                      app.windows.firstMatch.title)
        let names = try collectionNames(app, count: 16)
        var chosen: (name: String, owned: Int)?
        for name in names.prefix(8) where !name.hasSuffix(" Rune") {
            if let owned = try copiesOwned(app, of: name) { chosen = (name, owned); break }
        }
        let card = try XCTUnwrap(chosen, "none of the first 8 names could be counted alone: \(names.prefix(8))")
        XCTAssertGreaterThan(card.owned, 0)
        let others = names.filter { $0.caseInsensitiveCompare(card.name) != .orderedSame }
        XCTAssertGreaterThanOrEqual(others.count, 8, "\(names)")
        quit(app)

        // 2. and 3. Two decks by paste, each set active. A failed run sets them not active too (final fix A7), so a later
        // test of this class on the same root sees no deck's need.
        var deckIDs: [String] = []
        sharingDecks = []
        addTeardownBlock { @MainActor [unowned self] in
            self.setNotActive(self.sharingDecks, root: root)
        }
        for (index, extra) in [others[0..<4], others[4..<8]].enumerated() {
            let paste = (["\(card.owned) \(card.name)"] + extra.map { "1 \($0)" }).joined(separator: "\n") + "\n"
            let (running, id) = try pasteNewDeck(root: root, text: paste, copies: card.owned + 4, known: idsOf(decksBefore) + deckIDs)
            app = running
            deckIDs.append(id)
            sharingDecks = deckIDs
            if index == 1 {
                let count = element(app, "sidebar-deck-missing-\(id)")
                XCTAssertTrue(waitUntil(timeout: 30) { count.exists && self.text(count) == "\(card.owned)" },
                              "the second deck's count: \(count.exists ? text(count) : "none"), not \(card.owned)")
                XCTAssertFalse(element(app, "sidebar-deck-missing-\(deckIDs[0])").exists, "the first deck misses copies")
                shot("real-sharing-1-second-deck")
            }
            quit(app)
        }
        let decks = storedDecks().filter { deckIDs.contains($0["id"] as? String ?? "") }
        XCTAssertEqual(decks.map { $0["active"] as? Bool }, [true, true])
        let keys = decks.map { Set(cards(ofDeck: $0).map(\.key)) }
        let common = keys[0].intersection(keys[1])
        XCTAssertEqual(common.count, 1, "\(keys)")
        let key = try XCTUnwrap(common.first)
        let savedName = try XCTUnwrap(((decks[0]["cards"] as? [[String: Any]]) ?? [])
            .first { $0["cardKey"] as? String == key }?["name"] as? String)

        // 4. Wanted: the decks' part, the pending mark, Share.
        let launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "wanted"])
        let cell = app.buttons["wanted-cell-\(key)"]
        let expected = "\(savedName), ×\(card.owned), \(card.owned) for decks, "
        XCTAssertTrue(waitUntil(timeout: 60) { cell.exists && cell.label.hasPrefix(expected) },
                      "\(cell.exists ? cell.label : "no cell"), not \(expected)…")
        times.append("launch -> Wanted's cell with its decks' part: \(seconds(launched))")
        XCTAssertEqual(identifiers(wantedCells(app)), ["wanted-cell-\(key)"])
        let pending = element(app, "wanted-pending-\(key)")
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "no pending row")
        XCTAssertEqual(text(pending), "Decision pending")
        XCTAssertEqual(element(app, "wanted-decisions").label, "Decisions (1)…")
        XCTAssertEqual(text(element(app, "sidebar-deck-missing-\(deckIDs[1])")), "\(card.owned)")
        XCTAssertFalse(text(app.staticTexts["status-line"]).contains("sharing decision"), "the launch said the pending card")
        let share = settled(reveal(app, "wanted-share-\(key)", in: "wanted-screen"))
        shot("real-sharing-2-wanted-pending")
        let clicked = Date()
        share.click()
        XCTAssertTrue(waitUntil { !cell.exists }, "the shared card stayed on Wanted")
        times.append("Share click -> the cell gone: \(seconds(clicked))")
        XCTAssertTrue(waitUntil { self.storedSharing() == [key: true] }, "\(storedSharing())")
        XCTAssertTrue(waitUntil { !self.element(app, "sidebar-deck-missing-\(deckIDs[1])").exists }, "the second deck still misses copies")
        XCTAssertFalse(element(app, "wanted-decisions").exists, "Decisions stays with nothing pending")
        shot("real-sharing-3-wanted-after-share")

        // Both decks not active again (a later test of this class on the same root).
        setNotActive(deckIDs, root: root)

        // After the last quit: the other lists as before, the answer, two more decks, not active.
        let final = try XCTUnwrap(storedUserFile(game: "riftbound"))
        for list in ["collection", "wanted", "forSale", "sold"] {
            XCTAssertEqual(final[list] as? NSArray, initial[list] as? NSArray, "\(list) changed")
        }
        XCTAssertEqual(storedSharing(), [key: true])
        XCTAssertEqual(storedDecks().count, decksBefore.count + 2)
        XCTAssertFalse(storedDecks().contains { $0["active"] as? Bool == true }, "a deck stays active")
        times.append("riftbound.json: \(bytesBefore) bytes before, \(try Data(contentsOf: file).count) bytes after")
        let report = times.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-sharing-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests sharing\n\(report)")
    }

    /// Sets the decks `ids` of the Riftbound file not active again, through the app (Deck ▸ Active on each deck page), and
    /// quits it. Only the ones still active; nothing when none is. Uses the app of the test while it runs, else launches it
    /// on `root` (a teardown after a failure: final fix A7).
    private func setNotActive(_ ids: [String], root: URL) {
        let active = ids.filter { id in storedDecks().first { $0["id"] as? String == id }?["active"] as? Bool == true }
        guard !active.isEmpty else { return }
        let app: XCUIApplication
        if let running = self.app, running.state == .runningForeground || running.state == .runningBackground {
            app = running
        } else {
            app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        }
        for id in active {
            guard let name = storedDecks().first(where: { $0["id"] as? String == id })?["name"] as? String else {
                XCTFail("\(id) is not in the file")
                continue
            }
            element(app, "sidebar-deck-\(id)").click()
            XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasPrefix(name + " – ") && self.element(app, "deck-screen").exists },
                          "the deck page of \(id) did not open: \(app.windows.firstMatch.title)")
            element(app, "deck-menu").click()
            let item = app.menuItems["Active"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "no Active item")
            item.click()
            XCTAssertTrue(waitUntil { self.storedDecks().first { $0["id"] as? String == id }?["active"] as? Bool == false },
                          "\(id) stays active")
        }
        quit(app)
    }

    /// The copies owned of the card `name`: the Collection's search for it, when every shown printing has that name (the
    /// label's product name without its trailing brackets): the subtitle's `<a> of <b> copies`. Nil when another card
    /// shows too. Empties the search field after.
    private func copiesOwned(_ app: XCUIApplication, of name: String) throws -> Int? {
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        defer {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
        }
        let window = app.windows.firstMatch
        let pattern = /([\d,]+) of [\d,]+ cop(?:y|ies) · ([\d,]+) of [\d,]+ printings?/
        var title = ""
        // The subtitle follows each keystroke: wait until it shows a part and is the same on two reads.
        XCTAssertTrue(waitUntil(timeout: 20) {
            let now = window.title
            defer { title = now }
            return now == title && now.firstMatch(of: pattern) != nil
        }, window.title)
        let match = try XCTUnwrap(title.firstMatch(of: pattern), title)
        let number = { (text: Substring) in Int(text.replacingOccurrences(of: ",", with: "")) ?? -1 }
        let copies = number(match.1), printings = number(match.2)
        let cells = collectionCells(app)
        var seen: [String: String] = [:]                        // identifier → label
        for _ in 0..<20 where seen.count < printings {
            for cell in cells.allElementsBoundByIndex where cell.exists { seen[cell.identifier] = cell.label }
            if seen.count < printings, let shown = cells.allElementsBoundByIndex.last(where: \.isHittable) {
                shown.scroll(byDeltaX: 0, deltaY: -300)
            }
        }
        guard seen.count == printings else { return nil }
        let alone = seen.values.allSatisfy { label in
            guard let end = label.range(of: ", ×") else { return false }
            return Self.withoutBrackets(String(label[..<end.lowerBound])).caseInsensitiveCompare(name) == .orderedSame
        }
        return alone ? copies : nil
    }

    /// Launches on the Collection with `-pasteDeck` and `text` (written into the runner's temporary folder), for a new deck:
    /// "Read" (every line known: "<copies> cards on 5 lines"), "Create deck", then Deck ▸ Active on the deck's page. Returns
    /// the running app and the new deck's id (the one not in `known`).
    private func pasteNewDeck(root: URL, text: String, copies: Int, known: [String]) throws -> (XCUIApplication, String) {
        let pasteFile = FileManager.default.temporaryDirectory.appending(path: "sharing-check-paste-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: pasteFile)
        defer { try? FileManager.default.removeItem(at: pasteFile) }
        let app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection", "-pasteDeck", pasteFile.path])
        let sheet = element(app, "paste-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no paste sheet")
        let read = element(app, "paste-read")
        XCTAssertTrue(waitUntil(timeout: 30) { read.isEnabled }, "Read stays off")
        read.click()
        let summary = element(app, "paste-summary")
        XCTAssertTrue(waitUntil(timeout: 60) { summary.exists }, "no table")
        XCTAssertEqual(self.text(summary), "\(copies) cards on 5 lines")
        let apply = element(app, "paste-apply")
        XCTAssertTrue(waitUntil { apply.isEnabled }, "Create deck stays off")
        apply.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        var id: String?
        XCTAssertTrue(waitUntil {
            id = self.storedDecks().compactMap { $0["id"] as? String }.first { !known.contains($0) }
            return id != nil
        }, "no new deck in the file")
        let deckID = try XCTUnwrap(id)
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10), "the new deck's page did not open")
        element(app, "deck-menu").click()
        let active = app.menuItems["Active"].firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5), "no Active item")
        active.click()
        XCTAssertTrue(waitUntil { self.storedDecks().first { $0["id"] as? String == deckID }?["active"] as? Bool == true },
                      "\(deckID) is not active")
        return (app, deckID)
    }

    /// The ids of `decks`.
    private func idsOf(_ decks: [[String: Any]]) -> [String] {
        decks.compactMap { $0["id"] as? String }
    }

    /// The sharing answers of the running root's Riftbound file: card key → shared.
    private func storedSharing() -> [String: Bool] {
        let list = (((try? storedUserFile(game: "riftbound")) ?? nil)?["sharing"] as? [[String: Any]]) ?? []
        return Dictionary(list.compactMap { entry in
            (entry["cardKey"] as? String).flatMap { key in (entry["shared"] as? Bool).map { (key, $0) } }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Waits until `element` stops moving (a scroll's deceleration), so a click lands on it: once its frame was the same
    /// on two reads 0.3 s apart. Returns the element.
    private func settled(_ element: XCUIElement) -> XCUIElement {
        var last = element.frame
        _ = waitUntil(timeout: 3) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            defer { last = element.frame }
            return element.frame == last
        }
        return element
    }

    /// The Collection's first `count` distinct card names in reading order, from the cells' labels (`<product name>, ×<n>,
    /// …`): the product name without its trailing brackets (`Calm Rune (R02a)` → `Calm Rune`). Scrolls the gallery while
    /// it needs more.
    private func collectionNames(_ app: XCUIApplication, count: Int) throws -> [String] {
        var names: [String] = []
        let cells = collectionCells(app)
        XCTAssertTrue(waitUntil(timeout: 30) { cells.count > 0 }, "no Collection cell")
        for _ in 0..<40 where names.count < count {
            for identifier in identifiersInOrder(cells) {
                let label = app.buttons[identifier].label
                guard let end = label.range(of: ", ×") else { continue }
                let name = Self.withoutBrackets(String(label[..<end.lowerBound]))
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            }
            // The gallery's scroll view is not found by its identifier on every run: a cell's scroll moves its gallery.
            if names.count < count, let shown = cells.allElementsBoundByIndex.last(where: \.isHittable) {
                shown.scroll(byDeltaX: 0, deltaY: -300)
            }
        }
        XCTAssertGreaterThanOrEqual(names.count, count, "\(names)")
        return Array(names.prefix(count))
    }

    /// Searches `name` in the deck's search (the field emptied first), clicks `+` once under the cell whose label starts
    /// with the name, waits for its count 1, and returns the card key (from the cell's identifier).
    private func addFromSearch(_ app: XCUIApplication, name: String) throws -> String {
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'card-cell-' AND label BEGINSWITH %@",
                                                                        name + ", ")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "no result for \(name): \(identifiers(cardCells(app)))")
        let key = String(cell.identifier.dropFirst("card-cell-".count))
        let plus = element(app, "deck-add-plus-\(key)")
        XCTAssertTrue(waitUntil(timeout: 20) { plus.exists && plus.isEnabled }, "+ of \(key) is off")
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-add-value-\(key)")) == "1" },
                      text(element(app, "deck-add-value-\(key)")))
        return key
    }

    /// The deck page's subtitle and section titles against the file: `<n> cards` and `<Section> · <n>` per section the
    /// deck uses.
    private func assertDeckPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let stored = cards(of: storedDecks())
        let total = stored.reduce(0) { $0 + $1.count }
        let window = app.windows.firstMatch
        XCTAssertTrue(waitUntil(timeout: 30) { window.title.contains(" – \(total) cards") }, "\(window.title), not \(total) cards",
                      file: file, line: line)
        var bySection: [String: Int] = [:]
        for card in stored { bySection[card.section, default: 0] += card.count }
        for (section, count) in bySection {
            let name = Self.riftboundSections[section] ?? section
            let title = element(app, "deck-section-\(section)")
            XCTAssertTrue(waitUntil { self.text(title) == "\(name) · \(count)" }, "\(self.text(title)), not \(name) · \(count)",
                          file: file, line: line)
        }
    }

    /// The decks of the running root's Riftbound file as the app wrote them; [] without.
    private func storedDecks() -> [[String: Any]] {
        (((try? storedUserFile(game: "riftbound")) ?? nil)?["decks"] as? [[String: Any]]) ?? []
    }

    /// The cards of the first deck: card key, section, count.
    private func cards(of decks: [[String: Any]]) -> [(key: String, section: String, count: Int)] {
        decks.first.map(cards(ofDeck:)) ?? []
    }

    /// The cards of one deck: card key, section, count.
    private func cards(ofDeck deck: [String: Any]) -> [(key: String, section: String, count: Int)] {
        ((deck["cards"] as? [[String: Any]]) ?? []).map {
            ($0["cardKey"] as? String ?? "", $0["section"] as? String ?? "", $0["count"] as? Int ?? 0)
        }
    }

    /// The copies of the first deck.
    private func deckCount(_ decks: [[String: Any]]) -> Int {
        cards(of: decks).reduce(0) { $0 + $1.count }
    }

    /// The element `identifier` of a screen (the deck page unless `screen` names another container), scrolled into the
    /// window (a group's cells are in a lazy grid).
    private func reveal(_ app: XCUIApplication, _ identifier: String, in screen: String = "deck-screen") -> XCUIElement {
        let target = element(app, identifier), page = element(app, screen)
        for _ in 0..<30 where !(target.exists && target.isHittable) {
            page.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(target.exists && target.isHittable, "\(identifier) is not in the window")
        return target
    }

    /// A name without its trailing bracket groups (`Calm Rune (R02a)` → `Calm Rune`).
    private static func withoutBrackets(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// The misspelling of the check: the name without its third letter (`Calm Rune` → `Cam Rune`); nil with fewer than four
    /// letters.
    private static func withoutThirdLetter(_ name: String) -> String? {
        guard name.count(where: \.isLetter) >= 4 else { return nil }
        var letters = 0
        for index in name.indices where name[index].isLetter {
            letters += 1
            if letters == 3 { return String(name[..<index]) + String(name[name.index(after: index)...]) }
        }
        return nil
    }
}
