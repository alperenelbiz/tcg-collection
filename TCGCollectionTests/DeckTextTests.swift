import Foundation
import Testing
@testable import TCGCollection2

/// The text of a pasted deck (phase 3A task 7): the old app's `DeckFile` format, `Section:` lines, `N Card name` lines,
/// `#` notes and blank lines, read line by line with each line's number.
struct DeckTextTests {
    private func text(_ name: String) throws -> String {
        try #require(String(data: try fixture(name), encoding: .utf8))
    }

    private func kinds(_ text: String) -> [DeckTextLine.Kind] {
        DeckText.parse(text).map(\.kind)
    }

    @Test func sectionsCardsAndNotesWithTheirLineNumbers() throws {
        let lines = DeckText.parse(try text("deck-yugioh.txt"))
        #expect(lines.map(\.number) == Array(1...9))
        #expect(lines.map(\.kind) == [
            .note,
            .section("Main Deck"),
            .card(count: 3, name: "Swiftwind Panther Warrior"),
            .note,
            .section("Extra Deck"),
            .card(count: 2, name: "Stardust Dragon"),
            .note,
            .section("Side Deck"),
            .card(count: 1, name: "Token: Joey and Red-Eyes Black Dragon"),
        ])
    }

    /// A `//` split name and an accented name are kept as written; a section the format may lack is still a section.
    @Test func aSplitNameAndAnAccentedNameAreKept() throws {
        let lines = DeckText.parse(try text("deck-commander.txt"))
        let cards = lines.compactMap { line -> String? in
            if case .card(_, let name) = line.kind { name } else { nil }
        }
        #expect(cards == ["Ajani Resolute", "Chándra, Chill of Compliance", "Bloodline Recollector",
                          "Stingcaster Mage (Borderless) (0329)", "Fire // Ice", "Bloodline Recollector"])
        #expect(lines.compactMap { if case .section(let name) = $0.kind { name } else { nil } }
                == ["Commander", "Deck", "Sideboard"])
    }

    @Test func countsAndNamesInEveryForm() {
        #expect(kinds("3 7 Colored Fish") == [.card(count: 3, name: "7 Colored Fish")])
        #expect(kinds("1\tStingcaster Mage") == [.card(count: 1, name: "Stingcaster Mage")])
        #expect(kinds("4x Stingcaster Mage") == [.card(count: 4, name: "Stingcaster Mage")])
        #expect(kinds("4X Stingcaster Mage") == [.card(count: 4, name: "Stingcaster Mage")])
        #expect(kinds("  2   Calm Rune  ") == [.card(count: 2, name: "Calm Rune")])
        #expect(kinds("3 Xyz Dragon") == [.card(count: 3, name: "Xyz Dragon")])
        // Kept as written: the sheet marks 0 as dropped, and caps nothing here.
        #expect(kinds("0 Bloodline Recollector") == [.card(count: 0, name: "Bloodline Recollector")])
        #expect(kinds("500 Stingcaster Mage") == [.card(count: 500, name: "Stingcaster Mage")])
    }

    /// A non-empty line that is no section, no card and no note is never read as one copy.
    @Test func aLineWithoutACountIsUnreadable() {
        #expect(kinds("Ajani Resolute") == [.unreadable("Ajani Resolute")])
        #expect(kinds("4") == [.unreadable("4")])
        #expect(kinds("4x") == [.unreadable("4x")])
        #expect(kinds("x4 Card") == [.unreadable("x4 Card")])
        #expect(kinds("99999999999999999999999 Card") == [.unreadable("99999999999999999999999 Card")])
    }

    @Test func notesAndBlankLines() {
        #expect(kinds("# a note\n\n   \n#Main Deck:") == [.note, .note, .note, .note])
        #expect(kinds(" Main Deck : ") == [.section("Main Deck")])
    }

    /// Windows and old Mac line ends; a last line end adds no line.
    @Test func lineEnds() {
        let lines = DeckText.parse("Main Deck:\r\n3 Swiftwind Panther Warrior\r\n\r\n1 Stardust Dragon\r2 Calm Rune\n")
        #expect(lines.map(\.number) == [1, 2, 3, 4, 5])
        #expect(lines.map(\.kind) == [.section("Main Deck"), .card(count: 3, name: "Swiftwind Panther Warrior"), .note,
                                      .card(count: 1, name: "Stardust Dragon"), .card(count: 2, name: "Calm Rune")])
        #expect(DeckText.parse("").isEmpty)
    }

    /// Review Focus 3: every line of the odd list has its line number and kind.
    @Test func theOddListReadsEveryLine() throws {
        let lines = DeckText.parse(try text("deck-odd.txt"))
        #expect(lines.count == 108)
        #expect(lines.filter { if case .card = $0.kind { true } else { false } }.count == 100)
        #expect(lines[9].kind == .card(count: 1, name: "Stingcaster Mage"))         // line 10: a tab
        #expect(lines[14] == DeckTextLine(number: 15, kind: .unreadable("Ajani Resolute")))
        #expect(lines[105].kind == .section("Maybeboard"))
    }
}
