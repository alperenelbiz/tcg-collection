import XCTest

/// Phase 6A task 5: the Decks tab on the iPhone (A51): the deck list (the Mac sidebar's rows, missing counts, the
/// unreadable line, "New Deck…"), a deck page's "…" menu, the deck sheets (New Deck and Rename medium, Paste and Sharing
/// large). The fixture catalog's Riftbound cards: Kai'Sa, Rebel; Dockside Lock-Up; Calm Rune (a basic rune).
final class DecksPhoneTests: PhoneUITestCase {
    /// A deck name of 40 characters: its row must truncate inside the screen.
    private static let longName = "The Very Long Deck Name Of Forty Letters"

    /// Kai'Sa ×2 in an active deck, none owned: the deck misses 2. A second deck with a long name, not active; and one deck
    /// this build cannot read (no id).
    private static let missingFile = """
        {"version": 1, "collection": [],
         "decks": [{"id": "rb1", "name": "Wind", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2}]},
                   {"id": "rb2", "name": "\(longName)", "format": "standard", "active": false, "cards": []},
                   {"name": "no id"}]}
        """

    /// Two active decks use Kai'Sa ×2 each and 2 are owned, with no sharing answer: one pending card.
    private static let twoDecksOneKaisa = """
        {"version": 1,
         "collection": [{"productID": 721337, "finish": "Normal", "count": 2, "condition": "", "name": "Kai'Sa, Rebel"}],
         "decks": [{"id": "rb1", "name": "Wind", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2}]},
                   {"id": "rb2", "name": "Cheap", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2}]}]}
        """

    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    private func writeUserFile(_ json: String, game: String, root: URL) throws {
        let folder = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "\(game).json"))
    }

    private func storedUserFile(game: String) throws -> [String: Any]? {
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "\(game).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    }

    /// The file's decks as `<id>|<cardKey>|<section>|<count>` per card (a deck with no card: `<id>|`).
    private func storedDeckCards(game: String) -> [String] {
        guard let decks = (try? storedUserFile(game: game))?["decks"] as? [[String: Any]] else { return [] }
        return decks.flatMap { deck -> [String] in
            let id = deck["id"] as? String ?? "", cards = deck["cards"] as? [[String: Any]] ?? []
            if cards.isEmpty { return ["\(id)|"] }
            return cards.map { "\(id)|\($0["cardKey"] as? String ?? "")|\($0["section"] as? String ?? "")|\($0["count"] as? Int ?? -1)" }
        }
    }

    private var screen: CGRect { XCUIApplication(bundleIdentifier: Self.debugBundleID).windows.firstMatch.frame }

    /// `element` is hittable and wholly inside the screen.
    private func assertOnScreen(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, "\(element.identifier) is not hittable", file: file, line: line)
        XCTAssertTrue(screen.contains(element.frame), "\(element.identifier) \(element.frame) leaves \(screen)",
                      file: file, line: line)
    }

    /// Taps `identifier` once it exists, is enabled and hittable.
    private func tapWhenReady(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20,
                              file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, identifier).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "no \(identifier)", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: timeout) { target.isEnabled && target.isHittable }, "\(identifier) is off",
                      file: file, line: line)
        target.tap()
    }

    /// R3: the deck page's totals line says `expected`, inside the screen.
    private func assertDeckTotals(_ app: XCUIApplication, _ expected: String? = nil, prefix: String? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let totals = app.staticTexts["deck-totals"].firstMatch
        XCTAssertTrue(totals.waitForExistence(timeout: 20), "no deck-totals", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 20) {
            let shown = self.text(totals)
            return expected.map { shown == $0 } ?? prefix.map { shown.hasPrefix($0) } ?? false
        }, "deck-totals: \(text(totals))",
                      file: file, line: line)
        assertOnScreen(totals, file: file, line: line)
    }

    /// Decks → New Deck… (a medium sheet) → Create: the deck's page in the Decks tab. Its "…" menu → Add cards → `+` on
    /// Calm Rune → back: the page's totals say `1 card`; the file has the card.
    func testNewDeckAndAddCards() throws {
        let app = launch()
        XCTAssertTrue(tab(app, "Decks").waitForExistence(timeout: 20), "no Decks tab")
        tab(app, "Decks").tap()
        XCTAssertTrue(element(app, "decks-screen").waitForExistence(timeout: 10), "no deck list")
        tapWhenReady(app, "sidebar-new-deck")
        let sheet = element(app, "new-deck-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no New Deck sheet")
        XCTAssertEqual(element(app, "new-deck-name").value as? String, "Deck")
        // `.medium`: the sheet's content starts about halfway down the screen.
        XCTAssertGreaterThan(sheet.frame.minY, screen.height * 0.35, "the New Deck sheet is not medium: \(sheet.frame)")
        shot("decks-00-new-deck-sheet")
        tapWhenReady(app, "new-deck-create")
        XCTAssertTrue(waitUntil(timeout: 10) { !sheet.exists }, "the New Deck sheet stayed")

        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10), "no deck page")
        XCTAssertTrue(tab(app, "Decks").isSelected, "the deck page is not in the Decks tab")
        assertDeckTotals(app, "0 cards")
        tapWhenReady(app, "deck-more")
        for item in ["deck-paste", "deck-rename", "deck-active", "deck-move-up", "deck-move-down", "deck-delete"] {
            XCTAssertTrue(app.buttons[item].firstMatch.waitForExistence(timeout: 5)
                          || element(app, item).exists, "no \(item) in the … menu")
        }
        app.buttons["deck-add-cards"].firstMatch.tap()
        XCTAssertTrue(element(app, "deck-add-screen").waitForExistence(timeout: 10), "no deck search")
        let key = "calm rune"
        tapWhenReady(app, "deck-add-plus-\(key)", timeout: 30)
        XCTAssertTrue(waitUntil(timeout: 10) { self.text(self.element(app, "deck-add-value-\(key)")) == "1" })
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedDeckCards(game: "riftbound").first?.hasSuffix("|\(key)|runes|1") == true },
                      "\(storedDeckCards(game: "riftbound"))")
        app.navigationBars.buttons["Deck"].firstMatch.tap()
        XCTAssertTrue(element(app, "deck-cell-\(key)-runes").waitForExistence(timeout: 10), "no cell after back")
        assertDeckTotals(app, "1 card")
        shot("decks-01-page")
    }

    /// The deck list: the active deck missing 2 copies says `2`; the long name truncates inside the screen; the unreadable
    /// line; a row's tap opens its page.
    func testADeckListShowsMissing() throws {
        let app = launch(extra: ["-screen", "decks"],
                         prepare: { root in try self.writeUserFile(Self.missingFile, game: "riftbound", root: root) })
        XCTAssertTrue(element(app, "decks-screen").waitForExistence(timeout: 20), "no deck list")
        let missing = element(app, "sidebar-deck-missing-rb1")
        XCTAssertTrue(missing.waitForExistence(timeout: 30), "no missing count on Wind")
        XCTAssertEqual(text(missing), "2")
        XCTAssertFalse(element(app, "sidebar-deck-missing-rb2").exists, "a deck that is not active shows a count")
        let long = element(app, "sidebar-deck-rb2")
        XCTAssertTrue(long.exists, "no long deck row")
        assertOnScreen(long)
        let unreadable = element(app, "sidebar-decks-unreadable")
        XCTAssertTrue(unreadable.exists, "no unreadable line")
        XCTAssertEqual(text(unreadable), "1 deck cannot be read.")
        assertOnScreen(element(app, "sidebar-new-deck"))
        shot("decks-02-list")

        element(app, "sidebar-deck-rb1").tap()
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10), "no deck page")
        assertDeckTotals(app, prefix: "2 cards · 2 missing")
        tapWhenReady(app, "deck-list-back")
        XCTAssertTrue(element(app, "sidebar-deck-rb1").waitForExistence(timeout: 10), "no deck list after Decks")
    }

    /// D11 on the iPhone: `-pasteDeck <file>`: the paste sheet (large) → Read → Create deck: the deck's page in the Decks
    /// tab with its sections; the file has the deck.
    func testPasteADeckOnTheIPhone() throws {
        let file = Self.fixturesDirectory.appending(path: "deck-yugioh.txt").path
        let app = launch(game: "yu-gi-oh", extra: ["-screen", "collection", "-pasteDeck", file])
        let sheet = element(app, "paste-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "no paste sheet")
        XCTAssertLessThan(sheet.frame.minY, screen.height * 0.2, "the paste sheet is not large: \(sheet.frame)")
        tapWhenReady(app, "paste-read", timeout: 30)
        XCTAssertTrue(element(app, "paste-summary").waitForExistence(timeout: 10), "no table")
        XCTAssertEqual(text(element(app, "paste-summary")), "6 cards on 3 lines")
        shot("decks-03-paste")
        tapWhenReady(app, "paste-apply")
        XCTAssertTrue(waitUntil(timeout: 10) { !sheet.exists }, "the paste sheet stayed")
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10), "no deck page")
        XCTAssertTrue(waitUntil(timeout: 10) { self.tab(app, "Decks").isSelected }, "the new deck is not in the Decks tab")
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(self.element(app, "deck-section-main")) == "Main Deck · 3" })
        assertDeckTotals(app, prefix: "6 cards · 6 missing")
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedDeckCards(game: "yu-gi-oh").count == 3 },
                      "\(storedDeckCards(game: "yu-gi-oh"))")
        shot("decks-04-pasted-deck")
    }

    /// E7 on the iPhone: Wanted's "…" menu → Decisions (1)… → the sharing sheet (large) → Share all → Done: the file's
    /// `sharing` says the card is shared, and the card leaves Wanted.
    func testTheSharingSheetOnTheIPhone() throws {
        let app = launch(extra: ["-screen", "wanted"],
                         prepare: { root in try self.writeUserFile(Self.twoDecksOneKaisa, game: "riftbound", root: root) })
        let key = "kai sa rebel"
        XCTAssertTrue(app.buttons["wanted-cell-\(key)"].firstMatch.waitForExistence(timeout: 30), "no pending card")
        tapWhenReady(app, "wanted-more")
        let decisions = app.buttons["wanted-decisions"].firstMatch
        XCTAssertTrue(decisions.waitForExistence(timeout: 10), "no Decisions… in the menu")
        decisions.tap()
        let sheet = element(app, "sharing-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no sharing sheet")
        XCTAssertLessThan(sheet.frame.minY, screen.height * 0.2, "the sharing sheet is not large: \(sheet.frame)")
        XCTAssertTrue(element(app, "sharing-row-\(key)").exists, "no row")
        assertOnScreen(element(app, "sharing-choice-\(key)"))
        tapWhenReady(app, "sharing-share-all")
        shot("decks-05-sharing")
        tapWhenReady(app, "sharing-done")
        XCTAssertTrue(waitUntil(timeout: 10) { !sheet.exists }, "the sharing sheet stayed")
        XCTAssertTrue(waitUntil(timeout: 10) {
            ((try? self.storedUserFile(game: "riftbound"))?["sharing"] as? [[String: Any]])?
                .contains { $0["cardKey"] as? String == key && $0["shared"] as? Bool == true } == true
        }, "\(String(describing: try? storedUserFile(game: "riftbound")))")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["wanted-cell-\(key)"].firstMatch.exists },
                      "the shared card stayed on Wanted")
    }
}
