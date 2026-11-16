import Foundation
import Testing
@testable import TCGCollection2

struct SetMathsTests {
    private func key(_ id: Int, _ finish: String) -> PrintingKey { PrintingKey(productID: id, finish: finish) }

    private func row(_ id: Int, _ finish: String, _ count: Int) -> CollectionRow {
        CollectionRow(productID: id, finish: finish, count: count, condition: "", name: "Card \(id)")
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func set(_ id: Int, _ name: String, _ abbreviation: String = "", published: Date? = nil) -> SetRecord {
        SetRecord(groupID: id, gameID: "magic-the-gathering", name: name, abbreviation: abbreviation, publishedOn: published)
    }

    private func numbers(owned: Int, total: Int, sum: Double?, unpriced: Int) -> SetNumbers {
        SetNumbers(owned: owned, total: total, missingSum: sum, missingUnpriced: unpriced)
    }

    private func setRow(_ set: SetRecord, _ numbers: SetNumbers) -> SetRow { SetRow(set: set, numbers: numbers) }

    // MARK: targets (F1)

    @Test func targetsAreThePricedFinishesInOrder() {
        let targets = SetMaths.targets(productID: 7, priced: ["Normal", "Foil"], owned: [])
        #expect(targets.map(\.key) == [key(7, "Normal"), key(7, "Foil")])
        #expect(targets.map(\.id) == targets.map(\.key))
    }

    @Test func aProductWithoutPricesHasOneNormalTarget() {
        #expect(SetMaths.targets(productID: 7, priced: [], owned: []).map(\.finish) == ["Normal"])
    }

    /// Review Focus 1: an owned finish the table lacks is a target.
    @Test func anOwnedFinishThePriceTableLacksIsATarget() {
        #expect(SetMaths.targets(productID: 7, priced: ["Normal"], owned: ["Foil"]).map(\.finish) == ["Normal", "Foil"])
        #expect(SetMaths.targets(productID: 7, priced: [], owned: ["Foil"]).map(\.finish) == ["Normal", "Foil"])
    }

    // MARK: numbers (A26, F2, F6)

    /// Products 1 (Normal, Foil), 2 (Normal, Foil), 3 (Normal). Owned: 1 Normal (×3), 2 Foil. Missing: 1 Foil $1.00,
    /// 2 Normal $2.50, 3 Normal without a price.
    private func threeProductNumbers(owned: [PrintingKey: Int]) -> SetNumbers {
        let priced: [Int: [String]] = [1: ["Normal", "Foil"], 2: ["Normal", "Foil"], 3: []]
        let prices: [PrintingKey: ShownPrice] = [
            key(1, "Normal"): ShownPrice(amount: 9, isLow: false),
            key(1, "Foil"): ShownPrice(amount: 1, isLow: false),
            key(2, "Normal"): ShownPrice(amount: 2.5, isLow: true),
            key(2, "Foil"): ShownPrice(amount: 4, isLow: false),
        ]
        return SetMaths.numbers(products: [1, 2, 3], priced: { priced[$0] ?? [] }, ownedCount: { owned[$0] ?? 0 },
                                ownedFinishes: { id in owned.filter { $0.key.productID == id && $0.value > 0 }.map(\.key.finish).sorted() },
                                price: { prices[$0] })
    }

    @Test func numbersCountTargetsAndPriceTheMissingOnes() {
        let n = threeProductNumbers(owned: [key(1, "Normal"): 3, key(2, "Foil"): 1])
        #expect(n.owned == 2)        // a count of 3 is one owned target
        #expect(n.total == 5)
        #expect(n.missingSum == 3.5)
        #expect(n.missingUnpriced == 1)
        #expect(!n.isComplete)
    }

    @Test func aCountUnderOneIsNotOwned() {
        let n = threeProductNumbers(owned: [key(1, "Normal"): 0])
        #expect(n.owned == 0)
        #expect(n.total == 5)
    }

    @Test func aCompleteSetHasNoMissingPrice() {
        let all = [key(1, "Normal"), key(1, "Foil"), key(2, "Normal"), key(2, "Foil"), key(3, "Normal")]
        let n = threeProductNumbers(owned: Dictionary(uniqueKeysWithValues: all.map { ($0, 1) }))
        #expect(n == numbers(owned: 5, total: 5, sum: nil, unpriced: 0))
        #expect(n.isComplete)
    }

    @Test func missingTargetsWithoutAnyPriceGiveNoSum() {
        let n = SetMaths.numbers(products: [1, 2], priced: { _ in [] }, ownedCount: { _ in 0 }, ownedFinishes: { _ in [] },
                                 price: { _ in nil })
        #expect(n == numbers(owned: 0, total: 2, sum: nil, unpriced: 2))
    }

    // MARK: rows

    @Test func rowsListOnlySetsWithProductsInTheIndex() {
        let index = SetIndex(sets: [10: [1, 2], 20: [3]])
        let sets = [set(10, "Alpha"), set(20, "Beta"), set(30, "Gamma")]
        let result = SetMaths.rows(sets: sets, index: index, rows: [], priced: { _ in [] }, price: { _ in nil })
        #expect(result.map(\.id) == [10, 20])
        #expect(result.map(\.numbers.total) == [2, 1])
    }

    /// Review Focus 2: a row of a product in no set changes no number.
    @Test func aRowOfAProductInNoSetChangesNothing() {
        let index = SetIndex(sets: [10: [1, 2]])
        let sets = [set(10, "Alpha")]
        let without = SetMaths.rows(sets: sets, index: index, rows: [], priced: { _ in [] }, price: { _ in nil })
        let with = SetMaths.rows(sets: sets, index: index, rows: [row(99, "Normal", 4), row(99, "Foil", 1)],
                                 priced: { _ in [] }, price: { _ in nil })
        #expect(with == without)
    }

    /// A26: products 1 (set 10) and 2 (set 20) are printings of one card; owning 2 counts in set 20 only. An owned finish
    /// the table lacks is a target and owned; a row under 1 is no target.
    @Test func aPrintingCountsOnlyInItsOwnSet() {
        let index = SetIndex(sets: [10: [1], 20: [2]])
        let sets = [set(10, "Alpha"), set(20, "Beta")]
        let rows = [row(2, "Normal", 1), row(2, "Foil", 2), row(1, "Etched", 0)]
        let result = SetMaths.rows(sets: sets, index: index, rows: rows, priced: { _ in ["Normal"] },
                                   price: { _ in ShownPrice(amount: 1, isLow: false) })
        #expect(result[0].numbers == numbers(owned: 0, total: 1, sum: 1, unpriced: 0))
        #expect(result[1].numbers == numbers(owned: 2, total: 2, sum: nil, unpriced: 0))
    }

    // MARK: scope (A27)

    @Test func myScopeFallsBackToAllWhenNothingIsOwned() {
        let none = [setRow(set(1, "A"), numbers(owned: 0, total: 3, sum: 1, unpriced: 0))]
        let one = none + [setRow(set(2, "B"), numbers(owned: 1, total: 3, sum: 1, unpriced: 0))]
        #expect(SetMaths.scope(.mine, rows: none) == .all)
        #expect(SetMaths.scope(.mine, rows: one) == .mine)
        #expect(SetMaths.scope(.all, rows: one) == .all)
        #expect(SetMaths.scope(.mine, rows: []) == .all)
    }

    // MARK: shown

    private var sample: [SetRow] {
        [
            setRow(set(1, "Beyond the Brave", "BETB", published: day(2025, 11, 7)),
                   numbers(owned: 2, total: 4, sum: 10, unpriced: 0)),                     // 50 %, $10
            setRow(set(2, "Alpha Édition", "LEA", published: day(1993, 8, 5)),
                   numbers(owned: 0, total: 4, sum: 3, unpriced: 1)),                      // 0 %, $3
            setRow(set(3, "Cheap Set", "CHP"), numbers(owned: 3, total: 4, sum: nil, unpriced: 1)),   // 75 %, no price
            setRow(set(4, "Done Set", "DON", published: day(2025, 11, 7)),
                   numbers(owned: 4, total: 4, sum: nil, unpriced: 0)),                    // complete
            setRow(set(5, "Another Cheap", "ACH", published: day(2020, 1, 1)),
                   numbers(owned: 1, total: 4, sum: nil, unpriced: 2)),                    // 25 %, no price
        ]
    }

    @Test func myScopeKeepsSetsWithAnOwnedTarget() {
        let shown = SetMaths.shown(sample, scope: .mine, text: "", sort: .name)
        #expect(shown.map(\.id) == [5, 1, 3, 4])
        #expect(SetMaths.shown(sample, scope: .all, text: "", sort: .name).count == 5)
    }

    @Test func textMatchesNameOrAbbreviationFoldedEveryWord() {
        #expect(SetMaths.shown(sample, scope: .all, text: "betb", sort: .name).map(\.id) == [1])
        #expect(SetMaths.shown(sample, scope: .all, text: "  BRAVE beyond ", sort: .name).map(\.id) == [1])
        #expect(SetMaths.shown(sample, scope: .all, text: "edition", sort: .name).map(\.id) == [2])
        #expect(SetMaths.shown(sample, scope: .all, text: "cheap", sort: .name).map(\.id) == [5, 3])
        #expect(SetMaths.shown(sample, scope: .all, text: "cheap zzz", sort: .name).isEmpty)
        #expect(SetMaths.shown(sample, scope: .mine, text: "alpha", sort: .name).isEmpty)
    }

    @Test func sortNewestPutsUndatedLastThenName() {
        #expect(SetMaths.shown(sample, scope: .all, text: "", sort: .newest).map(\.id) == [1, 4, 5, 2, 3])
    }

    @Test func sortName() {
        #expect(SetMaths.shown(sample, scope: .all, text: "", sort: .name).map(\.id) == [2, 5, 1, 3, 4])
    }

    @Test func sortMostCompleteThenName() {
        let tie = setRow(set(6, "Aaa", "AAA"), numbers(owned: 1, total: 2, sum: 1, unpriced: 0))   // 50 %, ties set 1
        #expect(SetMaths.shown(sample + [tie], scope: .all, text: "", sort: .complete).map(\.id) == [4, 3, 6, 1, 5, 2])
    }

    @Test func sortCostPutsUnpricedThenCompleteLast() {
        let tie = setRow(set(6, "Aaa", "AAA"), numbers(owned: 1, total: 2, sum: 3, unpriced: 0))   // $3, ties set 2
        #expect(SetMaths.shown(sample + [tie], scope: .all, text: "", sort: .cost).map(\.id) == [6, 2, 1, 5, 3, 4])
    }

    // MARK: texts

    @Test func countText() {
        #expect(SetMaths.countText(numbers(owned: 187, total: 412, sum: 1240.5, unpriced: 0)) == "187 / 412")
    }

    @Test func costTexts() {
        #expect(SetMaths.costText(numbers(owned: 187, total: 412, sum: 1240.5, unpriced: 0)) == "$1,240.50")
        #expect(SetMaths.costText(numbers(owned: 187, total: 412, sum: 310, unpriced: 3)) == "$310.00 + 3 without a price")
        #expect(SetMaths.costText(numbers(owned: 187, total: 412, sum: nil, unpriced: 12)) == "12 without a price")
        #expect(SetMaths.costText(numbers(owned: 412, total: 412, sum: nil, unpriced: 0)) == nil)
    }

    @Test func subtitles() {
        #expect(SetMaths.subtitle(shown: 12, of: 12, searching: false) == "12 sets")
        #expect(SetMaths.subtitle(shown: 1, of: 1, searching: false) == "1 set")
        #expect(SetMaths.subtitle(shown: 3, of: 12, searching: true) == "3 of 12 sets")
    }

    @Test func pageSubtitles() {
        #expect(SetMaths.pageSubtitle(numbers(owned: 187, total: 412, sum: 1240.5, unpriced: 0))
                == "187 of 412 · $1,240.50 to complete")
        #expect(SetMaths.pageSubtitle(numbers(owned: 187, total: 412, sum: 310, unpriced: 3))
                == "187 of 412 · $310.00 to complete + 3 without a price")
        #expect(SetMaths.pageSubtitle(numbers(owned: 187, total: 412, sum: nil, unpriced: 12)) == "187 of 412 · 12 without a price")
        #expect(SetMaths.pageSubtitle(numbers(owned: 412, total: 412, sum: nil, unpriced: 0)) == "412 of 412")
    }

    @Test func releaseTextIsEnglishMonthAndYearInUTC() {
        #expect(SetMaths.releaseText(day(2025, 11, 7)) == "November 2025")
        // The first instant of a month in UTC stays in that month, whatever the device's time zone.
        #expect(SetMaths.releaseText(day(2026, 1, 1)) == "January 2026")
        #expect(SetMaths.releaseText(day(2025, 12, 31).addingTimeInterval(86_399)) == "December 2025")
        #expect(SetMaths.releaseText(nil) == "")
    }

    @Test func leftTexts() {
        #expect(SetMaths.leftText(count: 2, finish: "Normal") == "×2")
        #expect(SetMaths.leftText(count: 2, finish: "Foil") == "×2 · Foil")
        #expect(SetMaths.leftText(count: 0, finish: "Foil") == "Foil")
        #expect(SetMaths.leftText(count: 0, finish: "Normal") == "")
        #expect(SetMaths.leftText(count: 1, finish: "1st Edition") == "×1 · 1st Edition")
    }

    // MARK: filtered

    @Test func filterMissingAndOwned() {
        let targets = SetMaths.targets(productID: 1, priced: ["Normal", "Foil", "Etched"], owned: [])
        let owned: [PrintingKey: Int] = [key(1, "Foil"): 2, key(1, "Etched"): 0]
        #expect(SetMaths.filtered(targets, filter: .all, ownedCount: { owned[$0] ?? 0 }) == targets)
        #expect(SetMaths.filtered(targets, filter: .missing, ownedCount: { owned[$0] ?? 0 }).map(\.finish) == ["Normal", "Etched"])
        #expect(SetMaths.filtered(targets, filter: .owned, ownedCount: { owned[$0] ?? 0 }).map(\.finish) == ["Foil"])
    }
}
