import Testing
@testable import TCGCollection2

struct CardFactsTests {
    private let magic = Games.game("magic-the-gathering")!
    private let yugioh = Games.game("yu-gi-oh")!
    private let riftbound = Games.game("riftbound")!
    private let cyberpunk = Games.game("cyberpunk")!

    @Test func factLine() {
        #expect(CardFacts.line(setName: "Radiance", product: product(number: "136/167", rarity: "Epic")) == "Radiance · Epic · 136/167")
        #expect(CardFacts.line(setName: "Radiance", product: product(number: "", rarity: "Epic")) == "Radiance · Epic")
        #expect(CardFacts.line(setName: "", product: product(number: "136/167", rarity: "Epic")) == "Epic · 136/167")
    }

    @Test func statsPerGame() {
        #expect(CardFacts.stats(product(fields: ["P": "3", "T": "4"]), game: magic) == [CardStat(label: "P/T", value: "3/4")])
        #expect(CardFacts.stats(product(fields: ["Attack": "2500", "Defense": "2000", "Attribute": "DARK", "MonsterType": "Dragon"]), game: yugioh).map(\.label)
                == ["Attribute", "Type", "ATK", "DEF"])
        #expect(CardFacts.stats(product(fields: ["LinkRating": "2"]), game: yugioh) == [CardStat(label: "Link", value: "2")])
        #expect(CardFacts.stats(product(fields: ["Eddies": "true", "Color": "Red"]), game: cyberpunk).last == CardStat(label: "Eddies", value: "Yes"))
        #expect(CardFacts.stats(product(fields: ["Eddies": "FALSE"]), game: cyberpunk).last == CardStat(label: "Eddies", value: "No"))
        #expect(CardFacts.stats(product(fields: ["Might": "3", "Domain": "Fury", "Energy Cost": "2", "Power Cost": "1", "Tag": "Yordle"]), game: riftbound)
                == [CardStat(label: "Domain", value: "Fury"), CardStat(label: "Energy", value: "2"), CardStat(label: "Power", value: "1"),
                    CardStat(label: "Might", value: "3"), CardStat(label: "Tag", value: "Yordle")])
        #expect(CardFacts.stats(product(fields: [:]), game: riftbound).isEmpty)
    }

    @Test func priceTextNeverShowsZero() {
        #expect(CardFacts.priceText(.init(amount: 4.12, isLow: false)) == "$4.12")
        #expect(CardFacts.priceText(.init(amount: 9.5, isLow: true)) == "~$9.50")
        #expect(CardFacts.priceText(.init(amount: 1234.5, isLow: false)) == "$1,234.50")
        #expect(CardFacts.priceText(nil) == "—")
    }
}
