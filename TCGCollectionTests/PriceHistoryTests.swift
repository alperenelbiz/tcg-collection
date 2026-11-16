import Foundation
import Testing
@testable import TCGCollection2

struct PriceHistoryTests {
    private func text(_ history: PriceHistory) -> String { String(decoding: history.data(), as: UTF8.self) }
    private func read(_ json: String) throws -> PriceHistory { try PriceHistory(data: Data(json.utf8)) }
    private func price(_ amount: Double, low: Bool = false) -> ShownPrice { ShownPrice(amount: amount, isLow: low) }

    @Test func aHistoryRoundTripsWithSortedKeys() throws {
        let history = PriceHistory(days: ["2026-11-11", "2026-11-12"],
                                   products: [7: ["Normal": [price(12.4), nil], "Foil": [nil, price(3.0, low: true)]]])
        let expected = #"{"days":["2026-11-11","2026-11-12"],"products":{"7":{"Foil":{"low":[1],"prices":[null,3]},"#
            + #""Normal":{"prices":[12.4,null]}}},"version":1}"#
        #expect(text(history) == expected)
        #expect(try PriceHistory(data: history.data()) == history)
    }

    @Test func aFinishWithNoPriceIsNotWritten() {
        let history = PriceHistory(days: ["2026-11-11"], products: [7: ["Normal": [price(1.5)], "Foil": [nil]]])
        #expect(text(history) == #"{"days":["2026-11-11"],"products":{"7":{"Normal":{"prices":[1.5]}}},"version":1}"#)
    }

    @Test func aProductReadWithNoPriceKeepsItsEntry() throws {
        var history = PriceHistory(days: [], products: [:])
        history.setDay("2026-11-11", rows: [:], for: [7])
        #expect(history.has(productID: 7))
        #expect(!history.has(productID: 8))
        #expect(text(history) == #"{"days":["2026-11-11"],"products":{"7":{}},"version":1}"#)
        #expect(try PriceHistory(data: history.data()).has(productID: 7))
    }

    @Test func aNewerVersionIsRefused() {
        #expect(throws: PriceHistoryError.newerVersion) {
            try read(#"{"days":[],"products":{},"version":2}"#)
        }
    }

    @Test func aHugeVersionIsRefusedWithoutACrash() {
        #expect(throws: PriceHistoryError.newerVersion) {
            try read(#"{"days":[],"products":{},"version":1e30}"#)
        }
    }

    @Test func daysOutOfOrderOrRepeatedAndAMissingVersionAreMalformed() {
        #expect(throws: PriceHistoryError.malformed) {
            try read(#"{"days":["2026-11-12","2026-11-11"],"products":{},"version":1}"#)
        }
        #expect(throws: PriceHistoryError.malformed) {
            try read(#"{"days":["2026-11-11","2026-11-11"],"products":{},"version":1}"#)
        }
        #expect(throws: PriceHistoryError.malformed) { try read(#"{"days":[],"products":{}}"#) }
    }

