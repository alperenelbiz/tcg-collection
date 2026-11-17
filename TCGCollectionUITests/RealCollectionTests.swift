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
            let lineMatch = ElementMatch(.any, "identifier BEGINSWITH 'import-skipped-line-'")
            let lines = lineMatch.query(sheet)
            XCTAssertTrue(waitUntil { lines.count > 0 }, "no line under \(skipped.label)")
            scrollView.scroll(byDeltaX: 0, deltaY: -2000)
            // One snapshot: the table is a lazy stack.
            notImported.lines = snapshotElements(sheet, lineMatch).map(\.text)
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
        let candidates = identifiersInOrder(app, .collectionCells).prefix(12).map { String($0.dropFirst("collection-cell-".count)) }
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
        XCTAssertTrue(waitUntil { Set(self.identifiers(app, .wantedCells)) == wantedIDs },
                      "\(identifiers(app, .wantedCells)), not \(wantedIDs)")
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
        XCTAssertTrue(waitUntil { Set(self.identifiers(app, .wantedCells)) == wantedIDs }, "\(identifiers(app, .wantedCells))")
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

    // MARK: Price history (phase 5A task 7; phase 5B task 6: the day files)

    /// The price history on a real collection, offline (A34–A37, A42, A45, A47, H1, H5, H6, H8, H9, K1, K3, K5, K6, K11;
    /// Review Focus 1). Skipped unless `TCG_REAL_STORE` is set, its root has `user/riftbound.json`, and the window (the 90
    /// UTC days that end on the app's wanted day) has a day: a daily price archive in `caches/archives`
    /// (`prices-YYYY-MM-DD.ppmd.7z`) or a day file in `support/price-days` (`<day>.prices`). The root needs no price file.
    /// XCTest's name order runs it after the deck test and before the profiles test; a deck test run with archives on disk
    /// may have written the history files and the day files already, so a history file that is there before is allowed,
    /// and only its content is checked. Two launches, on Riftbound's Collection:
    /// 1. The Collection's subtitle agrees with the file. `riftbound.prices.json` comes: its `days` are the days of the
    ///    window (the archives' and the day files'), and its product ids hold every product of the collection. Phase 5B:
    ///    no archive is left in `caches/archives`, `support/price-days` has one `<day>.prices` per day of the window and
    ///    no `.prices.tmp` (K3, K11: the launch decoded each archive into its day file and deleted it). Once the history
    ///    files have stayed unchanged for 5 s: every file of `user/` that is not a history file is byte-equal to before,
    ///    none is removed, and every file added or changed is the history file of a known game. The cell to open and what
    ///    its block shows come from that file (`chooseCell`): a visible cell of a product with one owned finish, the first
    ///    with two or more priced days (the chart), else the first (one day: "Price history starts on …"; none: "No price
    ///    in the last 90 days."). Phase 5B: the block reads its printing's days when the page opens (K6), so the first
    ///    state it shows may be "Reading price history…" for a moment; the first other state must be the expected one.
    ///    Then All cards: among its first cells, a card whose shown printing is not owned ("In your collection: 0")
    ///    shows its chart from the day files (A45); the download line's button is not there (offline: no backfill, A48).
    ///    That proves a chart of an untracked printing only when `riftbound.json` has no Wanted entry and no deck (then
    ///    the history file cannot hold that printing): true in a run alone on a fresh copy. When the file has either (the
    ///    class's earlier tests leave a deck), this part is skipped and the attachment says why. Then a quit.
    /// 2. The same day: the same cell's block shows the same state within 60 s, then the quiet time and a margin pass.
    ///    Quit: every file of `user/`, the history files included, is byte-equal to the end of launch 1 (no second write
    ///    on one UTC day); still no archive; every day file is byte-equal with its modification date unchanged (no second
    ///    decode, K1: written once).
    /// A history file that is there before the launch (the deck test, first by name, writes one when the root has
    /// archives) is allowed; the attachment says "before the launch: yes" then, and the run does not prove that this
    /// build's first launch creates the file or the day files: that evidence is a run of this test alone on a fresh copy
    /// ("no"). It leaves the `<game>.prices.json` files in `user/` and the day files in `support/price-days`; the later
    /// tests of the class do not compare them. No number or name of the owner is in the test. Attachment
    /// `real-history-timings` (times measured from outside, polled every 0.2 s: an upper bound).
    func testPriceHistoryOnTheRealCollection() throws {
        let root = try realStoreRoot()
        let folder = root.appending(path: "user")
        guard FileManager.default.fileExists(atPath: folder.appending(path: "riftbound.json").path) else {
            throw XCTSkip("\(folder.path)/riftbound.json is not there: this test runs on a root whose Riftbound collection is imported")
        }
        let archives = root.appending(path: "caches/archives")
        let priceDays = root.appending(path: "support/price-days")
        let wanted = Self.wantedDay()
        let first = Self.day(wanted, movedBy: -89)
        let archiveDays = Self.archiveDays(in: archives)
        let dayFilesBefore = Self.dayFileDays(in: priceDays)
        let expectedDays = archiveDays.union(dayFilesBefore).filter { $0 >= first && $0 <= wanted }.sorted()
        guard !expectedDays.isEmpty else {
            throw XCTSkip("no price archive or day file of \(first)…\(wanted) in \(root.path): copy the archives first")
        }
        let before = try allFiles(folder, history: true)
        let historyFile = folder.appending(path: "riftbound.prices.json")
        var times: [String] = ["days in the window: \(expectedDays.count) (archives \(archiveDays.count), "
                                   + "day files \(dayFilesBefore.count) before the launch)",
                               "riftbound.prices.json before the launch: \(before["riftbound.prices.json"] == nil ? "no" : "yes")"]
        let seconds = { (from: Date) in String(format: "%.1f s", Date().timeIntervalSince(from)) }

        // 1. The first launch on the copy: the archives become day files, the history file comes, nothing else changes.
        var launched = Date()
        var app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        let rows = try storedCollection(game: "riftbound")         // read only: `root` is set by the launch
        XCTAssertTrue(waitUntil(timeout: 60) { self.mainWindow(app).title.hasSuffix(" " + self.totals(rows)) }, mainWindow(app).title)
        times.append("launch -> the Collection's subtitle: \(seconds(launched))")
        XCTAssertTrue(waitUntil(timeout: 600) {
            Self.archiveDays(in: archives).isEmpty && Set(expectedDays).isSubset(of: Self.dayFileDays(in: priceDays))
        }, "archives left: \(Self.archiveDays(in: archives).count), day files: \(Self.dayFileDays(in: priceDays).count)")
        times.append("launch -> every archive a day file, no archive left: \(seconds(launched))")
        let owned = Set(rows.map(\.productID))
        XCTAssertTrue(waitUntil(timeout: 600) {
            guard let history = Self.history(historyFile) else { return false }
            return history.days == expectedDays && owned.isSubset(of: history.products)
        }, "riftbound.prices.json: \(Self.history(historyFile).map { "\($0.days.count) days" } ?? "none")")
        times.append("launch -> riftbound.prices.json with every day and every owned product: \(seconds(launched))")
        // At rest first: another game's atomic write of the same pass may still have its temporary file in the folder.
        let settledAt = Date()
        XCTAssertTrue(waitUntilFilesRest(folder, for: 5, timeout: 300), "the history files kept changing")
        times.append("the history files at rest for 5 s: \(seconds(settledAt))")
        try assertOnlyHistoryAdded(folder, before)
        XCTAssertEqual(Self.archiveDays(in: archives), [], "an archive is left in caches/archives")
        XCTAssertEqual(Self.dayFileDays(in: priceDays).filter { $0 >= first && $0 <= wanted }.sorted(), expectedDays,
                       "the day files of the window")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: priceDays.path)) ?? []).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "a temporary day file is left in support/price-days")
        let dayFileSizes = Self.dayFiles(in: priceDays).values.map(\.data.count)
        times.append(String(format: "day files: %d, %.2f MB in all", dayFileSizes.count,
                            Double(dayFileSizes.reduce(0, +)) / 1_000_000))

        // The cell and the block it must show, decided from the file the app wrote.
        let history = try XCTUnwrap(Self.history(historyFile), "riftbound.prices.json does not read")
        let (cellID, expected) = try chooseCell(app, rows: rows, history: history)
        times.append("the chosen cell's expected block: \(expected)")
        let opened = Date()
        let outcome = try historyBlock(app, cell: cellID, expected: expected, firstLook: true,
                                       picture: "real-history-1-card-page")
        times.append("the chosen cell's block: \(outcome) (\(seconds(opened)) after the click)")

        // A card that is not owned has its chart from the day files (A45, K6). Only on a file with no Wanted entry and no
        // deck: else the history file could hold that printing (a run alone on a fresh copy has neither).
        let file = try storedUserFile(game: "riftbound") ?? [:]
        let tracksCards = !((file["wanted"] as? [Any])?.isEmpty ?? true) || !((file["decks"] as? [Any])?.isEmpty ?? true)
        if tracksCards {
            times.append("a card not owned: skipped (riftbound.json has a Wanted entry or a deck: run this test alone on a fresh copy)")
        } else {
            element(app, "sidebar-all-cards").click()
            let notOwned = try notOwnedChart(app, picture: "real-history-3-not-owned")
            times.append("a card not owned: \(notOwned)")
        }
        quit(app)
        try assertOnlyHistoryAdded(folder, before)
        let afterFirst = try allFiles(folder, history: true)
        let size = afterFirst["riftbound.prices.json"]?.count ?? 0
        times.append(String(format: "riftbound.prices.json: %.1f KB", Double(size) / 1_000))
        times.append("history files: \(afterFirst.keys.filter { Self.isHistoryFile($0) }.sorted().joined(separator: ", "))")
        let dayFilesAfterFirst = Self.dayFiles(in: priceDays)

        // 2. A second launch on the same day writes nothing and decodes nothing.
        launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        XCTAssertTrue(waitUntil(timeout: 60) { self.mainWindow(app).title.hasSuffix(" " + self.totals(rows)) }, mainWindow(app).title)
        _ = try historyBlock(app, cell: cellID, expected: expected, firstLook: false,
                             picture: "real-history-2-second-launch")
        times.append("second launch -> the chosen cell's block: \(seconds(launched))")
        // The pass of this launch (after the launch's price step) and the quiet time of a change (3 s) end well within it.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        quit(app)
        try assertUnchanged(folder, afterFirst, "after a second launch on the same day", history: true)
        XCTAssertEqual(Self.archiveDays(in: archives), [], "an archive came back after the second launch")
        let dayFilesAfterSecond = Self.dayFiles(in: priceDays)
        XCTAssertEqual(dayFilesAfterSecond.keys.sorted(), dayFilesAfterFirst.keys.sorted(), "the day files after a second launch")
        for (name, file) in dayFilesAfterFirst {
            XCTAssertEqual(dayFilesAfterSecond[name]?.data, file.data, "\(name) changed on the second launch")
            XCTAssertEqual(dayFilesAfterSecond[name]?.modified, file.modified, "\(name) was written again on the second launch")
        }

        let report = times.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-history-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests price history\n\(report)")
    }

    /// The days of the day files in `folder` (`<yyyy-MM-dd>.prices`, phase 5B).
    private static func dayFileDays(in folder: URL) -> Set<String> {
        Set(dayFiles(in: folder).keys.map { String($0.dropLast(".prices".count)) })
    }

    /// The day files of `folder` by name, with their bytes and modification dates.
    private static func dayFiles(in folder: URL) -> [String: (data: Data, modified: Date?)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [String: (data: Data, modified: Date?)] = [:]
        for name in names where name.wholeMatch(of: /\d{4}-\d{2}-\d{2}\.prices/) != nil {
            let url = folder.appending(path: name)
            guard let data = try? Data(contentsOf: url) else { continue }
            files[name] = (data, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return files
    }

    /// On All cards: opens its first cells one by one (at most 12, from one snapshot) until a card whose shown printing
    /// is not owned ("In your collection: 0") shows a chart with its summary; checks that the download line has no button
    /// (offline); keeps a picture; returns what each opened cell showed. Fails when none of them shows a chart.
    private func notOwnedChart(_ app: XCUIApplication, picture: String,
                               file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let match = ElementMatch(.any, "identifier BEGINSWITH 'card-cell-'")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.identifiersInOrder(app, match).isEmpty }, "no All cards cell",
                      file: file, line: line)
        var seen: [String] = []
        for (index, cell) in identifiersInOrder(app, match).prefix(12).enumerated() {
            let link = app.buttons[cell]
            guard link.waitForExistence(timeout: 10) else { continue }
            for _ in 0..<10 where !link.isHittable { element(app, "gallery").scroll(byDeltaX: 0, deltaY: -150) }
            settled(link).click()
            let page = element(app, "card-page")
            XCTAssertTrue(page.waitForExistence(timeout: 10), "no card page", file: file, line: line)
            let owned = element(app, "card-owned")
            _ = waitUntil(timeout: 10) { self.text(owned).hasPrefix("In your collection: ") && !self.text(owned).hasSuffix("—") }
            let block = element(app, "price-history")
            XCTAssertTrue(block.waitForExistence(timeout: 10), "no price history block", file: file, line: line)
            for _ in 0..<10 where !block.isHittable { page.scroll(byDeltaX: 0, deltaY: -200) }
            var state = ""
            _ = waitUntil(timeout: 30) { state = self.blockState(app); return !state.isEmpty && state != "Reading price history…" }
            let isOwned = text(owned) != "In your collection: 0"
            seen.append("cell \(index + 1): \(isOwned ? "owned" : "not owned"), \(state)")
            if !isOwned && state == "chart" {
                XCTAssertTrue(element(app, "price-history-summary").exists, "a chart without its summary", file: file, line: line)
                XCTAssertFalse(app.buttons["price-history-download"].exists, "a download button offline", file: file, line: line)
                showPlot(app, page: page)
                shot(picture)
                app.toolbars.buttons["Back"].firstMatch.click()
                return seen.joined(separator: "; ")
            }
            app.toolbars.buttons["Back"].firstMatch.click()
            XCTAssertTrue(app.buttons[cell].waitForExistence(timeout: 10), "Back did not show All cards", file: file, line: line)
        }
        XCTFail("no card that is not owned showed a chart: \(seen.joined(separator: "; "))", file: file, line: line)
        return seen.joined(separator: "; ")
    }

    /// Scrolls the card page until the plot's bottom is inside the window (phase 5B task 6: the pictures show the plot,
    /// not only the heading at the window's edge); at most 10 steps.
    private func showPlot(_ app: XCUIApplication, page: XCUIElement) {
        let plot = element(app, "price-history-chart")
        let window = mainWindow(app).frame
        for _ in 0..<10 where plot.exists && plot.frame.maxY > window.maxY - 8 { page.scroll(byDeltaX: 0, deltaY: -120) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// What the price history block shows now: `"chart"`, `"one day"`, `"no price"`, another sentence as it is, or `""`
    /// (the frame with no sentence).
    private func blockState(_ app: XCUIApplication) -> String {
        if element(app, "price-history-chart").exists { return "chart" }
        let note = element(app, "price-history-note")
        guard note.exists else { return "" }
        let sentence = text(note)
        if sentence.hasPrefix("Price history starts on ") { return "one day" }
        if sentence == "No price in the last 90 days." { return "no price" }
        return sentence
    }

    /// The history file names the app may write: `<game id>.prices.json` of the four games.
    private static func isHistoryFile(_ name: String) -> Bool {
        gameOrder.contains { name == "\($0).prices.json" }
    }

    /// The days of the archives in `folder` (`prices-YYYY-MM-DD.ppmd.7z`, as the app names them).
    private static func archiveDays(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.compactMap { name in
            name.wholeMatch(of: /prices-(\d{4}-\d{2}-\d{2})\.ppmd\.7z/).map { String($0.1) }
        })
    }

    /// A history file as the app wrote it (`PriceHistory.data()`): its days, its product ids, and per product and finish
    /// the number of days with a price; nil with no file, or one that does not read.
    private struct StoredHistory {
        let days: [String]
        let priced: [Int: [String: Int]]
        var products: Set<Int> { Set(priced.keys) }
    }

    private static func history(_ url: URL) -> StoredHistory? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["version"] as? Int == 1, let days = object["days"] as? [String],
              let products = object["products"] as? [String: Any] else { return nil }
        var priced: [Int: [String: Int]] = [:]
        for (key, value) in products {
            guard let id = Int(key) else { continue }
            var finishes: [String: Int] = [:]
            for (finish, entry) in value as? [String: Any] ?? [:] {
                let prices = (entry as? [String: Any])?["prices"] as? [Any] ?? []
                finishes[finish] = prices.count { !($0 is NSNull) }
            }
            priced[id] = finishes
        }
        return StoredHistory(days: days, priced: priced)
    }

    /// The Collection cell to open and the block it must show, from the history file: among the visible cells (one
    /// snapshot) whose product has one owned finish (so the card page shows that finish first, A38), the first with two
    /// or more priced days (the chart), else the first of them (its count decides: one day, no price).
    private func chooseCell(_ app: XCUIApplication, rows: [StoredRow], history: StoredHistory) throws -> (String, String) {
        let finishesOwned = Dictionary(grouping: rows.filter { $0.count >= 1 }, by: \.productID).mapValues { $0.count }
        var candidates: [(id: String, days: Int)] = []
        for id in identifiersInOrder(app, .collectionCells) {
            let key = id.dropFirst("collection-cell-".count)
            guard let dash = key.firstIndex(of: "-"), let product = Int(key[..<dash]),
                  finishesOwned[product] == 1 else { continue }
            let finish = String(key[key.index(after: dash)...])
            candidates.append((id, history.priced[product]?[finish] ?? 0))
        }
        let chosen = try XCTUnwrap(candidates.first { $0.days >= 2 } ?? candidates.first,
                                   "no visible Collection cell of a product with one owned finish")
        return (chosen.id, chosen.days >= 2 ? "chart" : chosen.days == 1 ? "one day" : "no price")
    }

    /// Every file of `folder` that is not a history file is byte-equal to `before` and none is removed; every file added
    /// or changed is the history file of a known game.
    private func assertOnlyHistoryAdded(_ folder: URL, _ before: [String: Data],
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try allFiles(folder, history: true)
        for (name, data) in before where !Self.isHistoryFile(name) {
            XCTAssertEqual(now[name], data, "\(name) changed or was removed", file: file, line: line)
        }
        for (name, data) in now where before[name] != data {
            XCTAssertTrue(Self.isHistoryFile(name), "\(name) was added or changed", file: file, line: line)
        }
        for name in before.keys where now[name] == nil && Self.isHistoryFile(name) {
            XCTFail("\(name) was removed", file: file, line: line)
        }
    }

    /// Opens the card page of the Collection cell `cell`, scrolls to the price history block and checks it shows
    /// `expected`: `"chart"` (the plot and its summary), `"one day"` ("Price history starts on …") or `"no price"` ("No
    /// price in the last 90 days."). With `firstLook` the first state seen after "Reading price history…" must be it
    /// (any other sentence fails at once); else it must come within 60 s. Then keeps a picture `picture` of the card page
    /// with the block, and goes back to the Collection.
    @discardableResult
    private func historyBlock(_ app: XCUIApplication, cell: String, expected: String, firstLook: Bool, picture: String,
                              file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let link = app.buttons[cell]
        XCTAssertTrue(link.waitForExistence(timeout: 30), "\(cell) is not a link", file: file, line: line)
        // Phase 5B task 6: right after a launch the cell can exist before the window's content does (seen once: the
        // gallery was not in the hierarchy yet); wait for it before a scroll.
        _ = waitUntil(timeout: 10) { link.isHittable }
        let gallery = element(app, "collection-gallery")
        for _ in 0..<10 where !link.isHittable && gallery.waitForExistence(timeout: 10) {
            gallery.scroll(byDeltaX: 0, deltaY: -150)
        }
        settled(link).click()
        let page = element(app, "card-page")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "no card page", file: file, line: line)
        let block = element(app, "price-history")
        XCTAssertTrue(block.waitForExistence(timeout: 10), "no price history block", file: file, line: line)
        for _ in 0..<10 where !block.isHittable { page.scroll(byDeltaX: 0, deltaY: -200) }
        let seen = { self.blockState(app) }
        var outcome = ""
        if firstLook {
            // The first state the block shows (the frame with no sentence is not a state: wait for one). Phase 5B: the
            // page reads its printing's day files when it opens (K6), so "Reading price history…" may show for a moment.
            _ = waitUntil(timeout: 10) { outcome = seen(); return !outcome.isEmpty && outcome != "Reading price history…" }
        } else {
            _ = waitUntil(timeout: 60) { outcome = seen(); return outcome == expected }
        }
        XCTAssertEqual(outcome, expected, "the block of \(cell)", file: file, line: line)
        if outcome == "chart" {
            XCTAssertTrue(element(app, "price-history-summary").exists, "a chart without its summary", file: file, line: line)
            showPlot(app, page: page)
        }
        shot(picture)                                              // the card page with its block, before Back
        let back = app.toolbars.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button", file: file, line: line)
        back.click()
        XCTAssertTrue(app.buttons[cell].waitForExistence(timeout: 10), "Back did not show the Collection", file: file, line: line)
        return outcome
    }

    /// Waits until the history files of `folder` have stayed byte-equal for `rest` seconds (read every second).
    private func waitUntilFilesRest(_ folder: URL, for rest: TimeInterval, timeout: TimeInterval) -> Bool {
        let histories = { (try? self.allFiles(folder, history: true))?.filter { Self.isHistoryFile($0.key) } ?? [:] }
        var last = histories()
        var since = Date()
        return waitUntil(timeout: timeout) {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let now = histories()
            if now != last {
                last = now
                since = Date()
            }
            return Date().timeIntervalSince(since) >= rest
        }
    }

    // MARK: Profiles (phase 4B task 6)

    /// The four games in their fixed order, by id and by the name the game picker shows.
    private static let pickerNames = ["magic-the-gathering": "Magic: The Gathering", "yu-gi-oh": "Yu-Gi-Oh!",
                                      "riftbound": "Riftbound", "cyberpunk": "Cyberpunk TCG"]
    private static let gameOrder = ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"]

    /// The games the profiles test turned off in Settings, until it has turned them on again: its teardown block turns them
    /// on through the app after a failure too, so a later test of this class on the same root finds every game followed.
    private var profilesTurnedOff: [String] = []

    /// Games and roles on a real collection, offline (A28–A30, G1–G6, G10, G11; Review Focus 1). Skipped unless
    /// `TCG_REAL_STORE` is set and its root has `user/riftbound.json`; no file of `user/` may hold a `profile` key (else it
    /// fails at once: a fresh copy each run, a folder as the build before phase 4B wrote it). Every game but Riftbound is
    /// turned off and on: at least one of them must have a file and one must have none (read from the folder at run time).
    /// Three launches, each on Riftbound's Collection:
    /// 1. No `-onboarding` flag: the Collection's subtitle agrees with the file; no first-run question, no folder sheet; the
    ///    picker lists the four games; Decks ("New Deck…") and Sets are in the sidebar; the status line says offline. Quit:
    ///    every file of `user/` is byte-equal to the bytes read before the launch, and no file was added (A30). A Debug
    ///    build never asks without `-onboarding YES`, so this launch proves "no write", not "no question in Release".
    /// 2. `-onboarding YES`: still no question (the folder has game files: G11), the files still byte-equal while it runs,
    ///    and Settings shows the normal note (onboarding is not due). Settings: every game but Riftbound unticked; the picker
    ///    follows (only Riftbound), Riftbound's checkbox is off (G3). Quit: a file that was there differs only by
    ///    `profile` (`{"followed": false, "player": true, "collector": true}`); a game that had none now has
    ///    `{"version": 1, "collection": [], "profile": …}`; `riftbound.json` and `settings.json` are byte-equal.
    /// 3. One game followed: the launch's time to the Collection. (That no scan of a game not followed runs is checked by
    ///    the unit tests and by the shell runs of the catalog report's "Profiles, phase 4B check": this test cannot know when
    ///    the launch's scans have ended, and the sandboxed runner cannot remove a file of the root to wait for a fresh
    ///    one.) Settings: each game ticked again; the picker lists four games. Quit: each file that
    ///    was there differs from before only by `profile`, now all on; the files the test made stay, all on (G1: the key is
    ///    written once a file has it); `riftbound.json` and `settings.json` byte-equal.
    /// No number or name of the owner is in the test. Attachment `real-profiles-timings` (each time measured from outside,
    /// polled every 0.2 s: an upper bound).
    func testProfilesOnTheRealCollection() throws {
        let root = try realStoreRoot()
        let folder = root.appending(path: "user")
        guard FileManager.default.fileExists(atPath: folder.appending(path: "riftbound.json").path) else {
            throw XCTSkip("\(folder.path)/riftbound.json is not there: this test runs on a root whose Riftbound collection is imported")
        }
        let before = try userFiles(folder)
        // Every file under `user/`, also in a subfolder: what "nothing written" compares.
        let beforeAll = try allFiles(folder)
        for (name, data) in before where name.hasSuffix(".json") {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNil(object?["profile"], "\(name) has a profile: give the test a fresh copy")
        }
        let others = Self.gameOrder.filter { $0 != "riftbound" }
        let withFile = others.filter { before["\($0).json"] != nil }
        let withoutFile = others.filter { before["\($0).json"] == nil }
        XCTAssertFalse(withFile.isEmpty, "no game but Riftbound has a file in \(folder.path)")
        XCTAssertFalse(withoutFile.isEmpty, "every game has a file in \(folder.path)")
        var times: [String] = []
        let seconds = { (from: Date) in String(format: "%.1f s", Date().timeIntervalSince(from)) }
        profilesTurnedOff = []
        addTeardownBlock { @MainActor [unowned self] in
            self.restoreProfiles(root: root)
        }

        // 1. The first launch of this build on the folder: nothing written, nothing asked, everything shown.
        var launched = Date()
        var app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        let rows = try storedCollection(game: "riftbound")         // read only: `root` is set by the launch
        XCTAssertTrue(waitUntil(timeout: 60) { self.mainWindow(app).title.hasSuffix(" " + self.totals(rows)) }, mainWindow(app).title)
        times.append("launch -> the Collection's subtitle, four games followed: \(seconds(launched))")
        XCTAssertFalse(element(app, "onboarding-sheet").exists, "the first-run question on a folder with game files")
        XCTAssertFalse(element(app, "user-folder-sheet").exists)
        XCTAssertEqual(gamePickerItems(app), Self.gameOrder.compactMap { Self.pickerNames[$0] })
        XCTAssertTrue(element(app, "sidebar-new-deck").exists, "no Decks section")
        XCTAssertTrue(element(app, "sidebar-sets").exists, "no Sets row")
        let status = app.staticTexts["status-line"]
        XCTAssertTrue(waitUntil { status.exists && self.text(status).hasPrefix("Offline") }, status.exists ? text(status) : "no status line")
        shot("real-profiles-1-first-launch")
        quit(app)
        try assertUnchanged(folder, beforeAll, "after the first launch")

        // 2. `-onboarding YES` on that folder: no question. Then Settings turns every other game off.
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection", "-onboarding", "YES"])
        XCTAssertTrue(waitUntil(timeout: 60) { self.mainWindow(app).title.hasSuffix(" " + self.totals(rows)) }, mainWindow(app).title)
        XCTAssertFalse(waitUntil(timeout: 3) { self.element(app, "onboarding-sheet").exists }, "the first-run question with -onboarding YES")
        try assertUnchanged(folder, beforeAll, "while the -onboarding YES launch runs")
        var pane = openSettings(app)
        XCTAssertEqual(text(element(app, "settings-note")),
                       "A game or a role you turn off is hidden. Its cards, lists and decks stay in your folder.")
        profilesTurnedOff = others
        for game in others {
            let box = element(app, "profile-followed-\(game)")
            XCTAssertTrue(isTicked(box) && box.isEnabled, game)
            let clicked = Date()
            box.click()
            XCTAssertTrue(waitUntil { !self.isTicked(box) }, game)
            XCTAssertTrue(waitUntil { self.storedProfile(game) == Self.off }, "\(game): \(String(describing: storedProfile(game)))")
            times.append("untick \(game) -> its file says not followed: \(seconds(clicked))")
        }
        var riftbound = element(app, "profile-followed-riftbound")
        XCTAssertTrue(isTicked(riftbound))
        XCTAssertFalse(riftbound.isEnabled, "the last followed game can be turned off")
        shot("real-profiles-2-settings-one-game", of: pane)
        XCTAssertEqual(gamePickerItems(app), ["Riftbound"])
        XCTAssertTrue(element(app, "sidebar-new-deck").exists && element(app, "sidebar-sets").exists, "Riftbound's roles are on")
        quit(app)
        try assertProfiles(folder, before, withFile: withFile, withoutFile: withoutFile, profile: Self.off)

        // 3. One game followed. Then Settings turns the others on again.
        launched = Date()
        app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        XCTAssertTrue(waitUntil(timeout: 60) { self.mainWindow(app).title.hasSuffix(" " + self.totals(rows)) }, mainWindow(app).title)
        times.append("launch -> the Collection's subtitle, one game followed: \(seconds(launched))")
        XCTAssertEqual(gamePickerItems(app), ["Riftbound"])
        pane = openSettings(app)
        for game in others {
            let box = element(app, "profile-followed-\(game)")
            XCTAssertTrue(!isTicked(box) && box.isEnabled, game)
            box.click()
            XCTAssertTrue(waitUntil { self.isTicked(box) }, game)
            XCTAssertTrue(waitUntil { self.storedProfile(game) == Self.on }, "\(game): \(String(describing: storedProfile(game)))")
        }
        riftbound = element(app, "profile-followed-riftbound")
        XCTAssertTrue(waitUntil { riftbound.isEnabled }, "Riftbound stays the last followed game")
        shot("real-profiles-3-settings-four-games", of: pane)
        XCTAssertEqual(gamePickerItems(app), Self.gameOrder.compactMap { Self.pickerNames[$0] })
        quit(app)
        try assertProfiles(folder, before, withFile: withFile, withoutFile: withoutFile, profile: Self.on)
        profilesTurnedOff = []

        times.append("files of user/ before: \(before.count); after: \(try userFiles(folder).count) (made: \(withoutFile.map { "\($0).json" }.joined(separator: ", ")))")
        let report = times.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-profiles-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests profiles\n\(report)")
    }

    /// A profile as written: a game turned off in Settings (its roles stay on), and every member on.
    private static let off = ["followed": false, "player": true, "collector": true]
    private static let on = ["followed": true, "player": true, "collector": true]

    /// The regular files of `folder` by name, with their bytes. Without `history`, the price history files
    /// (`<game>.prices.json`, phase 5A) are left out: derived data that any launch with archives in the root may write
    /// (checked by the price history test).
    private func userFiles(_ folder: URL, history: Bool = false) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where history || !Self.isHistoryFile(name) {
            let url = folder.appending(path: name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[name] = try Data(contentsOf: url)
        }
        return files
    }

    /// Every regular file under `folder`, also in its subfolders, by its path relative to `folder`, with its bytes.
    /// Without `history`, the price history files of `folder` itself are left out (as `userFiles`).
    private func allFiles(_ folder: URL, history: Bool = false) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let base = folder.standardizedFileURL.path + "/"
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return files
        }
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = url.standardizedFileURL.path
            let name = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            if !history && Self.isHistoryFile(name) { continue }
            files[name] = try Data(contentsOf: url)
        }
        return files
    }

    /// Every file under `folder` (recursively, `allFiles`; the history files only with `history`) is byte-equal to
    /// `before`, and none was added or removed.
    private func assertUnchanged(_ folder: URL, _ before: [String: Data], _ when: String, history: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try allFiles(folder, history: history)
        XCTAssertEqual(now.keys.sorted(), before.keys.sorted(), "the files of user/ \(when)", file: file, line: line)
        for (name, data) in before where now[name] != data {
            XCTFail("\(name) changed \(when): \(data.count) bytes before, \(now[name]?.count ?? 0) now", file: file, line: line)
        }
    }

    /// After a quit: every game of `withFile` has `profile` and is otherwise its object of `before`; every game of
    /// `withoutFile` has a file `{"version": 1, "collection": [], "profile": …}`; every other file is byte-equal to `before`.
    private func assertProfiles(_ folder: URL, _ before: [String: Data], withFile: [String], withoutFile: [String],
                                profile: [String: Bool], file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try userFiles(folder)
        let changed = Set((withFile + withoutFile).map { "\($0).json" })
        XCTAssertEqual(Set(now.keys), Set(before.keys).union(changed), "the files of user/", file: file, line: line)
        for (name, data) in before where !changed.contains(name) {
            XCTAssertEqual(now[name], data, "\(name) changed", file: file, line: line)
        }
        for game in withFile {
            var object = try XCTUnwrap(storedUserFile(game: game), game, file: file, line: line)
            XCTAssertEqual(object["profile"] as? [String: Bool], profile, game, file: file, line: line)
            object["profile"] = nil
            let old = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(before["\(game).json"])) as? [String: Any])
            XCTAssertEqual(object as NSDictionary, old as NSDictionary, "\(game).json differs by more than its profile",
                           file: file, line: line)
        }
        for game in withoutFile {
            let object = try XCTUnwrap(storedUserFile(game: game), "\(game).json was not made", file: file, line: line)
            XCTAssertEqual(Set(object.keys), ["version", "collection", "profile"], game, file: file, line: line)
            XCTAssertEqual(object["version"] as? Int, 1, game, file: file, line: line)
            XCTAssertEqual((object["collection"] as? [Any])?.count, 0, game, file: file, line: line)
            XCTAssertEqual(object["profile"] as? [String: Bool], profile, game, file: file, line: line)
        }
    }

    /// A game file's `profile` object as written; nil with no file or no key.
    private func storedProfile(_ game: String) -> [String: Bool]? {
        (try? storedUserFile(game: game))??["profile"] as? [String: Bool]
    }

    /// The app's main window (the one with the game picker), also while Settings is in front.
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.any, identifier: "game-picker").firstMatch
    }

    /// A checkbox's value (0 or 1).
    private func isTicked(_ box: XCUIElement) -> Bool { (box.value as? NSNumber)?.boolValue ?? false }

    /// Opens Settings (Cmd+,) and returns its pane.
    private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let pane = element(app, "settings-games")
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "no Settings pane", file: file, line: line)
        return pane
    }

    /// The game picker's items, the first of each (an open menu may list them twice), read from ONE snapshot of the picker
    /// with its open menu, then the menu closed.
    private func gamePickerItems(_ app: XCUIApplication) -> [String] {
        let picker = element(app, "game-picker")
        picker.click()
        _ = app.menuItems["Riftbound"].firstMatch.waitForExistence(timeout: 5)
        var seen: [String] = []
        let items = (try? picker.snapshot()).map { root -> [String] in
            var titles: [String] = []
            func walk(_ node: any XCUIElementSnapshot) {
                if node.elementType == .menuItem { titles.append(node.title) }
                for child in node.children { walk(child) }
            }
            walk(root)
            return titles
        } ?? []
        for item in items where !item.isEmpty && !seen.contains(item) {
            seen.append(item)
        }
        app.typeKey(.escape, modifierFlags: [])
        return seen
    }

    /// The teardown of the profiles test: every game it turned off whose file still has a member off is turned on again
    /// through the app (the sandboxed runner cannot write into the root), in Settings. Nothing is removed: a file the test
    /// made stays.
    private func restoreProfiles(root: URL) {
        let games = profilesTurnedOff.filter { game in storedProfile(game).map { $0 != Self.on } ?? false }
        guard !games.isEmpty else { return }
        self.app?.terminate()
        let running = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "collection"])
        XCTAssertTrue(element(running, "game-picker").waitForExistence(timeout: 60), "no window")
        _ = openSettings(running)
        for game in games {
            for member in ["followed", "player", "collector"] where storedProfile(game)?[member] == false {
                element(running, "profile-\(member)-\(game)").click()
                XCTAssertTrue(waitUntil { self.storedProfile(game)?[member] == true }, "\(game) \(member) stays off")
            }
        }
        quit(running)
        profilesTurnedOff = []
    }

    // MARK: Sets (phase 4A task 5)

    /// The printing the sets test added (`<productID>-<finish>`, the cell's suffix), its product name and its set, until the
    /// test takes it off again: its teardown block takes it off after a failure too, so a later test of this class on the
    /// same root finds the collection as it was.
    private var setsAdded: (suffix: String, name: String, groupID: Int)?

    /// Sets on a real Riftbound collection, offline (A26, A27, F1, F2, F8). Skipped unless `TCG_REAL_STORE` is set and its
    /// root has `user/riftbound.json`. One launch on `-screen sets` (the copy has no set index file: the app makes it at
    /// launch, in the background):
    /// 1. The list opens on "My sets" with at least one row. The first row's `owned / total` equals the count the test makes
    ///    from the file and from the set index the app wrote (`support/sets-riftbound.json`): an owned target is a row of
    ///    the set's products with a count of 1 or more (F2; F1 makes every owned row a target). The total is checked only
    ///    on a root without price files (`support/prices-riftbound.json` absent): then it is one Normal target per product
    ///    plus every owned finish that is not Normal. With a price file the finishes come from the price table, which the
    ///    test does not read, so the total is not checked.
    /// 2. The first row's page with the Owned filter: its cells (scrolled through) are exactly those owned targets, and the
    ///    window's subtitle is the row's count.
    /// 3. On the first set that is not complete, the Missing filter's first cell: one `+`. The cell leaves Missing, the
    ///    subtitle and (after Back) the row's count move by one, and `collection` differs by exactly that row (count 1, the
    ///    product's name); the other lists are equal.
    /// 4. Owned, the product's name in the search field, `−` on that cell: `collection` is as before again (a later test of
    ///    this class reads the Collection's first cells; a teardown block does the same after a failure).
    /// No number or name of the owner is in the test: everything comes from the screen, the file and the index at run time.
    /// Attachment `real-sets-timings` (each time measured from outside, an upper bound).
    func testSetsOnTheRealCollection() throws {
        let root = try realStoreRoot()
        let file = root.appending(path: "user").appending(path: "riftbound.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("\(file.path) is not there: this test runs on a root whose Riftbound collection is imported")
        }
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], file.path)
        let unpriced = !FileManager.default.fileExists(atPath: root.appending(path: "support/prices-riftbound.json").path)
        let bytesBefore = try Data(contentsOf: file).count
        var times: [String] = []
        let seconds = { (from: Date) in String(format: "%.1f s", Date().timeIntervalSince(from)) }
        setsAdded = nil
        addTeardownBlock { @MainActor [unowned self] in
            self.takeOffSetsAdded(root: root)
        }

        // 1. My sets, its first row against the file and the index.
        let launched = Date()
        let app = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "sets"])
        let before = try storedCollection(game: "riftbound")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.setRows(app).isEmpty }, "no set row")
        times.append("launch -> the first Sets row (the index made at launch): \(seconds(launched))")
        XCTAssertEqual(setsSegment(app, "My sets", in: "sets-scope").value as? Int, 1, "the list does not open on My sets")
        let rows = setRows(app)
        let first = try XCTUnwrap(Int(try XCTUnwrap(rows.first).dropFirst("sets-row-".count)))
        let indexFile = root.appending(path: "support/sets-riftbound.json")
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: indexFile.path) }, "no \(indexFile.path)")
        let index = try setIndex(indexFile)
        let expected = try XCTUnwrap(setNumbers(groupID: first, index: index, rows: before), "the first row's set is not in the index")
        let count = element(app, "sets-count-\(first)")
        XCTAssertTrue(count.waitForExistence(timeout: 30), "no count on the row of \(first): \(app.buttons["sets-row-\(first)"].label)")
        XCTAssertTrue(waitUntil { self.text(count).hasPrefix("\(expected.owned) / ") }, "\(text(count)), not \(expected.owned) owned")
        XCTAssertGreaterThan(expected.owned, 0, "My sets lists a set with nothing owned")
        let shownTotal = try XCTUnwrap(Int(text(count).split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? ""), text(count))
        if unpriced { XCTAssertEqual(shownTotal, expected.total, "the total of \(first) is not one Normal target per product + the other owned finishes") }
        let subtitle = "\(expected.owned) of \(shownTotal)"
        shot("real-sets-1-my-sets")

        // 2. The first row's page, Owned: its cells are the owned targets.
        var clicked = Date()
        app.buttons["sets-row-\(first)"].click()
        XCTAssertTrue(element(app, "set-screen").waitForExistence(timeout: 10), "the set's page did not open")
        XCTAssertTrue(waitUntil(timeout: 30) { app.windows.firstMatch.title.hasSuffix(" – " + subtitle) }, app.windows.firstMatch.title)
        XCTAssertTrue(waitUntil(timeout: 30) { !self.setCellIDs(app).isEmpty }, "no cell on the set's page")
        times.append("row click -> the page's cells (\(index[first]?.count ?? 0) products): \(seconds(clicked))")
        shot("real-sets-2-set-page")
        setsSegment(app, "Owned", in: "set-filter").click()
        let owned = collectSetCells(app)
        XCTAssertEqual(owned, Set(expected.ownedKeys.map { "set-cell-\($0)" }), "the Owned cells are not the owned targets of the file")
        app.toolbars.buttons["Back"].firstMatch.click()

        // 3. One `+` on a missing target of the first set that is not complete.
        let shownIDs = setRows(app).compactMap { Int($0.dropFirst("sets-row-".count)) }
        let open = try XCTUnwrap(shownIDs.first { id in
            let parts = text(element(app, "sets-count-\(id)")).split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] != parts[1]
        }, "every set shown is complete")
        let openBefore = text(element(app, "sets-count-\(open)"))
        let parts = openBefore.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        app.buttons["sets-row-\(open)"].click()
        XCTAssertTrue(waitUntil(timeout: 30) { app.windows.firstMatch.title.hasSuffix(" – \(parts[0]) of \(parts[1])") },
                      app.windows.firstMatch.title)
        setsSegment(app, "Missing", in: "set-filter").click()
        XCTAssertTrue(waitUntil(timeout: 30) { !self.setCellIDs(app).isEmpty }, "no missing cell")
        let missing = try XCTUnwrap(setCellIDs(app).first)
        let suffix = String(missing.dropFirst("set-cell-".count))
        let label = app.buttons[missing].label
        let name = String(label[..<(try XCTUnwrap(label.range(of: ", missing", options: .backwards))).lowerBound])
        let key = try printing(suffix)
        let plus = revealSetControl(app, "set-cell-plus-\(suffix)")
        XCTAssertEqual(text(element(app, "set-cell-value-\(suffix)")), "0")
        clicked = Date()
        setsAdded = (suffix, name, open)
        plus.click()
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix(" – \(parts[0] + 1) of \(parts[1])") },
                      app.windows.firstMatch.title)
        times.append("+ click -> the subtitle's new count: \(seconds(clicked))")
        XCTAssertTrue(waitUntil { !app.buttons[missing].exists }, "the added target stays under Missing")
        let added = StoredRow(productID: key.productID, finish: key.finish, count: 1, name: name)
        var after: [StoredRow] = []
        XCTAssertTrue(waitUntil {
            after = (try? self.storedCollection(game: "riftbound")) ?? []
            return after.contains(added)
        }, "\(added) is not in the file")
        XCTAssertEqual(after.filter { $0 != added }, before, "collection differs by more than the added row")
        XCTAssertEqual(after.count, before.count + 1)
        try assertOtherListsEqual(initial)
        shot("real-sets-3-after-plus")
        app.toolbars.buttons["Back"].firstMatch.click()
        let openCount = element(app, "sets-count-\(open)")
        XCTAssertTrue(waitUntil { self.text(openCount) == "\(parts[0] + 1) / \(parts[1])" }, text(openCount))

        // 4. `−` on it again: the collection as before.
        app.buttons["sets-row-\(open)"].click()
        XCTAssertTrue(element(app, "set-screen").waitForExistence(timeout: 10), "the set's page did not open")
        try takeOff(app, suffix: suffix, name: name)
        XCTAssertTrue(waitUntil { app.windows.firstMatch.title.hasSuffix(" – \(parts[0]) of \(parts[1])") },
                      app.windows.firstMatch.title)
        app.toolbars.buttons["Back"].firstMatch.click()
        XCTAssertTrue(waitUntil { self.text(openCount) == openBefore }, text(openCount))
        quit(app)

        let final = try XCTUnwrap(storedUserFile(game: "riftbound"))
        XCTAssertEqual(final["collection"] as? NSArray, initial["collection"] as? NSArray, "collection changed")
        try assertOtherListsEqual(initial)
        times.append("riftbound.json: \(bytesBefore) bytes before, \(try Data(contentsOf: file).count) bytes after")
        let report = times.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "real-sets-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RealCollectionTests sets\n\(report)")
    }

    /// The identifiers of the Sets list's rows, top to bottom.
    private func setRows(_ app: XCUIApplication) -> [String] {
        identifiersInOrder(app, ElementMatch(.button, "identifier BEGINSWITH 'sets-row-'"))
    }

    /// The identifiers of a set page's cells in reading order (not their count controls).
    private func setCellIDs(_ app: XCUIApplication) -> [String] {
        identifiersInOrder(app, ElementMatch(.button, "identifier BEGINSWITH 'set-cell-' AND NOT identifier "
            + "BEGINSWITH 'set-cell-minus-' AND NOT identifier BEGINSWITH 'set-cell-plus-'"))
    }

    /// A segment of a segmented picker (`sets-scope`, `set-filter`).
    private func setsSegment(_ app: XCUIApplication, _ title: String, in picker: String) -> XCUIElement {
        let radio = app.radioButtons[title].firstMatch
        return radio.exists ? radio : element(app, picker).buttons[title].firstMatch
    }

    /// Every cell of the set page on screen, scrolled through from the top (a lazy grid makes a cell near the window only).
    private func collectSetCells(_ app: XCUIApplication) -> Set<String> {
        let page = element(app, "set-screen")
        var found = Set<String>()
        var still = 0
        for _ in 0..<300 where still < 3 {
            let seen = setCellIDs(app)
            let before = found.count
            found.formUnion(seen)
            still = found.count == before ? still + 1 : 0
            page.scroll(byDeltaX: 0, deltaY: -250)
        }
        return found
    }

    /// A set cell's control, scrolled whole into the window and at rest.
    private func revealSetControl(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier), page = element(app, "set-screen"), window = app.windows.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no \(identifier)")
        for _ in 0..<15 where !window.frame.insetBy(dx: 0, dy: 8).contains(target.frame) {
            page.scroll(byDeltaX: 0, deltaY: -60)
        }
        return settled(target)
    }

    /// On a set's page: Owned, `name` in the search field, `−` on the cell `suffix` until the file has no row of it.
    private func takeOff(_ app: XCUIApplication, suffix: String, name: String) throws {
        setsSegment(app, "Owned", in: "set-filter").click()
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        let minus = revealSetControl(app, "set-cell-minus-\(suffix)")
        XCTAssertEqual(text(element(app, "set-cell-value-\(suffix)")), "1")
        minus.click()
        let key = try printing(suffix)
        XCTAssertTrue(waitUntil {
            !((try? self.storedCollection(game: "riftbound")) ?? []).contains { $0.productID == key.productID && $0.finish == key.finish }
        }, "the added row is still in the file")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        setsAdded = nil
    }

    /// The teardown of the sets test: when the printing it added is still in the file (a failure between `+` and `−`),
    /// takes it off through the app (the sandboxed runner cannot write into the root), on the set's page.
    private func takeOffSetsAdded(root: URL) {
        guard let added = setsAdded, let key = try? printing(added.suffix),
              ((try? storedCollection(game: "riftbound")) ?? []).contains(where: {
                  $0.productID == key.productID && $0.finish == key.finish && $0.count == 1 && $0.name == added.name
              }) else { return }
        self.app?.terminate()
        let running = launch(storeRoot: root, game: "riftbound", extra: ["-screen", "sets"])
        XCTAssertTrue(waitUntil(timeout: 60) { running.buttons["sets-row-\(added.groupID)"].exists }, "no row of \(added.groupID)")
        running.buttons["sets-row-\(added.groupID)"].click()
        XCTAssertTrue(element(running, "set-screen").waitForExistence(timeout: 10), "the set's page did not open")
        try? takeOff(running, suffix: added.suffix, name: added.name)
        quit(running)
    }

    /// The other lists of the running root's Riftbound file equal those of `initial`.
    private func assertOtherListsEqual(_ initial: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try XCTUnwrap(storedUserFile(game: "riftbound"))
        for list in ["wanted", "forSale", "sold", "decks", "sharing"] {
            XCTAssertEqual(now[list] as? NSArray, initial[list] as? NSArray, "\(list) changed", file: file, line: line)
        }
    }

    /// The set index the app wrote (`{"version": 1, "sets": {"<groupID>": [productID, …]}}`).
    private func setIndex(_ url: URL) throws -> [Int: [Int]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.path)
        XCTAssertEqual(object["version"] as? Int, 1)
        let sets = try XCTUnwrap(object["sets"] as? [String: [Int]], url.path)
        return Dictionary(uniqueKeysWithValues: sets.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    /// The set's owned targets from the file's rows (F2: a printing key with a count of 1 or more, summed over rows of one
    /// key; F1 makes each a target) and its total on a root without prices (F1: one Normal target per product, then every
    /// owned finish that is not Normal). Nil for a set not in the index.
    private func setNumbers(groupID: Int, index: [Int: [Int]], rows: [StoredRow]) -> (owned: Int, total: Int, ownedKeys: [String])? {
        guard let products = index[groupID] else { return nil }
        let inSet = Set(products)
        var counts: [String: Int] = [:]
        for row in rows where inSet.contains(row.productID) { counts["\(row.productID)-\(row.finish)", default: 0] += row.count }
        let ownedKeys = counts.filter { $0.value >= 1 }.keys.sorted()
        let otherFinishes = ownedKeys.count { !$0.hasSuffix("-Normal") }
        return (ownedKeys.count, products.count + otherFinishes, ownedKeys)
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

    /// Deck ▸ Active on the deck page on screen; false when the item never showed. Another app that comes to the front
    /// (seen: the Claude desktop app's window, reported by XCUITest as an interrupting element) makes this app inactive,
    /// and an inactive app's open menu closes: the item is gone before the click. So the app is brought to the front
    /// before each try, and the menu is opened again (at most 3 tries) when its item does not show.
    private func chooseActive(_ app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            app.activate()
            guard app.wait(for: .runningForeground, timeout: 5) else { continue }
            element(app, "deck-menu").click()
            let item = app.menuItems["Active"].firstMatch
            if item.waitForExistence(timeout: 3), item.isHittable {
                item.click()
                return true
            }
            app.typeKey(.escape, modifierFlags: [])              // a menu left open, if any
        }
        return false
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
            XCTAssertTrue(chooseActive(app), "no Active item")
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
        var seen: [String: String] = [:]                        // identifier → label
        for _ in 0..<20 where seen.count < printings {
            // One snapshot per step: the lazy grid drops cells while it scrolls.
            let shown = elementsInOrder(app, .collectionCells)
            for cell in shown { seen[cell.identifier] = cell.label }
            if seen.count < printings, let last = lastInWindow(app, shown) {
                last.scroll(byDeltaX: 0, deltaY: -300)
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
        XCTAssertTrue(chooseActive(app), "no Active item")
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
            // One snapshot per step (identifiers, labels and frames together): the lazy grid drops cells while it scrolls.
            let shown = elementsInOrder(app, .collectionCells)
            for cell in shown {
                let label = cell.label
                guard let end = label.range(of: ", ×") else { continue }
                let name = Self.withoutBrackets(String(label[..<end.lowerBound]))
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            }
            // The gallery's scroll view is not found by its identifier on every run: a cell's scroll moves its gallery.
            if names.count < count, let last = lastInWindow(app, shown) {
                last.scroll(byDeltaX: 0, deltaY: -300)
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
