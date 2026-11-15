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
        return try decks.map { deck in
            let cards = try XCTUnwrap(deck["cards"] as? [[String: Any]]).map { card in
                "\(card["cardKey"] as? String ?? "")|\(card["section"] as? String ?? "")|\(card["count"] as? Int ?? -1)"
            }
            return StoredDeck(id: try XCTUnwrap(deck["id"] as? String), name: deck["name"] as? String ?? "",
                              format: deck["format"] as? String ?? "", active: deck["active"] as? Bool ?? false, cards: cards)
        }
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
        XCTAssertTrue(element(app, "deck-cell-dockside lock up-main").label.hasPrefix("Dockside Lock-Up, ×2, $5.12"),
                      element(app, "deck-cell-dockside lock up-main").label)
        XCTAssertEqual(identifiersInOrder(sectionTitles(app)),
                       ["deck-section-legend", "deck-section-champion", "deck-section-main", "deck-section-runes",
                        "deck-section-battlefields", "deck-section-sideboard"])
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 4")
        XCTAssertEqual(text(element(app, "deck-section-legend")), "Legend · 0")
        XCTAssertEqual(text(element(app, "deck-warning-legend")), "1 card")
        XCTAssertEqual(text(element(app, "deck-warning-main")), "Main Deck with its Champion: at least 40 cards")
        XCTAssertFalse(element(app, "deck-warning-runes").exists, "12 runes meet the bound")
        for heading in ["Units", "Gear", "Runes"] {
            XCTAssertTrue(element(app, "deck-gallery").staticTexts[heading].exists, "no group heading \(heading)")
        }
        XCTAssertTrue(waitUntil { self.title.contains("16 cards · 1 missing") }, title)
        XCTAssertEqual(text(element(app, "sidebar-decks-unreadable")), "1 deck cannot be read.")
        XCTAssertFalse(element(app, "sidebar-deck-missing-rb1").exists, "a deck that is not active shows a count")
        shot("decks-04-riftbound-deck-top")
        let rune = element(app, "deck-cell-calm rune-runes")
        element(app, "deck-gallery").scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(rune.waitForExistence(timeout: 5))
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
        XCTAssertTrue(waitUntil { self.text(warning) == "40–60 cards · more than 3 copies: Swiftwind Panther Warrior" }, text(warning))
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 3")
        shot("decks-11-warnings")
        let plus = element(app, "deck-cell-plus-swiftwind panther warrior-main")
        XCTAssertTrue(plus.isEnabled)
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-cell-value-swiftwind panther warrior-main")) == "4" })
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
        XCTAssertEqual(text(element(app, "deck-warning-deck")), "Commander deck: 100 cards")

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
        XCTAssertTrue(element(app, "deck-cell-ajani resolute-deck").waitForExistence(timeout: 10))
        XCTAssertEqual(identifiersInOrder(sectionTitles(app)), ["deck-section-deck", "deck-section-sideboard"])
        XCTAssertEqual(text(element(app, "deck-section-deck")), "Deck · 2")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "magic-the-gathering"))
                == [StoredDeck(id: "mg1", name: "Lifegain", format: "constructed", active: false,
                               cards: ["ajani resolute|deck|1", "bloodline recollector|deck|1"])] },
                      "\(String(describing: try? storedDecks(game: "magic-the-gathering")))")
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
        let gone = element(app, "deck-cell-vanished card-main")
        XCTAssertTrue(gone.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { gone.label == "Vanished Card, ×1, no price" }, gone.label)
        XCTAssertFalse(element(app, "deck-catalog-note").exists, "a settled catalog still says it downloads")
        XCTAssertTrue(waitUntil { self.text(self.element(app, "sidebar-deck-missing-rb2")) == "1" })   // Kai'Sa only
        shot("decks-18-card-not-in-the-catalog")
        element(app, "deck-cell-minus-vanished card-main").click()
        XCTAssertTrue(waitUntil { !gone.exists }, "− left the card")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards == ["kai sa rebel|main|1"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
    }
}
