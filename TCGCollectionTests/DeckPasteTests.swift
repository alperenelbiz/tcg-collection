import Foundation
import Testing
@testable import TCGCollection2

/// A pasted deck's lines matched with the catalog (phase 3A task 7): sections, default sections, unknown names with their
/// nearest names, the cards a paste saves and its summary.
struct DeckPasteTests {
    private let magic = Games.game("magic-the-gathering")!
    private let yugioh = Games.game("yu-gi-oh")!
    private let riftbound = Games.game("riftbound")!
    private let cyberpunk = Games.game("cyberpunk")!

    private var commander: DeckFormat { magic.format("commander") }

    /// The catalog of a test: card names, each with its type text, found by search key (the model also tries the base
    /// name; that step is `DeckPaste.keys`).
    private func known(_ game: GameDefinition, _ cards: [(name: String, type: String)])
        -> (String) -> (cardKey: String, name: String, kind: CardKind)? {
        let table = Dictionary(cards.map { (CardName.searchKey($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        return { name in
            table[CardName.searchKey(name)].map { (CardName.searchKey($0.name), $0.name, game.kind(cardType: $0.type, ygoType: nil)) }
        }
    }

    private var ygoCards: [(name: String, type: String)] {
        [("Swiftwind Panther Warrior", "Effect Monster"), ("Stardust Dragon", "Synchro Monster"),
         ("Token: Joey and Red-Eyes Black Dragon", "Token")]
    }

    private var magicCards: [(name: String, type: String)] {
        [("Ajani Resolute", "Legendary Creature — Cat Warrior"), ("Bloodline Recollector", "Creature — Vampire"),
         ("Chandra, Chill of Compliance", "Legendary Planeswalker — Chandra"), ("Stingcaster Mage", "Creature — Faerie Wizard"),
         ("Fire // Ice", "Instant // Instant")]
    }

    private func lines(_ text: String, game: GameDefinition, format: DeckFormat? = nil,
                       cards: [(name: String, type: String)], suggest: @escaping (String) -> [Suggestion] = { _ in [] })
        -> [PastedLine] {
        DeckPaste.lines(DeckText.parse(text), format: format ?? game.formats[0], known: known(game, cards), suggest: suggest,
                        game: game)
    }

    // MARK: Sections

    /// The format's section names and ids, ignoring case, spaces and punctuation, and the old app's names.
    @Test func sectionIDsByNameIDAndAlias() {
        let standard = yugioh.formats[0], constructed = magic.format("constructed")
        for (name, id) in [("Main Deck", "main"), ("main", "main"), ("MAIN-DECK", "main"), ("Deck", "main"), ("Extra", "extra"),
                           ("extra deck", "extra"), ("Side", "side"), ("Side Deck", "side"), ("Sideboard", "side")] {
            #expect(DeckPaste.sectionID(named: name, in: standard) == id, "\(name)")
        }
        #expect(DeckPaste.sectionID(named: "Commander", in: standard) == nil)
        #expect(DeckPaste.sectionID(named: "Maybeboard", in: standard) == nil)
        #expect(DeckPaste.sectionID(named: "", in: standard) == nil)
        for (name, id) in [("Commander", "commander"), ("Deck", "deck"), ("Main", "deck"), ("Main Deck", "deck")] {
            #expect(DeckPaste.sectionID(named: name, in: commander) == id, "\(name)")
        }
        #expect(DeckPaste.sectionID(named: "Sideboard", in: commander) == nil)
        #expect(DeckPaste.sectionID(named: "Side", in: constructed) == "sideboard")
        #expect(DeckPaste.sectionID(named: "Side Deck", in: constructed) == "sideboard")
        let rift = riftbound.formats[0]
        for (name, id) in [("Legend", "legend"), ("Legends", "legend"), ("Champion", "champion"), ("Main Deck", "main"),
                           ("Rune", "runes"), ("Runes", "runes"), ("Battlefield", "battlefields"), ("Battlefields", "battlefields"),
                           ("Sideboard", "sideboard"), ("Side Deck", "sideboard")] {
            #expect(DeckPaste.sectionID(named: name, in: rift) == id, "\(name)")
        }
        #expect(DeckPaste.sectionID(named: "Legend", in: cyberpunk.formats[0]) == "legends")
        #expect(DeckPaste.sectionID(named: "Side Deck", in: cyberpunk.formats[0]) == "side")
    }

    // MARK: Matching

    @Test func aKnownNameMatchesBySearchKey() {
        let shown = lines("Main Deck:\n3 swiftwind  PANTHER warrior", game: yugioh, cards: ygoCards)
        #expect(shown == [PastedLine(number: 2, text: "swiftwind  PANTHER warrior", count: 3,
                                     match: .card(cardKey: "swiftwind panther warrior", name: "Swiftwind Panther Warrior"),
                                     section: "main", note: nil)])
    }

    /// The exact key of the whole name first, then the key of its base name (a bracket, a set code).
    @Test func theKeysOfANameExactFirstThenItsBase() {
        #expect(DeckPaste.keys(for: "Calm Rune (R02a)", game: riftbound) == ["calm rune r02a", "calm rune"])
        #expect(DeckPaste.keys(for: "Lightning Bolt [M10]", game: magic) == ["lightning bolt m10", "lightning bolt"])
        #expect(DeckPaste.keys(for: "Fire // Ice", game: magic) == ["fire ice"])
        #expect(DeckPaste.keys(for: "  ", game: magic) == [])
    }

    @Test func aCardWithNoSectionLineGoesToItsDefaultSection() {
        let shown = lines("2 Stardust Dragon\n1 Swiftwind Panther Warrior", game: yugioh, cards: ygoCards)
        #expect(shown.map(\.section) == ["extra", "main"])
        #expect(shown.allSatisfy { $0.note == nil })
    }

    @Test func aSectionTheFormatLacksSendsItsCardsToTheirDefaultSectionAndSaysSo() {
        let shown = lines("Sideboard:\n1 Bloodline Recollector", game: magic, format: commander, cards: magicCards)
        #expect(shown.map(\.section) == ["deck"])
        #expect(shown.map(\.note) == ["no section Sideboard in Commander"])
    }

    /// The Side Deck, Sideboard, Commander and Champion are by hand only: the text is the hand, so its cards stay there.
    @Test func sideLinesStayInTheSideSection() {
        #expect(lines("Side Deck:\n2 Stardust Dragon\nSideboard:\n1 Swiftwind Panther Warrior", game: yugioh, cards: ygoCards)
            .map(\.section) == ["side", "side"])
        #expect(lines("Commander:\n1 Ajani Resolute\nDeck:\n1 Stingcaster Mage", game: magic, format: commander,
                      cards: magicCards).map(\.section) == ["commander", "deck"])
        #expect(lines("Champion:\n1 Kai'Sa, Rebel", game: riftbound, cards: [("Kai'Sa, Rebel", "Champion Unit")])
            .map(\.section) == ["champion"])
        // Not named: a Champion Unit goes to the Main Deck.
        #expect(lines("1 Kai'Sa, Rebel", game: riftbound, cards: [("Kai'Sa, Rebel", "Champion Unit")]).map(\.section) == ["main"])
    }

    /// `Ash Blosom`: up to 5 suggestions, nearest first; the unknown line goes where a card of unknown kind goes.
    @Test func anUnknownNameGetsUpToFiveSuggestionsNearestFirst() {
        let names = ["Ash Hound", "Ash Blossom & Joyous Spring", "Ash Barrage", "Blossom Bombardment", "Ashened Firebrand",
                     "Ash Zealot", "Ashnod's Altar", "Mistblossom"]
        let candidates = names.map { Suggestion(cardKey: CardName.searchKey($0), name: $0) }
        let shown = lines("1 Ash Blosom", game: yugioh, cards: ygoCards) { DeckPaste.nearest($0, among: candidates, limit: 5) }
        guard case .unknown(let suggestions)? = shown.first?.match else {
            Issue.record("not unknown: \(shown)")
            return
        }
        #expect(suggestions.count == 5)
        #expect(suggestions.first?.name == "Ash Blossom & Joyous Spring")
        #expect(shown.first?.section == "main")
        #expect(DeckPaste.nearest("", among: candidates, limit: 5).isEmpty)
        #expect(DeckPaste.nearest("Ash Blosom", among: candidates, limit: 0).isEmpty)
        // One per card key; equal distances by name.
        let twice = DeckPaste.nearest("Cat", among: [Suggestion(cardKey: "cot", name: "Cot"), Suggestion(cardKey: "bat", name: "Bat"),
                                                     Suggestion(cardKey: "bat", name: "Bat")], limit: 5)
        #expect(twice.map(\.name) == ["Bat", "Cot"])
    }

    @Test func theSameCardOnTwoLinesIsShownTwiceAndSummedByCards() {
        let shown = lines("Deck:\n1 Bloodline Recollector\n2 Bloodline Recollector\nCommander:\n1 Bloodline Recollector",
                          game: magic, format: commander, cards: magicCards)
        #expect(shown.map(\.number) == [2, 3, 5])
        #expect(DeckPaste.cards(shown) == [
            DeckCard(cardKey: "bloodline recollector", name: "Bloodline Recollector", section: "deck", count: 3),
            DeckCard(cardKey: "bloodline recollector", name: "Bloodline Recollector", section: "commander", count: 1),
        ])
    }

    @Test func aDroppedLineIsNotInCards() {
        var shown = lines("1 Stingcaster Mage\n2 Bloodline Recollector\n0 Ajani Resolute", game: magic, format: commander,
                          cards: magicCards)
        #expect(shown[2].match == .dropped && shown[2].note == "0 copies")
        shown[0].match = .dropped
        #expect(DeckPaste.cards(shown) == [DeckCard(cardKey: "bloodline recollector", name: "Bloodline Recollector",
                                                    section: "deck", count: 2)])
    }

    /// A count over 999 is shown as written and saved as 999, with a note; two lines of one card sum to 999 at most.
    @Test func aCountOver999IsShownAndSavedAs999() {
        let shown = lines("1200 Stingcaster Mage\n600 Bloodline Recollector\n600 Bloodline Recollector", game: magic,
                          format: commander, cards: magicCards)
        #expect(shown.map(\.count) == [1200, 600, 600])
        #expect(shown.map(\.note) == ["saved as 999", nil, nil])
        #expect(DeckPaste.cards(shown).map(\.count) == [999, 999])
    }

    @Test func anUnreadableLineIsShownDropped() {
        let shown = lines("Ajani Resolute\n1 Stingcaster Mage", game: magic, format: commander, cards: magicCards)
        #expect(shown.first == PastedLine(number: 1, text: "Ajani Resolute", count: 0, match: .dropped, section: "", note: "no count"))
        #expect(DeckPaste.cards(shown).count == 1)
    }

    @Test func theSummary() {
        let card = { (n: Int, count: Int) in
            PastedLine(number: n, text: "Card \(n)", count: count, match: .card(cardKey: "card \(n)", name: "Card \(n)"),
                       section: "main", note: nil)
        }
        let unknown = { (n: Int) in PastedLine(number: n, text: "X", count: 1, match: .unknown(suggestions: []), section: "main", note: nil) }
        let lines = (1...27).map { card($0, 2) } + (28...31).map { card($0, 1) } + [unknown(32), unknown(33)]
        #expect(DeckPaste.summary(lines) == "58 cards on 31 lines, 2 lines not recognised")
        #expect(DeckPaste.summary([card(1, 1)]) == "1 card on 1 line")
        var dropped = card(2, 3)
        dropped.match = .dropped
        #expect(DeckPaste.summary([card(1, 1), unknown(3), dropped]) == "1 card on 1 line, 1 line not recognised, 1 line dropped")
        #expect(DeckPaste.summary([]) == "0 cards on 0 lines")
        #expect(DeckPaste.unknownCount([card(1, 1), unknown(3), unknown(4), dropped]) == 2)
    }

    /// Review Focus 3: a Commander list of 100 card lines with unknown names, one card on two lines, a `//` split name, an
    /// accented name, a section the format lacks, a count of 0 and of 500, a tab, `4x`, and a line without a count: every
    /// card line and the unreadable line are shown, with their numbers, before anything is saved.
    @Test func theOddListShowsEveryLine() throws {
        let text = try #require(String(data: try fixture("deck-odd.txt"), encoding: .utf8))
        let candidates = magicCards.map { Suggestion(cardKey: CardName.searchKey($0.name), name: $0.name) }
        let shown = lines(text, game: magic, format: commander, cards: magicCards) {
            DeckPaste.nearest($0, among: candidates, limit: 5)
        }
        #expect(shown.map(\.number) == [3] + Array(6...104) + [107])
        func line(_ n: Int) -> PastedLine? { shown.first { $0.number == n } }
        #expect(line(3)?.section == "commander")
        #expect(line(6)?.match == .card(cardKey: "bloodline recollector", name: "Bloodline Recollector"))
        #expect(line(7)?.match == line(6)?.match)
        #expect(line(8)?.match == .card(cardKey: "fire ice", name: "Fire // Ice"))
        #expect(line(9)?.match == .card(cardKey: "chandra chill of compliance", name: "Chandra, Chill of Compliance"))
        #expect(line(9)?.text == "Chándra, Chill of Compliance")
        #expect(line(10)?.count == 1 && line(11)?.count == 4 && line(13)?.count == 500)
        #expect(line(12)?.match == .dropped && line(12)?.note == "0 copies")
        #expect(line(13)?.note == nil)
        #expect(line(15) == PastedLine(number: 15, text: "Ajani Resolute", count: 0, match: .dropped, section: "", note: "no count"))
        if case .unknown(let suggestions)? = line(16)?.match { #expect(!suggestions.isEmpty && suggestions.count <= 5) } else {
            Issue.record("line 16 is not unknown")
        }
        #expect(line(107)?.section == "deck" && line(107)?.note == "no section Maybeboard in Commander")
        #expect(DeckPaste.cards(shown) == [
            DeckCard(cardKey: "ajani resolute", name: "Ajani Resolute", section: "commander", count: 1),
            DeckCard(cardKey: "bloodline recollector", name: "Bloodline Recollector", section: "deck", count: 3),
            DeckCard(cardKey: "fire ice", name: "Fire // Ice", section: "deck", count: 1),
            DeckCard(cardKey: "chandra chill of compliance", name: "Chandra, Chill of Compliance", section: "deck", count: 1),
            DeckCard(cardKey: "stingcaster mage", name: "Stingcaster Mage", section: "deck", count: 505),
        ])
        #expect(DeckPaste.summary(shown) == "511 cards on 9 lines, 90 lines not recognised, 2 lines dropped")
    }
}