    @Test func aLowIndexOnANullPriceIsIgnoredAndTheFinishKept() throws {
        let history = try read(#"{"days":["2026-11-11","2026-11-12"],"products":{"7":{"Normal":{"low":[0,1],"prices":[null,2]}}},"version":1}"#)
        #expect(history.products == [7: ["Normal": [nil, price(2, low: true)]]])
    }

    @Test func badJSONIsMalformed() {
        #expect(throws: PriceHistoryError.malformed) { try read("{not json") }
        #expect(throws: PriceHistoryError.malformed) { try read("[1, 2]") }
        #expect(throws: PriceHistoryError.malformed) { try read(#"{"days":"x","products":{},"version":1}"#) }
        #expect(throws: PriceHistoryError.malformed) { try read(#"{"days":[],"products":[],"version":1}"#) }
    }

    @Test func anEntryThatDoesNotFitIsDropped() throws {
        let json = #"{"days":["2026-11-11","2026-11-12"],"products":{"#
            + #""7":{"Normal":{"prices":[1,2]},"Foil":{"prices":[1]}},"#
            + #""x":{"Normal":{"prices":[1,2]}},"-5":{"Normal":{"prices":[1,2]}},"#
            + #""8":{"Normal":{"low":[2],"prices":[1,2]},"Foil":{"low":[0],"prices":[4,null]}}"#
            + #"},"version":1}"#
        let history = try read(json)
        #expect(history.days == ["2026-11-11", "2026-11-12"])
        #expect(history.products == [
            7: ["Normal": [price(1), price(2)]],
            8: ["Foil": [price(4, low: true), nil]],
        ])
    }

    @Test func settingADayInsertsItInOrderAndPadsTheOthers() {
        var history = PriceHistory(days: ["2026-11-11", "2026-11-12"],
                                   products: [7: ["Normal": [price(1), price(2)]], 8: ["Foil": [nil, price(5)]]])
        history.setDay("2026-11-10", rows: [7: ["Normal": price(0.5)], 8: ["Foil": price(9)]], for: [7])
        #expect(history.days == ["2026-11-10", "2026-11-11", "2026-11-12"])
        #expect(history.products[7] == ["Normal": [price(0.5), price(1), price(2)]])
        #expect(history.products[8] == ["Foil": [nil, nil, price(5)]])
    }

    @Test func settingADayInTheMiddlePadsAtItsIndex() {
        var history = PriceHistory(days: ["2026-11-10", "2026-11-12"],
                                   products: [7: ["Normal": [price(1), price(3)]], 8: ["Foil": [price(4), price(6)]]])
        history.setDay("2026-11-11", rows: [7: ["Normal": price(2)]], for: [7])
        #expect(history.days == ["2026-11-10", "2026-11-11", "2026-11-12"])
        #expect(history.products[7] == ["Normal": [price(1), price(2), price(3)]])
        #expect(history.products[8] == ["Foil": [price(4), nil, price(6)]])
    }

    @Test func settingAnExistingDayReplacesTheNamedProductsValues() {
        var history = PriceHistory(days: ["2026-11-11", "2026-11-12"],
                                   products: [7: ["Normal": [price(1), price(2)], "Foil": [nil, price(5)]],
                                              8: ["Normal": [nil, price(9)]]])
        history.setDay("2026-11-12", rows: [7: ["Normal": price(2.5, low: true)], 8: ["Normal": price(1)]], for: [7])
        #expect(history.days == ["2026-11-11", "2026-11-12"])
        #expect(history.products[7] == ["Normal": [price(1), price(2.5, low: true)]])
        #expect(history.products[8] == ["Normal": [nil, price(9)]])
    }

    @Test func settingADayTwiceFillsOnlyTheNamedProducts() {
        var history = PriceHistory(days: [], products: [:])
        let rows: [Int: [String: ShownPrice]] = [7: ["Normal": price(1)], 8: ["Foil": price(2, low: true)], 9: ["Normal": price(3)]]
        history.setDay("2026-11-11", rows: rows, for: [7])
        history.setDay("2026-11-11", rows: rows, for: [8])
        #expect(history.days == ["2026-11-11"])
        #expect(history.products == [7: ["Normal": [price(1)]], 8: ["Foil": [price(2, low: true)]]])
    }

    @Test func trimmingDropsDaysOutOfTheWindowAndUntrackedProducts() {
        let history = PriceHistory(days: ["2026-08-18", "2026-08-19", "2026-11-16"],
                                   products: [7: ["Normal": [price(1), price(2), nil], "Foil": [price(4), nil, nil]],
                                              8: ["Normal": [price(5), price(6), price(7)]],
                                              9: [:]])
        let trimmed = history.trimmed(window: PriceDay.window(endingOn: "2026-11-16"), keeping: [7, 9])
        #expect(trimmed.days == ["2026-08-19", "2026-11-16"])
        #expect(trimmed.products == [7: ["Normal": [price(2), nil]], 9: [:]])
    }

    @Test func theWindowIs90DaysWithItsEnd() {
        let window = PriceDay.window(endingOn: "2026-11-16")
        #expect(window == "2026-08-19"..."2026-11-16")
        let days = PriceDay.days(in: window)
        #expect(days.count == 90)
        #expect(days.first == "2026-08-19")
        #expect(days.last == "2026-11-16")
        #expect(days.contains("2026-09-30") && days.contains("2026-10-01"))
        #expect(PriceDay.window(endingOn: "2026-03-01").lowerBound == "2025-12-02")
    }

    @Test func pointsSkipDaysWithoutAPriceAndCarryTheLowMark() {
        let history = PriceHistory(days: ["2026-11-10", "2026-11-11", "2026-11-12"],
                                   products: [7: ["Normal": [price(1), nil, price(2, low: true)]]])
        #expect(history.points(productID: 7, finish: "Normal") == [
            HistoryPoint(day: "2026-11-10", amount: 1, isLow: false),
            HistoryPoint(day: "2026-11-12", amount: 2, isLow: true),
        ])
        #expect(history.points(productID: 7, finish: "Foil").isEmpty)
        #expect(history.points(productID: 8, finish: "Normal").isEmpty)
    }
}
