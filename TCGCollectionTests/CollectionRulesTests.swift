import Testing
@testable import TCGCollection2

struct CollectionRulesTests {
    @Test func settingACount() {
        let k = PrintingKey(productID: 1, finish: "Normal")
        var rows = CollectionRules.setting([], count: 2, for: k, name: "A")
        #expect(rows == [.init(productID: 1, finish: "Normal", count: 2, condition: "", name: "A")])
        rows = CollectionRules.setting(rows, count: 5, for: k, name: "ignored")
        #expect(rows[0].count == 5 && rows[0].name == "A")
        #expect(CollectionRules.setting(rows, count: 0, for: k, name: "").isEmpty)
        #expect(CollectionRules.setting(rows, count: -3, for: k, name: "").isEmpty)
        #expect(CollectionRules.setting(rows, count: 1, for: .init(productID: 1, finish: "Foil"), name: "A").count == 2)
    }

    @Test func settingKeepsConditionAndOrder() {
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 1, condition: "NM", name: "A"),
                    .init(productID: 2, finish: "Normal", count: 1, condition: "", name: "B")]
        let changed = CollectionRules.setting(rows, count: 4, for: .init(productID: 1, finish: "Normal"), name: "")
        #expect(changed[0].condition == "NM" && changed[0].count == 4 && changed[1] == rows[1])
        #expect(CollectionRules.setting(rows, count: 0, for: .init(productID: 9, finish: "Normal"), name: "") == rows)
        #expect(CollectionRules.count(rows, for: .init(productID: 2, finish: "Normal")) == 1)
        #expect(CollectionRules.count(rows, for: .init(productID: 2, finish: "Foil")) == 0)
    }

    @Test func playsetCountsACardOverAllItsPrintings() {
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 2, condition: "", name: ""),
                    .init(productID: 2, finish: "Foil", count: 2, condition: "", name: ""),
                    .init(productID: 9, finish: "Normal", count: 1, condition: "", name: "")]
        let perCard = CollectionRules.copiesPerCard(rows) { [1: "calm rune", 2: "calm rune"][$0] }
        #expect(perCard == ["calm rune": 4])
        #expect(CollectionRules.copies(rows) == 5)
        #expect(CollectionRules.matches(.moreThanAPlayset, copiesOfCard: 4, playset: 3))
        #expect(!CollectionRules.matches(.moreThanAPlayset, copiesOfCard: 3, playset: 3))
        #expect(CollectionRules.matches(.aPlaysetOrFewer, copiesOfCard: 3, playset: 3))
        #expect(!CollectionRules.matches(.aPlaysetOrFewer, copiesOfCard: 4, playset: 3))
        #expect(CollectionRules.matches(.any, copiesOfCard: 0, playset: 3))
    }

    @Test func priceFilter() {
        #expect(PriceFilter.under1.matches(0.99)); #expect(!PriceFilter.under1.matches(1))
        #expect(PriceFilter.from1.matches(1)); #expect(!PriceFilter.from1.matches(0.5))
        #expect(PriceFilter.from5.matches(5)); #expect(!PriceFilter.from20.matches(19.99)); #expect(PriceFilter.from20.matches(20))
        #expect(!PriceFilter.under1.matches(nil)); #expect(!PriceFilter.from1.matches(nil)); #expect(PriceFilter.any.matches(nil))
    }
}
