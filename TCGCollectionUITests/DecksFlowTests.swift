import AppKit
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
    private static var deckRowMatch: ElementMatch {
        ElementMatch(.any, "identifier BEGINSWITH 'sidebar-deck-' AND NOT (identifier BEGINSWITH 'sidebar-deck-missing-')")
    }
    private static var sectionTitleMatch: ElementMatch { ElementMatch(.any, "identifier BEGINSWITH 'deck-section-'") }

    private func deckRows(_ app: XCUIApplication) -> XCUIElementQuery { Self.deckRowMatch.query(app) }

    private var title: String { XCUIApplication(bundleIdentifier: Self.debugBundleID).windows.firstMatch.title }

    /// The Riftbound deck of the section test: Kai'Sa ×2 (1 owned), Dockside Lock-Up ×2 (3 owned), Calm Rune ×12 (none
    /// owned, basic), all in the format's default sections, and one card this build cannot read (a count as text); plus a
    /// second deck and one deck this build cannot read.
    private static let riftboundDeck = """
        {"version": 1,
         "collection": [{"productID": 721337, "finish": "Normal", "count": 1, "condition": "", "name": "Kai'Sa, Rebel"},
                        {"productID": 721334, "finish": "Normal", "count": 3, "condition": "", "name": "Dockside Lock-Up"}],
         "decks": [{"id": "rb1", "name": "Kai'Sa", "format": "standard", "active": false,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2},
                              {"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 2},
                              {"cardKey": "calm rune", "name": "Calm Rune", "section": "runes", "count": 12},
                              {"cardKey": "odd card", "name": "Odd Card", "section": "main", "count": "2"}]},
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
        XCTAssertTrue(waitUntil { rows.count == 1 }, "\(identifiers(app, Self.deckRowMatch))")
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
        XCTAssertEqual(identifiersInOrder(app, Self.sectionTitleMatch),
                       ["deck-section-legend", "deck-section-champion", "deck-section-main", "deck-section-runes",
                        "deck-section-battlefields", "deck-section-sideboard"])
        XCTAssertEqual(text(element(app, "deck-section-main")), "Main Deck · 4")
        XCTAssertEqual(text(element(app, "deck-section-legend")), "Legend · 0")
        XCTAssertEqual(text(element(app, "deck-warning-legend")), "needs 1 card")
        XCTAssertEqual(text(element(app, "deck-warning-main")), "Main Deck with its Champion: needs 40 cards")
        XCTAssertFalse(element(app, "deck-warning-runes").exists, "12 runes meet the bound")
        for heading in ["Units", "Gear", "Runes"] {
            XCTAssertTrue(element(app, "deck-screen").staticTexts[heading].exists, "no group heading \(heading)")
        }
        XCTAssertTrue(waitUntil { self.title.contains("16 cards · 1 missing") }, title)
        XCTAssertEqual(text(element(app, "sidebar-decks-unreadable")), "1 deck cannot be read.")
        // Final fix B8: the card this build cannot read is named under the totals.
        XCTAssertEqual(text(element(app, "deck-unreadable-cards")), "1 card of this deck cannot be read.")
        XCTAssertFalse(element(app, "sidebar-deck-missing-rb1").exists, "a deck that is not active shows a count")
        // The status area has its own room: the sidebar's list ends above it, and the last row inside the list's visible
        // part ends above the status line too (final fix B9: not passing when a row is not hittable).
        let status = app.staticTexts["status-line"], list = app.outlines.firstMatch
        XCTAssertTrue(status.exists && list.exists, "no status line or sidebar list")
        XCTAssertLessThanOrEqual(list.frame.maxY, status.frame.minY + 0.5, "the list reaches under the status line: \(list.frame) \(status.frame)")
        let rows = ["sidebar-collection", "sidebar-wanted", "sidebar-for-sale", "sidebar-sets", "sidebar-deck-rb1", "sidebar-deck-rb9",
                    "sidebar-decks-unreadable", "sidebar-new-deck", "sidebar-all-cards"].map { element(app, $0) }
            .filter { $0.exists && $0.frame.minY < list.frame.maxY }
        let last = try XCTUnwrap(rows.max { $0.frame.maxY < $1.frame.maxY }, "no sidebar row in the list's visible part")
        XCTAssertLessThanOrEqual(min(last.frame.maxY, list.frame.maxY), status.frame.minY + 0.5,
                                 "the status line is over \(last.identifier): \(last.frame) \(status.frame)")
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
        XCTAssertTrue(waitUntil { self.identifiersInOrder(app, Self.sectionTitleMatch) == ["deck-section-deck", "deck-section-sideboard"] },
                      "\(identifiersInOrder(app, Self.sectionTitleMatch))")
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

    // MARK: Final fix wave

    /// Final fix A2: New Deck's Create works once. A name typed and Return: one deck; a double click on Create: one deck
    /// more, not two.
    func testCreateMakesOneDeckOnReturnAndOnADoubleClick() throws {
        let app = launch(game: "riftbound", extra: ["-screen", "collection"])
        let newDeck = element(app, "sidebar-new-deck")
        XCTAssertTrue(newDeck.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { newDeck.isEnabled }, "New Deck… stays off")
        newDeck.click()
        let sheet = element(app, "new-deck-sheet"), field = element(app, "new-deck-name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Rift")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { !sheet.exists }, "Return did not close the sheet")
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))          // a second deck would be written by now
        var decks = try storedDecks(game: "riftbound")
        XCTAssertEqual(decks.map(\.name), ["Rift"], "Return made \(decks.count) decks")

        XCTAssertTrue(waitUntil { newDeck.isEnabled })
        newDeck.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        element(app, "new-deck-create").doubleClick()
        XCTAssertTrue(waitUntil { !sheet.exists }, "the sheet stayed open")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        decks = try storedDecks(game: "riftbound")
        XCTAssertEqual(decks.map(\.name), ["Rift", "Deck"], "a double click made \(decks.count - 1) decks")
        XCTAssertEqual(deckRows(app).count, 2, "\(identifiers(app, Self.deckRowMatch))")
    }

    /// C1: a card page opened from a deck cell is kept across a switch of the sidebar to the Collection and back; Back shows
    /// the deck. A deck card without a printing opens no page.
    func testACardPageOfADeckIsKeptAcrossASidebarSwitch() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb3"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1,
             "decks": [{"id": "rb3", "name": "Kept", "format": "standard", "active": false,
                        "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 1},
                                  {"cardKey": "vanished card", "name": "Vanished Card", "section": "main", "count": 1}]}]}
            """)
        }
        let kaisa = element(app, "deck-cell-kai sa rebel-main")
        XCTAssertTrue(kaisa.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        kaisa.click()
        let page = element(app, "card-page")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "a deck cell opens no card page")
        XCTAssertEqual(text(element(app, "card-title")), "Kai'Sa, Rebel")
        element(app, "sidebar-collection").click()
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
        XCTAssertFalse(page.exists)
        element(app, "sidebar-deck-rb3").click()
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the card page was not kept")
        XCTAssertEqual(text(element(app, "card-title")), "Kai'Sa, Rebel")
        shot("decks-26-card-page-kept")
        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(waitUntil { !page.exists }, "Back left the card page")
        XCTAssertTrue(element(app, "deck-screen").waitForExistence(timeout: 10))
        let vanished = reveal(app, "deck-cell-vanished card-main")
        vanished.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(page.exists, "a deck card without a printing opened a page")
        XCTAssertTrue(element(app, "deck-screen").exists)
    }

    /// C2: the arrow keys in the sidebar go from the Collection down over Wanted, For Sale, Sets, each deck row and All cards; the
    /// unreadable-decks line and "New Deck…" are not selectable, so they are passed over.
    func testTheArrowKeysCrossTheDeckRows() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "collection"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.riftboundDeck)
        }
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "sidebar-decks-unreadable").waitForExistence(timeout: 10))
        element(app, "sidebar-collection").click()
        let steps: [(row: String, title: String)] = [("sidebar-wanted", "Wanted"), ("sidebar-for-sale", "For Sale"),
                                                     ("sidebar-sets", "Sets"), ("sidebar-deck-rb1", "Kai'Sa"), ("sidebar-deck-rb9", "Second"),
                                                     ("sidebar-all-cards", "Riftbound")]
        for step in steps {
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(waitUntil { self.title.hasPrefix(step.title) }, "\(step.row): the window shows \(self.title)")
            assertAccentFill(app, row: step.row)
        }
        shot("decks-27-arrow-down-to-all-cards")
        for step in steps.reversed().dropFirst() {
            app.typeKey(.upArrow, modifierFlags: [])
            XCTAssertTrue(waitUntil { self.title.hasPrefix(step.title) }, "\(step.row): the window shows \(self.title)")
        }
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "collection-screen").waitForExistence(timeout: 10))
    }

    /// C3: fast `+` clicks on a deck cell, then Cmd+Q at once while the write waits (`-writeDelay`): the file has every
    /// click, and the next launch shows it.
    func testFastDeckClicksAndAQuitAtOnceReachTheFile() throws {
        let app = try launch(game: "cyberpunk", extra: ["-screen", "deck:cp1", "-writeDelay", "4000"]) { _ in
            try self.writeUserFile(game: "cyberpunk", json: """
            {"version": 1,
             "decks": [{"id": "cp1", "name": "Rockers", "format": "standard", "active": false,
                        "cards": [{"cardKey": "kerry eurodyne the last rockerboy", "name": "Kerry Eurodyne", "section": "main", "count": 1}]}]}
            """)
        }
        let kerry = "kerry eurodyne the last rockerboy"
        let plus = element(app, "deck-cell-plus-\(kerry)-main")
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { plus.isEnabled })
        plus.doubleClick()
        plus.click()
        plus.click()
        let value = element(app, "deck-cell-value-\(kerry)-main")
        XCTAssertTrue(waitUntil(timeout: 3) { self.text(value) == "5" }, text(value))
        XCTAssertNotEqual(try storedDecks(game: "cyberpunk").first?.cards, ["\(kerry)|main|5"],
                          "the write was done before the quit: nothing to wait for")
        quit(app)                                                // at once: the last write is still waiting
        XCTAssertEqual(try storedDecks(game: "cyberpunk").first?.cards, ["\(kerry)|main|5"])

        app.launch()
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(self.element(app, "deck-cell-value-\(kerry)-main")) == "5" })
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

    // MARK: A deck card's printing (phase 3A feedback 1, A18)

    private static let warrior = "swiftwind panther warrior"
    /// 40 characters: wider than the details column at 900 pt.
    private static let longDeckName = "Panther Warriors of the Long Night Decks"

    /// Each card of the deck `id` as `<cardKey>|<section>|<productID or "-">`; a `productID` key that is there but not a
    /// whole number is `?`.
    private func storedPrintings(game: String, deck id: String) throws -> [String] {
        let decks = try XCTUnwrap(try storedUserFile(game: game)?["decks"] as? [[String: Any]], "no decks")
        let deck = try XCTUnwrap(decks.first { $0["id"] as? String == id }, "no deck \(id)")
        return (deck["cards"] as? [[String: Any]] ?? []).map { card in
            let printing = card["productID"].map { ($0 as? Int).map(String.init) ?? "?" } ?? "-"
            return "\(card["cardKey"] as? String ?? "")|\(card["section"] as? String ?? "")|\(printing)"
        }
    }

    /// Switches the open card page to the printing `productID` (a row of "Other printings", below the window's edge)
    /// and waits until its facts line names `rarity`.
    private func showPrinting(_ app: XCUIApplication, _ productID: Int, rarity: String, file: StaticString = #filePath,
                              line: UInt = #line) {
        let row = revealOnCardPage(app, "printing-row-\(productID)", file: file, line: line)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).click()
        let facts = app.staticTexts["card-facts-line"]
        XCTAssertTrue(waitUntil { self.text(facts).contains(rarity) }, text(facts), file: file, line: line)
        // The click leaves the page scrolled to the bottom; the Decks block is above the Price history block.
        element(app, "card-page").scroll(byDeltaX: 0, deltaY: 2000)
    }

    /// The card page's facts line names `rarity` (the page opened on that printing).
    private func assertPageRarity(_ app: XCUIApplication, _ rarity: String, file: StaticString = #filePath, line: UInt = #line) {
        let facts = app.staticTexts["card-facts-line"]
        XCTAssertTrue(facts.waitForExistence(timeout: 10), "no card page", file: file, line: line)
        XCTAssertTrue(waitUntil { self.text(facts).contains(rarity) }, text(facts), file: file, line: line)
    }

    /// A18: "Add to deck" on the second printing's page (719834, Super Rare) saves that printing on the new line; the deck
    /// cell shows it (its own price, $9.00, its cheapest finish) and opens its page. A deck that holds the card without a
    /// printing, with nothing owned, shows the cheapest printing (719835, $3.10). The deck lines' printing buttons stay in
    /// the 900 pt window.
    func testAddToDeckSavesThePagesPrinting() throws {
        let app = try launch(game: "yu-gi-oh") { root in
            try self.writePinPrices(in: root)
            try self.writeUserFile(game: "yu-gi-oh", json: """
            {"version": 1, "decks": [{"id": "yg1", "name": "Wind", "format": "standard", "active": false, "cards": []},
                                     {"id": "yg2", "name": "Cheap", "format": "standard", "active": false,
                                      "cards": [{"cardKey": "\(Self.warrior)", "name": "Swiftwind Panther Warrior", "section": "main", "count": 1}]},
                                     {"id": "yg3", "name": "\(Self.longDeckName)", "format": "standard", "active": false,
                                      "cards": [{"cardKey": "\(Self.warrior)", "name": "Swiftwind Panther Warrior", "section": "side", "count": 1}]}]}
            """)
        }
        let cell = element(app, "card-cell-\(Self.warrior)")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        cell.click()
        assertPageRarity(app, "Starlight Rare")                   // the catalog's first printing
        showPrinting(app, 719834, rarity: "Super Rare")
        revealOnCardPage(app, "card-add-to-deck").click()
        let wind = app.menuItems["Wind"].firstMatch
        XCTAssertTrue(wind.waitForExistence(timeout: 5))
        wind.click()
        XCTAssertTrue(waitUntil { (try? self.storedPrintings(game: "yu-gi-oh", deck: "yg1")) == ["\(Self.warrior)|main|719834"] },
                      "\(String(describing: try? storedPrintings(game: "yu-gi-oh", deck: "yg1")))")
        // The line stored on this page's printing offers "Any printing"; the other deck's line "Use this printing".
        let windButton = revealOnCardPage(app, "deck-line-printing-yg1-main")
        XCTAssertTrue(waitUntil { windButton.label == "Any printing" }, windButton.label)
        let cheapButton = revealOnCardPage(app, "deck-line-printing-yg2-main")
        XCTAssertEqual(cheapButton.label, "Use this printing")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.width, 900, accuracy: 1, "the deck lines widened the window")
        // Fix round 1: two rows per line, so a short deck name reads whole beside "Use this printing" and "Any printing".
        for (id, name) in [("yg1-main", "Wind"), ("yg2-main", "Cheap")] {
            element(app, "card-page").scroll(byDeltaX: 0, deltaY: 2000)      // `revealOnCardPage` scrolls down only
            let label = revealOnCardPage(app, "deck-line-name-\(id)")
            XCTAssertEqual(text(label), name)
            let whole = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
            XCTAssertGreaterThanOrEqual(label.frame.width + 1, whole, "\(name) is cut: \(label.frame)")
            XCTAssertLessThanOrEqual(label.frame.maxX, window.maxX, "\(name) leaves the window: \(label.frame)")
            let button = revealOnCardPage(app, "deck-line-printing-\(id)")
            XCTAssertTrue(button.isHittable, "\(button.identifier) is not hittable")
            XCTAssertLessThanOrEqual(button.frame.maxX, window.maxX, "\(button.identifier) leaves the window: \(button.frame)")
            XCTAssertGreaterThan(button.frame.minY, label.frame.maxY - 1, "the button is not under the name: \(button.frame)")
        }
        // A long name may truncate; the window stays 900 pt and its line's controls stay in it.
        element(app, "card-page").scroll(byDeltaX: 0, deltaY: 2000)
        let long = revealOnCardPage(app, "deck-line-name-yg3-side")
        XCTAssertLessThanOrEqual(long.frame.maxX, window.maxX, "the long name leaves the window: \(long.frame)")
        let longButton = revealOnCardPage(app, "deck-line-printing-yg3-side")
        XCTAssertTrue(longButton.isHittable)
        XCTAssertLessThanOrEqual(longButton.frame.maxX, window.maxX)
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, accuracy: 1, "the long deck name widened the window")
        shot("decks-40-card-page-printing-buttons")

        element(app, "sidebar-deck-yg1").click()
        let windCell = reveal(app, "deck-cell-\(Self.warrior)-main")
        XCTAssertTrue(waitUntil { windCell.label == "Swiftwind Panther Warrior, ×1 · 1 missing, $9.00" }, windCell.label)
        shot("decks-41-deck-cell-chosen-printing")
        windCell.click()
        assertPageRarity(app, "Super Rare")

        element(app, "sidebar-deck-yg2").click()
        let cheapCell = reveal(app, "deck-cell-\(Self.warrior)-main")
        XCTAssertTrue(waitUntil { cheapCell.label == "Swiftwind Panther Warrior, ×1 · 1 missing, $3.10" }, cheapCell.label)
        cheapCell.click()
        assertPageRarity(app, "Starlight Rare")
    }

    /// A18: with no stored printing the cell shows the printing owned (719834, though 719835 is cheaper). "Use this
    /// printing" on the other printing's page stores it (the cell follows); "Any printing" clears the key from the file,
    /// and the cell shows the owned printing again.
    func testUseThisPrintingAndAnyPrinting() throws {
        let app = try launch(game: "yu-gi-oh", extra: ["-screen", "deck:yg1"]) { root in
            try self.writePinPrices(in: root)
            try self.writeUserFile(game: "yu-gi-oh", json: """
            {"version": 1,
             "collection": [{"productID": 719834, "finish": "Unlimited", "count": 1, "condition": "", "name": "Swiftwind Panther Warrior"}],
             "decks": [{"id": "yg1", "name": "Wind", "format": "standard", "active": false,
                        "cards": [{"cardKey": "\(Self.warrior)", "name": "Swiftwind Panther Warrior", "section": "main", "count": 1}]}]}
            """)
        }
        let deckCell = reveal(app, "deck-cell-\(Self.warrior)-main")
        XCTAssertTrue(waitUntil { deckCell.label == "Swiftwind Panther Warrior, ×1, $9.00" }, deckCell.label)
        shot("decks-42-deck-cell-owned-printing")
        deckCell.click()
        assertPageRarity(app, "Super Rare")
        let button = revealOnCardPage(app, "deck-line-printing-yg1-main")
        XCTAssertEqual(button.label, "Use this printing")
        showPrinting(app, 719835, rarity: "Starlight Rare")
        let use = revealOnCardPage(app, "deck-line-printing-yg1-main")
        XCTAssertEqual(use.label, "Use this printing")
        use.click()
        XCTAssertTrue(waitUntil { use.label == "Any printing" }, use.label)
        XCTAssertTrue(waitUntil { (try? self.storedPrintings(game: "yu-gi-oh", deck: "yg1")) == ["\(Self.warrior)|main|719835"] },
                      "\(String(describing: try? storedPrintings(game: "yu-gi-oh", deck: "yg1")))")
        XCTAssertEqual(app.windows.firstMatch.frame.width, 900, accuracy: 1, "the deck line widened the window")
        shot("decks-43-card-page-any-printing")
        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(waitUntil { deckCell.label == "Swiftwind Panther Warrior, ×1, $3.10" }, deckCell.label)

        deckCell.click()
        assertPageRarity(app, "Starlight Rare")
        let any = revealOnCardPage(app, "deck-line-printing-yg1-main")
        XCTAssertEqual(any.label, "Any printing")
        any.click()
        XCTAssertTrue(waitUntil { any.label == "Use this printing" }, any.label)
        XCTAssertTrue(waitUntil { (try? self.storedPrintings(game: "yu-gi-oh", deck: "yg1")) == ["\(Self.warrior)|main|-"] },
                      "\(String(describing: try? storedPrintings(game: "yu-gi-oh", deck: "yg1")))")
        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(waitUntil { deckCell.label == "Swiftwind Panther Warrior, ×1, $9.00" }, deckCell.label)
    }

    // MARK: The deck order (phase 3B task 4: E4, E6)

    /// Two active decks use Kai'Sa ×2 and 2 are owned, with no sharing answer: the first deck in the order gets both copies,
    /// the second misses 2.
    private static let twoDecksOneKaisa = """
        {"version": 1,
         "collection": [{"productID": 721337, "finish": "Normal", "count": 2, "condition": "", "name": "Kai'Sa, Rebel"}],
         "decks": [{"id": "rb1", "name": "Wind", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2}]},
                   {"id": "rb2", "name": "Cheap", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2}]}]}
        """

    /// E4, E6: the second deck's row shows 2 and its cell `×2 · 2 missing`; Deck ▸ "Move Up" on it makes it the first:
    /// the counts swap (the first row none, the moved one served first), its cell has no "missing", the file's `decks`
    /// order changed, and on the first deck "Move Up" is off while "Move Down" is on. (The sidebar's drag, `onMove`, has no
    /// UI test: XCUITest's drags did not move a row on macOS 27, phase 3B task 4.)
    func testDecksAreServedInDeckOrder() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb2"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.twoDecksOneKaisa)
        }
        let cell = element(app, "deck-cell-kai sa rebel-main")
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let first = element(app, "sidebar-deck-missing-rb1"), second = element(app, "sidebar-deck-missing-rb2")
        XCTAssertTrue(second.waitForExistence(timeout: 10), "no count on the second deck")
        XCTAssertEqual(text(second), "2")
        XCTAssertFalse(first.exists, "the first deck in the order shows a count")
        XCTAssertTrue(waitUntil { cell.label.hasPrefix("Kai'Sa, Rebel, ×2 · 2 missing, ") }, cell.label)
        XCTAssertEqual(identifiersInOrder(app, Self.deckRowMatch), ["sidebar-deck-rb1", "sidebar-deck-rb2"])
        shot("decks-44-second-deck-misses")

        element(app, "deck-menu").click()
        let up = app.menuItems["Move Up"].firstMatch, down = app.menuItems["Move Down"].firstMatch
        XCTAssertTrue(up.waitForExistence(timeout: 5))
        XCTAssertTrue(up.isEnabled, "Move Up is off on the second deck")
        XCTAssertFalse(down.isEnabled, "Move Down is on on the last deck")
        shot("decks-45-deck-menu-move-up")
        up.click()

        XCTAssertTrue(first.waitForExistence(timeout: 10), "no count on the deck moved second")
        XCTAssertEqual(text(first), "2")
        XCTAssertTrue(waitUntil { !second.exists }, "the deck moved first still shows a count")
        XCTAssertTrue(waitUntil { cell.label.hasPrefix("Kai'Sa, Rebel, ×2, ") }, cell.label)
        XCTAssertTrue(waitUntil { self.identifiersInOrder(app, Self.deckRowMatch) == ["sidebar-deck-rb2", "sidebar-deck-rb1"] },
                      "\(identifiersInOrder(app, Self.deckRowMatch))")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.map(\.id) == ["rb2", "rb1"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
        shot("decks-46-moved-up-counts-swapped")

        element(app, "deck-menu").click()
        XCTAssertTrue(app.menuItems["Move Up"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Move Up"].firstMatch.isEnabled, "Move Up is on on the first deck")
        XCTAssertTrue(app.menuItems["Move Down"].firstMatch.isEnabled, "Move Down is off on the first deck")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: The sharing decision (phase 3B task 6: A22, E7, E8)

    /// The file's `sharing` answers, by card key; [:] with no file or no list.
    private func storedSharing(game: String) throws -> [String: Bool] {
        guard let list = try storedUserFile(game: game)?["sharing"] as? [[String: Any]] else { return [:] }
        return Dictionary(list.compactMap { entry in
            (entry["cardKey"] as? String).flatMap { key in (entry["shared"] as? Bool).map { (key, $0) } }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// `element` is in the window and can be clicked; the window is still 900 pt wide.
    private func assertInWindow(_ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath,
                                line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.width, 900, accuracy: 1, "the window is not 900 pt", file: file, line: line)
        XCTAssertTrue(element.exists && element.isHittable, "\(element.identifier) is not hittable", file: file, line: line)
        XCTAssertTrue(window.contains(element.frame), "\(element.identifier) leaves the window: \(element.frame)",
                      file: file, line: line)
    }

    /// The element `identifier` of Wanted, scrolled into the window (XCUITest does not scroll to a click).
    private func revealOnWanted(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath,
                                line: UInt = #line) -> XCUIElement {
        // The screen's container: XCUITest does not find the scroll view by its own identifier (`wanted-gallery`).
        let target = element(app, identifier), gallery = element(app, "wanted-screen")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "no Wanted screen", file: file, line: line)
        for _ in 0..<15 {
            if target.exists, target.isHittable { return target }
            gallery.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(target.exists && target.isHittable, "\(identifier) is not in the window", file: file, line: line)
        return target
    }

    /// Waits until `element` stops moving (a scroll's deceleration), so a click lands on it: once its frame was the same
    /// on two reads 0.3 s apart. Returns the element.
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

    /// Cyberpunk: two active decks use Kerry, Satori and Jackie once each; none is owned: three pending cards.
    private static let threePending = """
        {"version": 1, "collection": [],
         "decks": [{"id": "cp1", "name": "Wind", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kerry eurodyne the last rockerboy", "name": "Kerry Eurodyne - The Last Rockerboy", "section": "main", "count": 1},
                              {"cardKey": "satori sword of saburo", "name": "Satori - Sword of Saburo", "section": "main", "count": 1},
                              {"cardKey": "jackie welles ride or die choom", "name": "Jackie Welles - Ride or Die Choom", "section": "main", "count": 1}]},
                   {"id": "cp2", "name": "Cheap", "format": "standard", "active": true,
                    "cards": [{"cardKey": "kerry eurodyne the last rockerboy", "name": "Kerry Eurodyne - The Last Rockerboy", "section": "main", "count": 1},
                              {"cardKey": "satori sword of saburo", "name": "Satori - Sword of Saburo", "section": "main", "count": 1},
                              {"cardKey": "jackie welles ride or die choom", "name": "Jackie Welles - Ride or Die Choom", "section": "main", "count": 1}]}]}
        """

    /// A22, E7: Wind and Cheap use Kai'Sa ×2 each, 2 owned, no answer: Wanted lists it `×2 · 2 for decks` with "Decision
    /// pending", "Share" and "Buy more" under its control, and "Decisions (1)…" in the toolbar. The launch says nothing
    /// in the status line (E8: the cards pending at the first read are the base). "Share": the card leaves Wanted, the
    /// file's `sharing` has it `true`, the second deck's sidebar count is gone.
    func testAPendingCardIsDecidedOnItsWantedCell() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "wanted"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.twoDecksOneKaisa)
        }
        let key = "kai sa rebel"
        let cell = app.buttons["wanted-cell-\(key)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the pending card is not on Wanted")
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { cell.label.hasPrefix("Kai'Sa, Rebel, ×2, 2 for decks, ") }, cell.label)
        let pending = element(app, "wanted-pending-\(key)")
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "no pending row")
        XCTAssertEqual(text(pending), "Decision pending")
        let decisions = element(app, "wanted-decisions")
        XCTAssertTrue(decisions.exists, "no Decisions button")
        XCTAssertEqual(decisions.label, "Decisions (1)…")
        // The cell is taller than the 450 pt test window: scroll the gallery until the row is in it.
        let share = settled(revealOnWanted(app, "wanted-share-\(key)")), buy = element(app, "wanted-buy-\(key)")
        assertInWindow(app, share)
        assertInWindow(app, buy)
        XCTAssertEqual(share.label, "Share")
        XCTAssertEqual(buy.label, "Buy more")
        XCTAssertGreaterThanOrEqual(buy.frame.width, 50, "Buy more is cut: \(buy.frame)")
        XCTAssertTrue(element(app, "sidebar-deck-missing-rb2").exists, "the second deck has no count")
        XCTAssertFalse(text(app.staticTexts["status-line"]).contains("sharing decision"), "the launch said the pending card")
        shot("decks-50-wanted-pending-cell")

        share.click()
        XCTAssertTrue(waitUntil { !cell.exists }, "the shared card stayed on Wanted")
        XCTAssertTrue(waitUntil { (try? self.storedSharing(game: "riftbound")) == [key: true] },
                      "\(String(describing: try? storedSharing(game: "riftbound")))")
        XCTAssertTrue(waitUntil { !self.element(app, "sidebar-deck-missing-rb2").exists }, "the second deck still misses copies")
        XCTAssertFalse(decisions.exists, "Decisions stays with nothing pending")
        shot("decks-51-wanted-after-share")
    }

    /// E7: "Buy more" on the pending cell: the card stays on Wanted with the decks' part (`×2 · 2 for decks`), no longer
    /// pending (no row, no Decisions button); the file has it `false`; the second deck still misses 2.
    func testBuyMoreKeepsTheCardOnWanted() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "wanted"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.twoDecksOneKaisa)
        }
        let key = "kai sa rebel"
        XCTAssertTrue(element(app, "wanted-buy-\(key)").waitForExistence(timeout: 20), "no Buy more")
        XCTAssertTrue(waitUntilSynced(app))
        settled(revealOnWanted(app, "wanted-buy-\(key)")).click()
        XCTAssertTrue(waitUntil { (try? self.storedSharing(game: "riftbound")) == [key: false] },
                      "\(String(describing: try? storedSharing(game: "riftbound")))")
        let cell = app.buttons["wanted-cell-\(key)"]
        XCTAssertTrue(waitUntil { !self.element(app, "wanted-pending-\(key)").exists }, "the pending row stayed")
        XCTAssertTrue(cell.label.hasPrefix("Kai'Sa, Rebel, ×2, 2 for decks, "), cell.label)
        XCTAssertFalse(element(app, "wanted-decisions").exists, "Decisions stays with nothing pending")
        XCTAssertEqual(text(element(app, "sidebar-deck-missing-rb2")), "2")
    }

    /// E7: three pending cards: "Decisions (3)…" opens the sheet with three rows by name and Done off; Cancel writes
    /// nothing. Again: "Share all", Done: one write with the three answers, none pending (no row, no Decisions button).
    func testTheSharingSheetDecidesAll() throws {
        let app = try launch(game: "cyberpunk", extra: ["-screen", "wanted"]) { _ in
            try self.writeUserFile(game: "cyberpunk", json: Self.threePending)
        }
        let decisions = element(app, "wanted-decisions")
        XCTAssertTrue(decisions.waitForExistence(timeout: 20), "no Decisions button")
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { decisions.label == "Decisions (3)…" }, decisions.label)
        assertInWindow(app, decisions)
        let before = try XCTUnwrap(root).appending(path: "user/cyberpunk.json")
        let bytes = try Data(contentsOf: before)

        decisions.click()
        let sheet = element(app, "sharing-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no sharing sheet")
        XCTAssertEqual(identifiersInOrder(app, ElementMatch(.any, "identifier BEGINSWITH 'sharing-row-'")), ["sharing-row-jackie welles ride or die choom",
                                                 "sharing-row-kerry eurodyne the last rockerboy",
                                                 "sharing-row-satori sword of saburo"])
        let done = element(app, "sharing-done"), cancel = element(app, "sharing-cancel")
        XCTAssertFalse(done.isEnabled, "Done is on with no choice")
        for id in ["sharing-share-all", "sharing-buy-all", "sharing-cancel", "sharing-done",
                   "sharing-choice-satori sword of saburo"] {
            XCTAssertTrue(element(app, id).isHittable, "\(id) is not hittable")
        }
        shot("decks-52-sharing-sheet", of: sheet)
        cancel.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "Cancel did not close the sheet")
        XCTAssertEqual(try Data(contentsOf: before), bytes, "Cancel wrote the file")
        XCTAssertEqual(decisions.label, "Decisions (3)…")

        decisions.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no sharing sheet the second time")
        element(app, "sharing-share-all").click()
        XCTAssertTrue(waitUntil { done.isEnabled }, "Done stays off after Share all")
        shot("decks-53-sharing-sheet-share-all", of: sheet)
        done.click()
        XCTAssertTrue(waitUntil { !sheet.exists }, "Done did not close the sheet")
        XCTAssertTrue(waitUntil { (try? self.storedSharing(game: "cyberpunk")) == ["jackie welles ride or die choom": true,
                                                                                  "kerry eurodyne the last rockerboy": true,
                                                                                  "satori sword of saburo": true] },
                      "\(String(describing: try? storedSharing(game: "cyberpunk")))")
        XCTAssertTrue(waitUntil { !decisions.exists }, "Decisions stays with nothing pending")
        let pendingRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'wanted-pending-'"))
        XCTAssertEqual(pendingRows.count, 0, "a pending row stayed")
        shot("decks-54-wanted-after-share-all")
    }

    /// E7: Kai'Sa shared between Wind and Cheap (2 owned, each uses 2): not on Wanted. Its card page (from the deck's cell)
    /// says "Shared between decks" with "Change"; "Change" → "Bought for each deck" and the file has `false`; Wanted lists
    /// it again (`2 for decks`).
    func testTheCardPageChangesTheAnswer() throws {
        let shared = Self.twoDecksOneKaisa.replacingOccurrences(of: "{\"version\": 1,",
                                                                  with: "{\"version\": 1, \"sharing\": [{\"cardKey\": \"kai sa rebel\", \"shared\": true}],")
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb2"]) { _ in
            try self.writeUserFile(game: "riftbound", json: shared)
        }
        let key = "kai sa rebel"
        let cell = element(app, "deck-cell-\(key)-main")
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "no deck cell")
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertFalse(element(app, "sidebar-deck-missing-rb2").exists, "a shared card leaves the second deck short")
        cell.click()
        let line = settled(revealOnCardPage(app, "card-sharing-change"))
        let sharing = element(app, "card-sharing")
        XCTAssertEqual(text(sharing), "Shared between decks")
        XCTAssertEqual(line.label, "Change")
        assertInWindow(app, line)
        shot("decks-55-card-page-shared")
        line.click()
        XCTAssertTrue(waitUntil { self.text(sharing) == "Bought for each deck" }, text(sharing))
        XCTAssertTrue(waitUntil { (try? self.storedSharing(game: "riftbound")) == [key: false] },
                      "\(String(describing: try? storedSharing(game: "riftbound")))")
        assertInWindow(app, element(app, "card-sharing-change"))
        shot("decks-56-card-page-each")

        element(app, "sidebar-wanted").click()
        let wanted = app.buttons["wanted-cell-\(key)"]
        XCTAssertTrue(wanted.waitForExistence(timeout: 10), "the card is not on Wanted again")
        XCTAssertTrue(waitUntil { wanted.label.hasPrefix("Kai'Sa, Rebel, ×2, 2 for decks, ") }, wanted.label)
        XCTAssertFalse(element(app, "wanted-pending-\(key)").exists, "an answered card is pending")
    }

    /// A22, E8: Wind uses Kai'Sa ×2, 2 owned; Cheap is active and empty. `+` in Cheap's search adds one Kai'Sa: no dialog
    /// opens, and the status line says "1 card needs a sharing decision."; the card page's line is "Decision pending".
    func testAddingACardSaysADecisionIsNeeded() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb2"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1,
             "collection": [{"productID": 721337, "finish": "Normal", "count": 2, "condition": "", "name": "Kai'Sa, Rebel"}],
             "decks": [{"id": "rb1", "name": "Wind", "format": "standard", "active": true,
                        "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2}]},
                       {"id": "rb2", "name": "Cheap", "format": "standard", "active": true, "cards": []}]}
            """)
        }
        let key = "kai sa rebel"
        XCTAssertTrue(element(app, "deck-empty-add-cards").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        let status = app.staticTexts["status-line"]
        XCTAssertFalse(text(status).contains("sharing decision"), text(status))
        openSearch(app, button: "deck-empty-add-cards", text: "kai", cardKey: key)
        element(app, "deck-add-plus-\(key)").click()
        XCTAssertTrue(waitUntil { self.text(status) == "1 card needs a sharing decision." }, text(status))
        XCTAssertEqual(app.sheets.count, 0, "a dialog opened")
        XCTAssertFalse(element(app, "sharing-sheet").exists, "the sharing sheet opened")
        shot("decks-57-status-decision-needed")

        element(app, "card-cell-\(key)").click()
        let pending = settled(revealOnCardPage(app, "card-sharing-buy"))
        XCTAssertEqual(text(element(app, "card-sharing")), "Decision pending")
        assertInWindow(app, pending)
        assertInWindow(app, element(app, "card-sharing-share"))
        shot("decks-58-card-page-pending")
        XCTAssertEqual(try storedSharing(game: "riftbound"), [:], "the app answered for the user")
    }

    // MARK: The list view (phase 6A feedback 1, A57, A58)

    /// Two Riftbound decks: rb1 with Kai'Sa ×2 (1 owned: 1 missing), Dockside Lock-Up ×1 (3 owned) and Calm Rune ×12 (basic,
    /// none owned); rb9 with Dockside Lock-Up ×1.
    private static let listDecks = """
        {"version": 1,
         "collection": [{"productID": 721337, "finish": "Normal", "count": 1, "condition": "", "name": "Kai'Sa, Rebel"},
                        {"productID": 721334, "finish": "Normal", "count": 3, "condition": "", "name": "Dockside Lock-Up"}],
         "decks": [{"id": "rb1", "name": "Kai'Sa", "format": "standard", "active": false,
                    "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 2},
                              {"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 1},
                              {"cardKey": "calm rune", "name": "Calm Rune", "section": "runes", "count": 12}]},
                   {"id": "rb9", "name": "Second", "format": "standard", "active": false,
                    "cards": [{"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 1}]}]}
        """

    /// A deck card's element is a list row (one line, 44 pt tall, across the column), not a gallery cell (a picture over
    /// its texts, 150 pt wide at least).
    private func isRow(_ element: XCUIElement) -> Bool {
        element.exists && element.frame.height < 60 && element.frame.width > 250
    }

    private func isCell(_ element: XCUIElement) -> Bool {
        element.exists && element.frame.height > 150
    }

    /// A segment of the toolbar's `deck-view` control ("gallery" or "list"), by its identifier (XCUITest finds the
    /// segments' identifiers on macOS 27; asserted here, with no fallback by name).
    private func viewSegment(_ app: XCUIApplication, _ mode: String,
                             file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let byID = element(app, "deck-view-\(mode)")
        XCTAssertTrue(byID.waitForExistence(timeout: 5), "no deck-view-\(mode) segment", file: file, line: line)
        return byID
    }

    private func userFileData(game: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(root).appending(path: "user/\(game).json"))
    }

    /// A57, A58, Review Focus 1, 2 and 5: the toolbar's switch shows the deck as a list: each card one row with the
    /// gallery's label; two fast `+` both count; a row's card page and Back keep the list; the search text stays across a
    /// switch; another deck and a relaunch show the list; the switch itself writes nothing to the user folder.
    func testTheDeckListView() throws {
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb1"]) { _ in
            try self.writeUserFile(game: "riftbound", json: Self.listDecks)
        }
        let kaisaID = "deck-cell-kai sa rebel-main"
        let kaisa = element(app, kaisaID)
        XCTAssertTrue(kaisa.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        XCTAssertTrue(waitUntil { kaisa.label.hasPrefix("Kai'Sa, Rebel, ×2 · 1 missing, ") }, kaisa.label)
        XCTAssertTrue(isCell(kaisa), "the first time is not the gallery: \(kaisa.frame)")
        let galleryLabel = kaisa.label
        let dockside = reveal(app, "deck-cell-dockside lock up-main")
        let docksideLabel = dockside.label
        let rune = reveal(app, "deck-cell-calm rune-runes")
        let runeLabel = rune.label
        let before = try userFileData(game: "riftbound")

        XCTAssertTrue(element(app, "deck-view").exists, "no deck-view control")
        viewSegment(app, "list").click()
        XCTAssertTrue(waitUntil { self.isRow(kaisa) }, "Kai'Sa is no row: \(kaisa.frame)")
        XCTAssertEqual(kaisa.label, galleryLabel)
        XCTAssertTrue(kaisa.label.contains("×2 · 1 missing"), kaisa.label)
        XCTAssertEqual(reveal(app, "deck-cell-dockside lock up-main").label, docksideLabel)
        let runeRow = reveal(app, "deck-cell-calm rune-runes")
        XCTAssertTrue(isRow(runeRow), "the rune is no row: \(runeRow.frame)")
        XCTAssertEqual(runeRow.label, runeLabel)                    // basic: never missing
        XCTAssertFalse(runeRow.label.contains("missing"), runeRow.label)
        XCTAssertEqual(try userFileData(game: "riftbound"), before, "the switch wrote the user folder")

        // Review Focus 1: two fast clicks on a row's `+` both count.
        let plus = reveal(app, "deck-cell-plus-kai sa rebel-main")
        plus.click()
        plus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-cell-value-kai sa rebel-main")) == "4" })
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards
                == ["kai sa rebel|main|4", "dockside lock up|main|1", "calm rune|runes|12"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
        XCTAssertTrue(waitUntil { kaisa.label.hasPrefix("Kai'Sa, Rebel, ×4 · 3 missing, ") }, kaisa.label)
        let screen = element(app, "deck-screen")
        for _ in 0..<6 { screen.scroll(byDeltaX: 0, deltaY: 200) }  // back to the top: Kai'Sa's row in the picture
        shot("decks-list-01")

        // Review Focus 2: a row's card page, then Back: still the list.
        reveal(app, kaisaID).click()
        let page = element(app, "card-page")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "a list row opens no card page")
        XCTAssertEqual(text(element(app, "card-title")), "Kai'Sa, Rebel")
        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(waitUntil { !page.exists }, "Back left the card page")
        XCTAssertTrue(waitUntil { self.isRow(kaisa) }, "Back left the list: \(kaisa.frame)")

        // The search text stays across a switch.
        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("dock")
        XCTAssertTrue(waitUntil { !kaisa.exists }, "the search shows Kai'Sa")
        viewSegment(app, "gallery").click()
        let docksideCell = element(app, "deck-cell-dockside lock up-main")
        XCTAssertTrue(waitUntil { self.isCell(docksideCell) }, "no gallery: \(docksideCell.frame)")
        XCTAssertEqual(search.value as? String, "dock")
        XCTAssertFalse(kaisa.exists, "the switch dropped the search")
        viewSegment(app, "list").click()
        XCTAssertTrue(waitUntil { self.isRow(docksideCell) }, "no list: \(docksideCell.frame)")
        XCTAssertEqual(search.value as? String, "dock")

        // Review Focus 5: one choice for every deck.
        element(app, "sidebar-deck-rb9").click()
        XCTAssertTrue(waitUntil { self.title.hasPrefix("Second") }, title)
        let second = element(app, "deck-cell-dockside lock up-main")
        XCTAssertTrue(waitUntil { self.isRow(second) }, "the second deck is no list: \(second.frame)")
        let after = try userFileData(game: "riftbound")

        quit(app)
        XCTAssertEqual(try userFileData(game: "riftbound"), after)
        app.launch()                                             // the same root and flags: deck rb1
        let again = element(app, kaisaID)
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.isRow(again) }, "the relaunch is no list: \(again.frame)")
        XCTAssertEqual(try userFileData(game: "riftbound"), after, "the relaunch wrote the user folder")
        shot("decks-list-02-after-relaunch")
    }

    /// Review Focus 3: a 60-character card name truncates inside its row; the price column and the row's `+` stay whole
    /// and inside the 900 pt window.
    func testALongNameInTheDeckList() throws {
        let long = "Vanished Cards of the Extraordinarily Long Riftbound Archive"
        XCTAssertEqual(long.count, 60)
        // 60 characters fit the Mac's row at 900 pt; this one does not, so its name is cut.
        let longer = String(repeating: "Extraordinarily Long Name ", count: 5)
        XCTAssertEqual(longer.count, 130)
        let app = try launch(game: "riftbound", extra: ["-screen", "deck:rb2"]) { _ in
            try self.writeUserFile(game: "riftbound", json: """
            {"version": 1,
             "decks": [{"id": "rb2", "name": "Long", "format": "standard", "active": false,
                        "cards": [{"cardKey": "kai sa rebel", "name": "Kai'Sa, Rebel", "section": "main", "count": 1},
                                  {"cardKey": "vanished long", "name": "\(long)", "section": "main", "count": 1},
                                  {"cardKey": "vanished longer", "name": "\(longer)", "section": "main", "count": 1}]}]}
            """)
        }
        XCTAssertTrue(element(app, "deck-cell-kai sa rebel-main").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSynced(app))
        viewSegment(app, "list").click()
        let row = reveal(app, "deck-cell-vanished long-main")
        XCTAssertTrue(waitUntil { self.isRow(row) }, "no list row: \(row.frame)")
        XCTAssertEqual(row.label, "\(long), ×1, no price")
        let plus = reveal(app, "deck-cell-plus-vanished long-main")
        assertInWindow(app, row)
        assertInWindow(app, plus)
        assertInWindow(app, reveal(app, "deck-cell-minus-vanished long-main"))
        XCTAssertLessThanOrEqual(row.frame.maxX, plus.frame.minX, "the row runs under its control")
        XCTAssertEqual(row.frame.height, 44, accuracy: 2)
        let kaisa = reveal(app, "deck-cell-kai sa rebel-main")
        XCTAssertEqual(kaisa.frame.maxX, row.frame.maxX, accuracy: 1, "the rows' price columns do not line up")
        let cut = reveal(app, "deck-cell-vanished longer-main"), cutPlus = reveal(app, "deck-cell-plus-vanished longer-main")
        assertInWindow(app, cut)
        assertInWindow(app, cutPlus)
        XCTAssertEqual(cut.frame.height, 44, accuracy: 2)
        XCTAssertEqual(cut.frame.maxX, row.frame.maxX, accuracy: 1, "a cut name pushes the price column")
        XCTAssertLessThanOrEqual(cut.frame.maxX, cutPlus.frame.minX)
        shot("decks-list-03-long-name")
    }

    /// Review Focus 4, D13: a card the settled catalog does not have, in the list: its saved name, no price, no
    /// "missing", no link; its control works.
    func testAPendingCardInTheDeckList() throws {
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
        viewSegment(app, "list").click()
        let gone = reveal(app, "deck-cell-vanished card-main")
        XCTAssertTrue(waitUntil { self.isRow(gone) }, "no list row: \(gone.frame)")
        XCTAssertTrue(waitUntil { gone.label == "Vanished Card, ×1, no price" }, gone.label)
        shot("decks-list-04-card-not-in-the-catalog")
        gone.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(element(app, "card-page").exists, "a deck card without a printing opened a page")
        reveal(app, "deck-cell-plus-vanished card-main").click()
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards
                == ["kai sa rebel|main|1", "vanished card|main|2"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
        let minus = reveal(app, "deck-cell-minus-vanished card-main")
        minus.click()
        XCTAssertTrue(waitUntil { self.text(self.element(app, "deck-cell-value-vanished card-main")) == "1" })
        reveal(app, "deck-cell-minus-vanished card-main").click()
        XCTAssertTrue(waitUntil { !gone.exists }, "− left the card")
        XCTAssertTrue(waitUntil { (try? self.storedDecks(game: "riftbound"))?.first?.cards == ["kai sa rebel|main|1"] },
                      "\(String(describing: try? storedDecks(game: "riftbound")))")
    }
}
