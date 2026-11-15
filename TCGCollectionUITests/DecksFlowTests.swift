import XCTest

/// The click paths of the Decks sidebar section and the deck page (phase 3A task 5), on the fixture catalog. The fixture
/// has no Riftbound Legend and no Commander-legal pair of a legendary creature: the decks are written with the card keys
/// it has (Riftbound: Kai'Sa, Rebel (Champion Unit), Dockside Lock-Up (Gear), Calm Rune (a basic rune); Cyberpunk: Kerry
/// Eurodyne, Satori; Yu-Gi-Oh!: Swiftwind Panther Warrior; Magic: Ajani Resolute, Bloodline Recollector).
final class DecksFlowTests: UITestCase {
    /// A deck as `GameUserFile` keeps it.
    private struct StoredDeck: Equatable {
        var id: String
        var name: String
        var format: String
        var active: Bool
        var cards: [String]      // "<cardKey>|<section>|<count>"
    }

    private func storedDecks(game: String) throws -> [StoredDeck] {
        guard let object = try storedUserFile(game: game) else { return [] }
        let decks = try XCTUnwrap(object["decks"] as? [[String: Any]], "no decks array")
        // A deck this build cannot read (no id, no cards array) is kept in the file as written: not one of ours.
        return decks.compactMap { deck in
            guard let id = deck["id"] as? String, let cards = deck["cards"] as? [[String: Any]] else { return nil }
            return StoredDeck(id: id, name: deck["name"] as? String ?? "", format: deck["format"] as? String ?? "",
                              active: deck["active"] as? Bool ?? false, cards: cards.map { card in
                                  "\(card["cardKey"] as? String ?? "")|\(card["section"] as? String ?? "")|\(card["count"] as? Int ?? -1)"
                              })
        }
    }

    /// The element `identifier` of the deck page, scrolled into the window: a group's cells are in a lazy grid, made only
    /// near the window (450 pt high in the tests), and XCUITest does not scroll to a click.
    private func reveal(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath,
                        line: UInt = #line) -> XCUIElement {
        // The page's container: XCUITest does not find the scroll view by its own identifier (`deck-gallery`).
        let target = element(app, identifier), gallery = element(app, "deck-screen")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "no deck page", file: file, line: line)
        for _ in 0..<15 {
            if target.exists, target.isHittable { return target }
            gallery.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(target.exists && target.isHittable, "\(identifier) is not in the window", file: file, line: line)
        return target
    }

