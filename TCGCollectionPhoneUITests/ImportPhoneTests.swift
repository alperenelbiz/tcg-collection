import XCTest

/// Phase 6A task 8: the CSV import sheet on the iPhone (A51). The sheet opens with `-importCSV <file>` (the Mac's way past
/// the system panel; the iPhone's panel is Files, which the UI tests do not drive). The fixture `collection-riftbound.csv`
/// against two rows (Dockside Lock-Up Foil ×1, "Only Here" 555 ×2): New 2, Count changes 1, In your collection, not in
/// this file 1, as the Mac's `CollectionFlowTests.testImportShowsTheComparisonAndAppliesIt`.
final class ImportPhoneTests: PhoneUITestCase {
    /// The two rows of the Mac test: Dockside Lock-Up Foil ×1, and "Only Here" (product 555, not in the catalog) ×2.
    private func writeRows(_ root: URL) throws {
        let folder = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
            {"version": 1,
             "collection": [{"productID": 721334, "finish": "Foil", "count": 1, "condition": "", "name": "Dockside Lock-Up"},
                            {"productID": 555, "finish": "Normal", "count": 2, "condition": "Mint", "name": "Only Here"}]}
            """
        try Data(json.utf8).write(to: folder.appending(path: "riftbound.json"))
    }

    /// The sheet fills the screen; every row's name, finish, number and Remove switch are whole on screen, the number on a
    /// line of its own under the name (the iPhone's stacked rows, under 640 pt), the numbers in one right-aligned column.
    /// Import writes, and the Collection tab's totals say the imported collection.
    func testImportACSVOnTheIPhone() throws {
        let path = Self.fixturesDirectory.appending(path: "collection-riftbound.csv").path
        let app = launch(extra: ["-importCSV", path], prepare: { try self.writeRows($0) })
        let sheet = element(app, "import-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no import sheet")
        let missing = element(app, "import-missing-riftbound")
        XCTAssertTrue(missing.waitForExistence(timeout: 40), "no comparison")
        XCTAssertEqual(text(element(app, "import-summary")), "2 new, 1 changed, 1 not in the file (kept)")
        XCTAssertEqual(text(element(app, "import-count-722282-Normal")), "+4")
        XCTAssertEqual(text(element(app, "import-count-721337-Normal")), "+3")
        XCTAssertEqual(text(element(app, "import-count-721334-Foil")), "1 → 3")
        XCTAssertEqual(text(element(app, "import-count-555-Normal")), "×2")

        let screen = app.windows.firstMatch.frame
        // `.large`: the sheet reaches the screen's lower half and is as wide as the screen.
        XCTAssertGreaterThan(sheet.frame.height, screen.height * 0.8, "the sheet is not large: \(sheet.frame)")
        let rows = ["722282-Normal": "Calm Rune (R02a)", "721337-Normal": "Kai'Sa, Rebel",
                    "721334-Foil": "Dockside Lock-Up", "555-Normal": "Only Here"]
        var counts: [CGFloat] = []
        for (id, name) in rows {
            let row = element(app, "import-row-\(id)")
            let nameText = row.staticTexts[name].firstMatch
            let count = element(app, "import-count-\(id)")
            XCTAssertTrue(nameText.exists, "no name \(name) in row \(id)")
            XCTAssertTrue(screen.contains(nameText.frame), "\(name) \(nameText.frame) is not inside \(screen)")
            XCTAssertTrue(screen.contains(count.frame), "count \(id) \(count.frame) is not inside \(screen)")
            // The name has the line's width, not what four columns leave of 402 pt: these short names take one line.
            XCTAssertLessThan(nameText.frame.height, 25, "\(name) is squeezed onto two lines: \(nameText.frame)")
            // Stacked: the number stands under the name.
            XCTAssertGreaterThanOrEqual(count.frame.minY, nameText.frame.maxY - 1,
                                        "count \(id) \(count.frame) is not under its name \(nameText.frame)")
            counts.append(count.frame.maxX)
        }
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1, "the counts are not right-aligned: \(counts)")
        let remove = element(app, "import-remove-555-Normal")
        XCTAssertTrue(remove.isHittable, "Remove is not hittable")
        XCTAssertTrue(screen.contains(remove.frame), "Remove \(remove.frame) is not inside \(screen)")
        // The system's switch (28 pt tall in iOS 27), with its "Remove" title: not one of the app's 44 pt controls.
        XCTAssertGreaterThanOrEqual(remove.frame.height, 24, "Remove is too small to tap: \(remove.frame)")
        shot("import-01")

        element(app, "import-skipped").tap()
        XCTAssertTrue(element(app, "import-skipped-line-5").waitForExistence(timeout: 5), "Not imported did not open")
        XCTAssertTrue(screen.contains(element(app, "import-skipped-line-6").frame), "line 6 is not inside the screen")
        shot("import-02-not-imported")

        let apply = element(app, "import-apply")
        XCTAssertTrue(apply.isHittable, "Import is not hittable")
        apply.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !sheet.exists }, "the sheet stayed open")
        let totals = app.staticTexts["collection-totals"].firstMatch
        XCTAssertTrue(totals.waitForExistence(timeout: 20), "no collection-totals")
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(totals) == "12 copies · 4 printings" }, text(totals))
        shot("import-03-collection")
    }
}
