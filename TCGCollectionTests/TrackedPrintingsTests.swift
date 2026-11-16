import Testing
@testable import TCGCollection2

struct TrackedPrintingsTests {
    private func row(_ productID: Int, count: Int = 1) -> CollectionRow {
        CollectionRow(productID: productID, finish: "Normal", count: count, condition: "", name: "Card")
    }

    private func sale(_ productID: Int, count: Int = 1) -> SaleEntry {
        SaleEntry(productID: productID, finish: "Normal", count: count, name: "Card")
    }

    private func wanted(_ cardKey: String, pin: Int? = nil) -> WantedEntry {
        WantedEntry(cardKey: cardKey, name: cardKey, count: 1, pinProductID: pin, pinFinish: pin.map { _ in "Foil" })
    }

    private func deck(_ cards: [(String, String)]) -> Deck {
        Deck(id: "d1", name: "Deck", format: "standard", active: false,
             cards: cards.map { DeckCard(cardKey: $0.0, name: $0.0, section: $0.1, count: 2) })
    }

    private func ids(collection: [CollectionRow] = [], forSale: [SaleEntry] = [], wanted: [WantedEntry] = [],
                     decks: [Deck] = [], printingsByCard: [String: [Int]] = [:]) -> Set<Int> {
        TrackedPrintings.productIDs(collection: collection, forSale: forSale, wanted: wanted,
                                    printingsByCard: printingsByCard,
                                    cardKeys: TrackedPrintings.cardKeys(wanted: wanted, decks: decks))
    }

    @Test func anOwnedRowAndAForSaleEntryCount() {
        #expect(ids(collection: [row(1)], forSale: [sale(2)]) == [1, 2])
    }

    @Test func aRowWithCountZeroDoesNot() {
        #expect(ids(collection: [row(1, count: 0)], forSale: [sale(2, count: 0)]).isEmpty)
    }

    @Test func aPinCountsAlsoWhenItsCardHasNoPrintingInTheMap() {
        #expect(ids(wanted: [wanted("bolt", pin: 9)]) == [9])
        #expect(ids(wanted: [wanted("bolt", pin: 9)], printingsByCard: ["bolt": [3, 4]]) == [3, 4, 9])
    }

    @Test func aWantedCardAndADeckCardBringEveryProductOfTheirKey() {
        let map = ["bolt": [3, 4], "mist": [5], "other": [6]]
        #expect(ids(wanted: [wanted("bolt")], decks: [deck([("mist", "main")])], printingsByCard: map) == [3, 4, 5])
    }

    @Test func aCardOfADeckInTwoSectionsCountsOnce() {
        let keys = TrackedPrintings.cardKeys(wanted: [], decks: [deck([("mist", "main"), ("mist", "side")])])
        #expect(keys == ["mist"])
        #expect(ids(decks: [deck([("mist", "main"), ("mist", "side")])], printingsByCard: ["mist": [5, 7]]) == [5, 7])
    }

    @Test func noDecksPassedMeansDeckCardsAreNotTracked() {
        #expect(TrackedPrintings.cardKeys(wanted: [wanted("bolt")], decks: []) == ["bolt"])
        #expect(ids(wanted: [wanted("bolt")], printingsByCard: ["bolt": [3], "mist": [5]]) == [3])
    }

    @Test func anEmptyFileTracksNothing() {
        #expect(TrackedPrintings.cardKeys(wanted: [], decks: []).isEmpty)
        #expect(ids(printingsByCard: ["bolt": [3]]).isEmpty)
    }
}