    /// The sidebar's deck rows, not their counts (`sidebar-deck-missing-…`) and not `sidebar-decks-unreadable`.
    private func deckRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'sidebar-deck-' AND NOT (identifier BEGINSWITH 'sidebar-deck-missing-')"))
    }

    private func sectionTitles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-section-'"))
    }

    private var title: String { XCUIApplication(bundleIdentifier: Self.debugBundleID).windows.firstMatch.title }

    /// The Riftbound deck of the section test: Kai'Sa ×2 (1 owned), Dockside Lock-Up ×2 (3 owned), Calm Rune ×12 (none
    /// owned, basic), all in the format's default sections; plus one deck this build cannot read.
    private static let riftboundDeck = """
        {"version": 1,
         "collection": [{"productID": 721337, "finish": "Normal", "count": 1, "condition": "", "name": "Kai'Sa, Rebel"},
                        {"productID": 721334, "finish": "Normal", "count": 3, "condition": "", "name": "Dockside Lock-Up"}],
         "decks": [{"id": "rb1", "name": "Kai'Sa", "format": "standard", "active": false,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2},
                              {"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 2},
                              {"cardKey": "calm rune", "name": "Calm Rune", "section": "runes", "count": 12}]},
                   {"id": "rb9", "name": "Second", "format": "standard", "active": false, "cards": []},
                   {"name": "no id"}]}
        """

    /// "New Deck…" → the sheet (the name pre-filled, no format picker for a game of one format) → Create: the deck's page
    /// with its empty message and no warning; the sidebar row has no count (A14); the file has one deck, not active, no
    /// cards.
    func testNewDeckIsNotActiveAndOpensEmpty() throws {
        let app = launch(game: "riftbound", extra: ["-screen", "collection"])
        let newDeck = element(app, "sidebar-new-deck")
        XCTAssertTrue(newDeck.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { newDeck.isEnabled }, "New Deck… stays off")
        shot("decks-01-sidebar-without-decks")
        newDeck.click()
        let sheet = element(app, "new-deck-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "new-deck-name").value as? String, "Deck")
        XCTAssertFalse(element(app, "new-deck-format").exists, "a format picker for a game of one format")
        shot("decks-02-new-deck-sheet", of: sheet)
        element(app, "new-deck-create").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")

        let screen = element(app, "deck-screen")
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(screen.descendants(matching: .staticText).matching(NSPredicate(format: "value == %@ OR label == %@",
            "This deck has no cards yet.", "This deck has no cards yet.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-warning-'")).count, 0)
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Deck") }, title)
        let rows = deckRows(app)
        XCTAssertTrue(waitUntil { rows.count == 1 }, "\(identifiers(rows))")
        let id = String(rows.firstMatch.identifier.dropFirst("sidebar-deck-".count))
        XCTAssertFalse(element(app, "sidebar-deck-missing-\(id)").exists, "a new deck shows a count")
        assertAccentFill(app, row: "sidebar-deck-\(id)")
        shot("decks-03-new-deck-page")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))
                == [StoredDeck(id: id, name: "Deck", format: "standard", active: false, cards: [])] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
    }

    /// A Riftbound deck written into the file: the sections in the format's order, the group headings, `×2 · 1 missing` on
    /// Kai'Sa (1 owned), `×2` on Dockside Lock-Up (3 owned), `×12` and never "missing" on the basic rune; the subtitle's
    /// totals; the bounds the deck does not meet, as warnings. The fixture has no Legend: the Legend section is empty.
    func testADeckShowsItsSectionsGroupsAndMissing() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb1"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.riftboundDeck)
        }
        let kaisa = element(app, "deck-cell-kai sa rebel-main")
        XCTAssertTrue(kaisa.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { kaisa.label.hasPrefix("Kai'Sa, Rebel, ×2 · 1 missing, ") }, kaisa.label)
        XCTAssertEqual(identifiersInOrder(sectionTitles(app)),
                       ["deck-section-legend", "deck-section-champion", "deck-section-main", "deck-section-runes",
                        "deck-section-battlefields", "deck-section-sideboard"])
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 4")
        XCTAssertEqual(text(element(app, "deck-section-legend")), "Legend · 0")
        XCTAssertEqual(text(element(app, "deck-warning-legend")), "needs 1 card")
        XCTAssertEqual(text(element(app, "deck-warning-main")), "Main Deck with its Champion: needs at least 40 cards")
        XCTAssertFalse(element(app, "deck-warning-runes").exists, "12 runes meet the bound")
        for heading in ["Units", "Gear", "Runes"] {
            XCTAssertTrue(element(app, "deck-screen").staticTexts[heading].exists, "no group heading \(heading)")
        }
        XCTAssertTrue(waitUntil { self.title.contains("16 cards · 1 missing") }, title)
        XCTAssertEqual(text(element(app, "sidebar-decks-unreadable")), "1 deck cannot be read.")
        XCTAssertFalse(element(app, "sidebar-deck-missing-rb1").exists, "a deck that is not active shows a count")
        // The status area has its own room: the sidebar's last row is above it, with two decks in the 450 pt window.
        let allCards = element(app, "sidebar-all-cards"), status = app.staticTexts["status-line"]
        XCTAssertTrue(allCards.frame.maxY <= status.frame.minY || !allCards.isHittable,
                      "the status line is over All cards: \(allCards.frame) \(status.frame)")
        shot("decks-04-riftbound-deck-top")
        let dockside = reveal(app, "deck-cell-dockside lock up-main")
        XCTAssertTrue(dockside.label.hasPrefix("Dockside Lock-Up, ×2, $5.12"), dockside.label)
        let rune = reveal(app, "deck-cell-calm rune-runes")
        XCTAssertTrue(rune.label.hasPrefix("Calm Rune, ×12, "), rune.label)      // basic: never missing
        shot("decks-05-riftbound-deck-runes")
    }

    /// "Deck" ▸ "Active": the sidebar row gets the missing count; off again, it goes; the file's `active` follows.
    func testActiveShowsTheMissingCountInTheSidebar() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb1"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.riftboundDeck)
        }
        XCTAssertTrue(element(app, "deck-cell-kai sa rebel-main").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let count = element(app, "sidebar-deck-missing-rb1")
        XCTAssertFalse(count.exists)
        element(app, "deck-menu").click()
        let active = app.menuItems["Active"].firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Rename…"].firstMatch.exists && app.menuItems["Delete Deck…"].firstMatch.exists)
        XCTAssertFalse(app.menuItems["Format"].firstMatch.exists, "a format menu for a game of one format")
        shot("decks-06-deck-menu")
        active.click()
        XCTAssertTrue(count.waitForExistence(timeout: 10), "no count after Active")
        XCTAssertEqual(text(count), "1")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.active == true })
        shot("decks-07-active-deck-count")
        element(app, "deck-menu").click()
        app.menuItems["Active"].firstMatch.click()
        XCTAssertTrue(waitUntil { !count.exists }, "the count stayed after Active off")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.active == false })
    }

    /// `+` on a cell; `−` to 0 removes the cell; the context menu's "Move to ▸ Side Deck" moves a card; the file agrees.
    func testCountAndMoveOnTheCell() throws {
        let app = try launch(game: "cyberpunk", extra: ["-screen", "deck:cp1"]) { _ in
            try self.writeUserFile(game: "cyberpunk", json: """
            {"version": 1,
             "decks": [{"id": "cp1", "name": "Rockers", "format": "standard", "active": false,
                        "cards": [{"cardKey": "kerry eurodyne the last rockerboy", "name": "Kerry Eurodyne", "section": "main", "count": 1},
                                  {"cardKey": "satori sword of saburo", "name": "Satori", "section": "main", "count": 1}]}]}
            """)
        }
        let kerry = "kerry eurodyne the last rockerboy"
        XCTAssertTrue(element(app, "deck-cell-\(kerry)-main").waitForExistence(timeout: 20))
        element(app, "deck-cell-plus-\(kerry)-main").click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-cell-value-\(kerry)-main")) == "2" })
        element(app, "deck-cell-minus-satori sword of saburo-main").click()
        XCTAssertTrue(waitUntil { !self.element(app, "deck-cell-satori sword of saburo-main").exists }, "− to 0 left the cell")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "cyberpunk"))?.first?.cards == ["\(kerry)|main|2"] },
                      "\(String(describing: try? storedDecks(game: "cyberpunk")))")
        shot("decks-08-count-changed")

        element(app, "deck-cell-\(kerry)-main").rightClick()
        let moveTo = app.menuItems["Move to"].firstMatch
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5))
        moveTo.hover()
        let side = app.menuItems["Side Deck"].firstMatch
        XCTAssertTrue(side.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Legends"].firstMatch.exists)
        shot("decks-09-move-to-menu")
        side.click()
        XCTAssertTrue(element(app, "deck-cell-\(kerry)-side").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "deck-cell-\(kerry)-main").exists)
        XCTAssertEqual(text(element(app, "deck-section-side")), "Side Deck · 2")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "cyberpunk"))?.first?.cards == ["\(kerry)|side|2"] },
                      "\(String(describing: try? storedDecks(game: "cyberpunk")))")
        shot("decks-10-moved-to-side-deck")
    }

    /// Rule checks warn, never block (spec 5.3): a Yu-Gi-Oh! deck with 4 copies of one card (3 in the Main Deck, 1 in the
    /// Side Deck) shows the Main Deck's size and the copy limit, and `+` still adds a copy.
    func testAWarningDoesNotBlock() throws {
        let app = try launch(game: "yu-gi-oh", extra: ["-screen", "deck:yg1"]) { _ in
            try self.writeUserFile(game: "yu-gi-oh", json: """
            {"version": 1,
             "decks": [{"id": "yg1", "name": "Wind", "format": "standard", "active": true,
                        "cards": [{"cardKey": "swiftwind panther warrior", "name": "Swiftwind Panther Warrior", "section": "main", "count": 3},
                                  {"cardKey": "swiftwind panther warrior", "name": "Swiftwind Panther Warrior", "section": "side", "count": 1}]}]}
            """)
        }
        let warning = element(app, "deck-warning-main")
        XCTAssertTrue(warning.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.text(warning) == "needs 40–60 cards · more than 3 copies: Swiftwind Panther Warrior" }, text(warning))
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 3")
        shot("decks-11-warnings")
        let plus = reveal(app, "deck-cell-plus-swiftwind panther warrior-main")
        XCTAssertTrue(plus.isEnabled)
        let value = element(app, "deck-cell-value-swiftwind panther warrior-main")
        let clicked = Date()
        plus.click()
        XCTAssertTrue(waitUntil { self.text(value) == "4" })
        // Each deck click joins the page and the sidebar again: the time from the click to the new count, for the report.
        print("deck plus click to count: \(Int(Date().timeIntervalSince(clicked) * 1000)) ms")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "yu-gi-oh"))?.first?.cards
                == ["swiftwind panther warrior|main|4", "swiftwind panther warrior|side|1"] },
                      "\(String(describing: try? storedDecks(game: "yu-gi-oh")))")
        // Owned 0, active: the sidebar says 5 missing.
        XCTAssertTrue(waitUntil { self.text(self.element(app, "sidebar-deck-missing-yg1")) == "5" })
    }

    /// Rename… saves a new name (an empty one is not saved); for Magic, Format ▸ Constructed moves the Commander section's
    /// card to the Deck and loses none (D12); Delete Deck… asks once, then the deck is gone and the Collection shows.
    func testRenameFormatAndDelete() throws {
        let app = try launch(game: "magic-the-gathering", extra: ["-screen", "deck:mg1"]) { _ in
            try self.writeUserFile(game: "magic-the-gathering", json: """
            {"version": 1,
             "decks": [{"id": "mg1", "name": "Ajani", "format": "commander", "active": false,
                        "cards": [{"cardKey": "ajani resolute", "name": "Ajani Resolute", "section": "commander", "count": 1},
                                  {"cardKey": "bloodline recollector", "name": "Bloodline Recollector", "section": "deck", "count": 1}]}]}
            """)
        }
        XCTAssertTrue(element(app, "deck-cell-ajani resolute-commander").waitForExistence(timeout: 20))
        XCTAssertEqual(text(element(app, "deck-warning-deck")), "Commander deck: needs 100 cards")

        element(app, "deck-menu").click()
        app.menuItems["Rename…"].firstMatch.click()
        let field = element(app, "deck-rename-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(element(app, "deck-rename-save").isEnabled, "an empty name can be saved")
        field.typeText("Lifegain")
        shot("decks-12-rename-sheet", of: element(app, "deck-rename-sheet"))
        element(app, "deck-rename-save").click()
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Lifegain") }, title)
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "magic-the-gathering"))?.first?.name == "Lifegain" })

        element(app, "deck-menu").click()
        let format = app.menuItems["Format"].firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 5))
        format.hover()
        let constructed = app.menuItems["Constructed"].firstMatch
        XCTAssertTrue(constructed.waitForExistence(timeout: 5))
        shot("decks-13-format-menu")
        constructed.click()
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "magic-the-gathering"))
                == [StoredDeck(id: "mg1", name: "Lifegain", format: "constructed", active: false,
                               cards: ["ajani resolute|deck|1", "bloodline recollector|deck|1"])] },
                      "\(String(describing: try? storedDecks(game: "magic-the-gathering")))")
        XCTAssertTrue(waitUntil { self.identifiersInOrder(self.sectionTitles(app)) == ["deck-section-deck", "deck-section-sideboard"] },
                      "\(identifiersInOrder(sectionTitles(app)))")
        XCTAssertEqual(text(element(app, "deck-section-deck")), "Deck · 2")
        XCTAssertTrue(element(app, "deck-cell-bloodline recollector-deck").waitForExistence(timeout: 10))
        _ = reveal(app, "deck-cell-ajani resolute-deck")
        shot("decks-14-constructed")

        element(app, "deck-menu").click()
        app.menuItems["Delete Deck…"].firstMatch.click()
        let delete = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.sheets.firstMatch.debugDescription)
        XCTAssertTrue(app.sheets.buttons["Cancel"].firstMatch.exists)
        XCTAssertTrue(app.sheets.staticTexts["Delete Lifegain?"].firstMatch.exists, app.sheets.firstMatch.debugDescription)
        XCTAssertTrue(app.sheets.staticTexts["Its cards stay in your collection."].firstMatch.exists)
        shot("decks-15-delete-dialog")
        delete.click()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "sidebar-deck-mg1").exists)
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "magic-the-gathering")) == [] })
        assertAccentFill(app, row: "sidebar-collection")
        shot("decks-16-after-delete")
    }

    /// Review Focus 4: with the page open, another device removes the deck: the page says so and offers the Collection.
    func testADeckRemovedElsewhereSaysSo() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb1"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.riftboundDeck)
        }
        XCTAssertTrue(element(app, "deck-cell-kai sa rebel-main").waitForExistence(timeout: 20))
        try changeUserFile(game: "riftbound", json: #"{"version": 1, "decks": []}"#)
        let gone = element(app, "deck-gone")
        XCTAssertTrue(gone.waitForExistence(timeout: 10), "the page of a removed deck does not say so")
        XCTAssertFalse(element(app, "sidebar-deck-rb1").exists)
        shot("decks-17-deck-removed-elsewhere")
        element(app, "deck-open-collection").click()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
    }

    /// Review Focus 2, D13: a deck card whose key the settled catalog does not have keeps its saved name, has no "missing"
    /// and no price, and `−` removes it.
    func testACardThatLeftTheCatalogStaysInTheDeck() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb2"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1,
             "decks": [{"id": "rb2", "name": "Old", "format": "standard", "active": true,
                        "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 1},
                                  {"cardKey": "vanished card", "name": "Vanished Card", "section": "main", "count": 1}]}]}
            """)
        }
        XCTAssertTrue(element(app, "deck-cell-kai sa rebel-main").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let gone = reveal(app, "deck-cell-vanished card-main")
        XCTAssertTrue(waitUntil { gone.label == "Vanished Card, ×1, no price" }, gone.label)
        XCTAssertFalse(element(app, "deck-catalog-note").exists, "a settled catalog still says it downloads")
        XCTAssertTrue(waitUntil { self.text(self.element(app, "sidebar-deck-missing-rb2")) == "1" })   // Kai'Sa only
        shot("decks-18-card-not-in-the-catalog")
        reveal(app, "deck-cell-minus-vanished card-main").click()
        XCTAssertTrue(waitUntil { !gone.exists }, "− left the card")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards == ["kai sa rebel|main|1"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
    }

    // MARK: Adding cards (phase 3A task 6)

    /// Opens the deck's search with "Add cards" (the toolbar's, or the empty deck's) and searches `text`: the cell of
    /// `cardKey` with its count control.
    private func openSearch(_ app: XCUIApplication, button: String, text: String, cardKey: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let add = element(app, button)
        XCTAssertTrue(add.waitForExistence(timeout: 20), "no \(button)", file: file, line: line)
        XCTAssertTrue(waitUntil { add.isEnabled }, "\(button) stays off", file: file, line: line)
        add.click()
        XCTAssertTrue(element(app, "deck-add-screen").waitForExistence(timeout: 10), "no search", file: file, line: line)
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.click()
        field.typeText(text)
        XCTAssertTrue(element(app, "deck-add-plus-\(cardKey)").waitForExistence(timeout: 10), "no cell \(cardKey)",
                      file: file, line: line)
    }

    /// The element `identifier` of a card page, scrolled into the window (the "Decks" block is below the 450 pt window).
    private func revealOnCardPage(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath,
                                  line: UInt = #line) -> XCUIElement {
        let target = element(app, identifier), page = element(app, "card-page")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "no card page", file: file, line: line)
        for _ in 0..<15 {
            if target.exists, target.isHittable { return target }
            page.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(target.exists && target.isHittable, "\(identifier) is not in the window", file: file, line: line)
        return target
    }

    /// D10: the empty deck's "Add cards" → the deck's search ("Add to Rockers") → a card → `+` twice, `−` once, `+` once:
    /// the deck's count of the card follows; Back: the cell is in its default section with `×2`; the file agrees and saves
    /// the card's name.
    func testAddCardsFromTheDecksSearch() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb5"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1, "decks": [{"id": "rb5", "name": "Rockers", "format": "standard", "active": false, "cards": []}]}
            """)
        }
        XCTAssertTrue(element(app, "deck-add-cards").waitForExistence(timeout: 20), "no Add cards in the toolbar")
        shot("decks-19-empty-deck-add-cards")
        let key = "dockside lock up"
        openSearch(app, button: "deck-empty-add-cards", text: "dockside", cardKey: key)
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Add to Rockers") }, title)
        let value = element(app, "deck-add-value-\(key)")
        XCTAssertEqual(text(value), "0")
        XCTAssertFalse(element(app, "deck-add-minus-\(key)").isEnabled, "− is on at 0")
        element(app, "deck-add-plus-\(key)").click()
        element(app, "deck-add-plus-\(key)").click()
        XCTAssertTrue(waitUntil { self.text(value) == "2" }, text(value))
        element(app, "deck-add-minus-\(key)").click()
        XCTAssertTrue(waitUntil { self.text(value) == "1" }, text(value))
        element(app, "deck-add-plus-\(key)").click()
        XCTAssertTrue(waitUntil { self.text(value) == "2" }, text(value))
        shot("decks-20-deck-search")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards == ["\(key)|main|2"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
        let stored = try XCTUnwrap(((try storedUserFile(game: "riftbound"))?["decks"] as? [[String: Any]])?.first?["cards"]
            as? [[String: Any]])
        XCTAssertEqual(stored.first?["name"] as? String, "Dockside Lock-Up")

        app.toolbars.buttons["Back"].click()
        let cell = element(app, "deck-cell-\(key)-main")
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no deck cell after Back")
        XCTAssertTrue(waitUntil { cell.label.hasPrefix("Dockside Lock-Up, ×2") }, cell.label)
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 2")
        shot("decks-21-deck-after-search")
    }

    /// D4, A15: Stardust Dragon (YGOPRODeck `synchro`, TCGplayer "Synchro Monster") added from the deck's search lands in
    /// the Extra Deck, not the Main Deck.
    func testAnExtraDeckCardGoesToTheExtraDeck() throws {
        let app = try launch(game: "yu-gi-oh", extra: ["-screen", "deck:yg2"]) { _ in
            try self.writeUserFile(game: "yu-gi-oh", json: """
            {"version": 1, "decks": [{"id": "yg2", "name": "Synchro", "format": "standard", "active": false,
                                      "cards": [{"cardKey": "swiftwind panther warrior", "name": "Swiftwind Panther Warrior", "section": "main", "count": 1}]}]}
            """)
        }
        XCTAssertTrue(element(app, "deck-cell-swiftwind panther warrior-main").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))                       // the Yu-Gi-Oh! index is read
        let key = "stardust dragon"
        openSearch(app, button: "deck-add-cards", text: "stardust", cardKey: key)
        element(app, "deck-add-plus-\(key)").click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-add-value-\(key)")) == "1" })
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "yu-gi-oh"))?.first?.cards
                == ["swiftwind panther warrior|main|1", "\(key)|extra|1"] },
                      "\(String(describing: try? storedDecks(game: "yu-gi-oh")))")
        app.toolbars.buttons["Back"].click()
        let cell = reveal(app, "deck-cell-\(key)-extra")
        XCTAssertTrue(cell.label.hasPrefix("Stardust Dragon, ×1"), cell.label)
        XCTAssertEqual(text(element(app, "deck-section-extra")), "Extra Deck · 1")
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 1")
        shot("decks-22-extra-deck")
    }
    /// Fix round 1: "New Deck…" from a card page, Cancel, then the sidebar's "New Deck…" → Create: the new deck is empty
    /// (the cancelled sheet's card is not added to it), the page of a game without decks shows the "Decks" heading.
    func testACancelledCardPageNewDeckLeavesNoCardForTheSidebarsNewDeck() throws {
        let app = launch(game: "riftbound")
        let cell = element(app, "card-cell-dockside lock up")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.click()
        revealOnCardPage(app, "card-add-to-deck").click()
        XCTAssertTrue(element(app, "card-page").staticTexts["Decks"].exists, "no Decks heading in a game without decks")
        let newDeck = app.menuItems["New Deck…"].firstMatch
        XCTAssertTrue(newDeck.waitForExistence(timeout: 5))
        newDeck.click()
        let sheet = element(app, "new-deck-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        element(app, "new-deck-cancel").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")

        let sidebarNewDeck = element(app, "sidebar-new-deck")
        XCTAssertTrue(waitUntil { sidebarNewDeck.isEnabled })
        sidebarNewDeck.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "new-deck-paste").exists, "the sidebar's sheet lacks Paste a deck…: it took the card")
        element(app, "new-deck-create").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10), "Create did not open the new deck")
        var decks: [StoredDeck] = []
        XCTAssertTrue(waitUntil { decks = (try? self.storedDecks(game: "riftbound")) ?? []; return decks.count == 1 },
                      "\(decks)")
        XCTAssertEqual(decks.first?.cards, [], "the new deck holds the cancelled card")
        shot("decks-25-sidebar-new-deck-after-a-cancel")
    }


    /// D10: All cards → a card → "Add to deck" ▸ a deck: the page's "Decks" line with 1; its `+`; "New Deck…" → Create: a
    /// line of the new deck, and the card page stays; the deck page shows the cell.
    func testAddToDeckFromACardPage() throws {
        let app = try launch(game: "riftbound") { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1, "decks": [{"id": "rb6", "name": "Gear", "format": "standard", "active": false,
                                      "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 1}]}]}
            """)
        }
        let key = "dockside lock up"
        let cell = element(app, "card-cell-\(key)")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.click()
        let menu = revealOnCardPage(app, "card-add-to-deck")
        XCTAssertFalse(element(app, "deck-line-rb6-main").exists, "a line for a deck without the card")
        menu.click()
        let gear = app.menuItems["Gear"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["New Deck…"].firstMatch.exists)
        shot("decks-23-add-to-deck-menu")
        gear.click()
        let value = element(app, "deck-line-value-rb6-main")
        XCTAssertTrue(value.waitForExistence(timeout: 10), "no deck line after Add to deck")
        XCTAssertEqual(text(value), "1")
        revealOnCardPage(app, "deck-line-plus-rb6-main").click()
        XCTAssertTrue(waitUntil { self.text(value) == "2" }, text(value))
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards
                == ["kai sa rebel|main|1", "\(key)|main|2"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")

        revealOnCardPage(app, "card-add-to-deck").click()
        app.menuItems["New Deck…"].firstMatch.click()
        let sheet = element(app, "new-deck-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        element(app, "new-deck-create").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertTrue(element(app, "card-page").exists, "Create left the card page")
        var decks: [StoredDeck] = []
        XCTAssertTrue(waitUntil { decks = (try? self.storedDecks(game: "riftbound")) ?? []; return decks.count == 2 })
        let newID = try XCTUnwrap(decks.last?.id)
        XCTAssertEqual(decks.last, StoredDeck(id: newID, name: "Deck", format: "standard", active: false, cards: ["\(key)|main|1"]))
        let newLine = revealOnCardPage(app, "deck-line-value-\(newID)-main")
        XCTAssertEqual(text(newLine), "1")
        shot("decks-24-card-page-deck-lines")

        element(app, "sidebar-deck-rb6").click()
        let deckCell = reveal(app, "deck-cell-\(key)-main")
        XCTAssertTrue(deckCell.label.hasPrefix("Dockside Lock-Up, ×2"), deckCell.label)
    }

    // MARK: Pasting a deck (phase 3A task 7)

    /// A Yu-Gi-Oh! deck with one card, `yg1` "Wind" (`cards` empty: an empty deck).
    private static func windDeck(cards: Bool = true) -> String {
        let list = cards ? #"[{"cardKey": "swiftwind panther warrior", "name": "Swiftwind Panther Warrior", "section": "main", "count": 1}]"# : "[]"
        return #"{"version": 1, "decks": [{"id": "yg1", "name": "Wind", "format": "standard", "active": false, "cards": "# + list + "}]}"
    }

    /// `-pasteDeck <fixture>`: the paste sheet opens at launch with the fixture's text (fix round 1: the tests never write
    /// the Mac's pasteboard).
    private func pasteDeck(_ fixture: String) -> [String] {
        ["-pasteDeck", Self.fixturesDirectory.appending(path: fixture).path]
    }

    /// The paste sheet that `-pasteDeck` opened, its editor holding the file's last line.
    private func pasteSheet(_ app: XCUIApplication, lastLine: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let sheet = element(app, "paste-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "no paste sheet", file: file, line: line)
        let editor = element(app, "paste-text")
        XCTAssertTrue(waitUntil { (editor.value as? String)?.contains(lastLine) == true },
                      "the editor does not hold the file: \(String(describing: editor.value))", file: file, line: line)
        return sheet
    }

    /// "Read" once the fixture catalog is settled, then the table.
    private func read(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let read = element(app, "paste-read")
        XCTAssertTrue(waitUntil(timeout: 30) { read.isEnabled }, "Read stays off", file: file, line: line)
        read.click()
        XCTAssertTrue(element(app, "paste-summary").waitForExistence(timeout: 10), "no table", file: file, line: line)
    }

    private func unknownLines(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'paste-unknown-' AND NOT (identifier == 'paste-unknown-count')"))
    }

    /// The sidebar's "New Deck…" → "Paste a deck…": the New Deck sheet closes, the paste sheet opens for a new deck with the
    /// name typed there; Cancel writes nothing.
    func testNewDeckOffersPasteADeck() throws {
        let app = launch(game: "yu-gi-oh", extra: ["-screen", "collection"])
        let newDeck = element(app, "sidebar-new-deck")
        XCTAssertTrue(newDeck.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { newDeck.isEnabled }, "New Deck… stays off")
        newDeck.click()
        let paste = element(app, "new-deck-paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste a deck…")
        shot("paste-00-new-deck-sheet", of: element(app, "new-deck-sheet"))
        paste.click()
        let sheet = element(app, "paste-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no paste sheet")
        XCTAssertTrue(waitUntil { !self.element(app, "new-deck-sheet").exists }, "the New Deck sheet stayed")
        XCTAssertEqual(element(app, "paste-name").value as? String, "Deck")
        XCTAssertEqual(text(element(app, "paste-title")), "Paste a Deck")
        XCTAssertFalse(element(app, "paste-read").isEnabled, "Read is on without text")
        element(app, "paste-cancel").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertEqual(try storedDecks(game: "yu-gi-oh"), [])
    }

    /// D11: the fixture text → Read: every card line, no unknown one, the sections the text names → Create deck: the deck's
    /// page with its sections; the file agrees.
    func testPasteCreatesADeck() throws {
        let app = launch(game: "yu-gi-oh", extra: ["-screen", "collection"] + pasteDeck("deck-yugioh.txt"))
        let sheet = pasteSheet(app, lastLine: "1 Token: Joey and Red-Eyes Black Dragon")
        XCTAssertEqual(element(app, "paste-name").value as? String, "Deck")
        shot("paste-01-text", of: sheet)
        read(app)
        XCTAssertEqual(text(element(app, "paste-summary")), "6 cards on 3 lines")
        XCTAssertEqual(unknownLines(app).count, 0, "\(identifiers(unknownLines(app)))")
        XCTAssertFalse(element(app, "paste-unknown-count").exists)
        XCTAssertEqual(text(element(app, "paste-section-3")), "Main Deck")
        XCTAssertEqual(text(element(app, "paste-section-6")), "Extra Deck")
        XCTAssertEqual(text(element(app, "paste-section-9")), "Side Deck")
        XCTAssertEqual(text(element(app, "paste-count-6")), "2")
        shot("paste-02-table", of: sheet)
        let create = element(app, "paste-apply")
        XCTAssertTrue(create.isEnabled)
        XCTAssertEqual(create.title.isEmpty ? create.label : create.title, "Create deck")
        create.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-section-main")) == "Main Deck · 3" })
        XCTAssertEqual(text(element(app, "deck-section-extra")), "Extra Deck · 2")
        XCTAssertEqual(text(element(app, "deck-section-side")), "Side Deck · 1")
        shot("paste-03-created-deck")
        var decks: [StoredDeck] = []
        XCTAssertTrue(waitUntil { decks = (try? self.storedDecks(game: "yu-gi-oh")) ?? []; return decks.count == 1 })
        let id = try XCTUnwrap(decks.first?.id)
        XCTAssertEqual(decks, [StoredDeck(id: id, name: "Deck", format: "standard", active: false,
                                          cards: ["swiftwind panther warrior|main|3", "stardust dragon|extra|2",
                                                  "token joey and red eyes black dragon|side|1"])])
    }

    /// A misspelt name and a nonsense line: "Create deck" is off; the suggestion is picked (the row says what was written),
    /// the other line dropped; then it is on, and the deck has the fixed card and not the dropped one.
    func testAnUnknownLineIsFixedOrDropped() throws {
        let app = launch(game: "yu-gi-oh", extra: ["-screen", "collection"] + pasteDeck("deck-misspelt.txt"))
        let sheet = pasteSheet(app, lastLine: "1 Qqq Zzz")
        read(app)
        let create = element(app, "paste-apply")
        XCTAssertFalse(create.isEnabled, "Create deck is on with unknown lines")
        XCTAssertTrue(text(element(app, "paste-unknown-count")).hasPrefix("2 lines not recognised"), text(element(app, "paste-unknown-count")))
        XCTAssertEqual(identifiers(unknownLines(app)), ["paste-unknown-4", "paste-unknown-5"])
        shot("paste-04-unknown-lines", of: sheet)
        element(app, "paste-unknown-4").click()
        let suggestion = app.menuItems["Stardust Dragon"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "no suggestion")
        XCTAssertTrue(app.menuItems["Drop this line"].firstMatch.exists)
        shot("paste-05-suggestions")
        suggestion.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "paste-unknown-count")).hasPrefix("1 line not recognised") })
        XCTAssertEqual(text(element(app, "paste-note-4")), "as written: Stardust Dragn")
        XCTAssertFalse(create.isEnabled)
        element(app, "paste-unknown-5").click()
        let drop = app.menuItems["Drop this line"].firstMatch
        XCTAssertTrue(drop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["No near names in the catalog"].firstMatch.exists, "a nonsense line has suggestions")
        drop.click()
        XCTAssertTrue(waitUntil { create.isEnabled }, "Create deck stays off")
        XCTAssertEqual(text(element(app, "paste-summary")), "3 cards on 2 lines, 1 line dropped")
        XCTAssertEqual(text(element(app, "paste-note-5")), "dropped")
        shot("paste-06-fixed-and-dropped", of: sheet)
        create.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "yu-gi-oh"))?.first?.cards
                == ["swiftwind panther warrior|main|1", "stardust dragon|extra|2"] },
                      "\(String(describing: try? storedDecks(game: "yu-gi-oh")))")
    }

    /// Review Focus 3: Cancel after the table writes nothing: the file's bytes are equal, and no deck is added. On the empty
    /// deck, which also offers "Paste…".
    func testPasteCancelWritesNothing() throws {
        let app = try launch(game: "yu-gi-oh", extra: ["-screen", "deck:yg1"] + pasteDeck("deck-misspelt.txt")) { _ in
            try self.writeUserFile(game: "yu-gi-oh", json: Self.windDeck(cards: false))
        }
        let file = try XCTUnwrap(root).appending(path: "user").appending(path: "yu-gi-oh.json")
        let before = try Data(contentsOf: file)
        let sheet = pasteSheet(app, lastLine: "1 Qqq Zzz")
        XCTAssertEqual(text(element(app, "paste-title")), "Paste into Wind")
        XCTAssertFalse(element(app, "paste-name").exists, "a name field when adding to a deck")
        read(app)
        XCTAssertEqual(text(element(app, "paste-summary")), "1 card on 1 line, 2 lines not recognised")
        element(app, "paste-cancel").click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        let emptyPaste = element(app, "deck-empty-paste")
        XCTAssertTrue(emptyPaste.waitForExistence(timeout: 5), "the deck is not empty any more")
        shot("paste-07-empty-deck")
        RunLoop.current.run(until: Date().addingTimeInterval(1))          // a queued write would land by now
        XCTAssertEqual(try Data(contentsOf: file), before, "Cancel wrote the file")
        emptyPaste.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the empty deck's Paste… opens no sheet")
        element(app, "paste-cancel").click()
        XCTAssertTrue(waitUntil { !sheet.exists })
    }

    /// "Paste…" in a deck page's toolbar adds counts to the cards already there; a card new to the deck goes to the
    /// section its kind picks. (The sheet opens by `-pasteDeck` on the deck shown; the toolbar's button is checked after.)
    func testPasteAddsToADeck() throws {
        let app = try launch(game: "yu-gi-oh", extra: ["-screen", "deck:yg1"] + pasteDeck("deck-add.txt")) { _ in
            try self.writeUserFile(game: "yu-gi-oh", json: Self.windDeck())
        }
        let sheet = pasteSheet(app, lastLine: "1 Stardust Dragon")
        read(app)
        XCTAssertEqual(text(element(app, "paste-section-2")), "Extra Deck")
        let add = element(app, "paste-apply")
        XCTAssertEqual(add.title.isEmpty ? add.label : add.title, "Add to Wind")
        shot("paste-08-add-to-deck", of: sheet)
        add.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-section-main")) == "Main Deck · 3" })
        XCTAssertEqual(text(element(app, "deck-section-extra")), "Extra Deck · 1")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "yu-gi-oh"))?.first?.cards
                == ["swiftwind panther warrior|main|3", "stardust dragon|extra|1"] },
                      "\(String(describing: try? storedDecks(game: "yu-gi-oh")))")
        let paste = element(app, "deck-paste")
        XCTAssertTrue(waitUntil { paste.isEnabled })
        shot("paste-09-deck-toolbar")
        paste.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the toolbar's Paste… opens no sheet")
        XCTAssertEqual(text(element(app, "paste-title")), "Paste into Wind")
    }
}
