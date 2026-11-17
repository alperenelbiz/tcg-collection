import Foundation
import Testing
@testable import TCGCollection2

struct PriceDayFileTests {
    private func row(_ id: Int, _ finish: String, _ amount: Double, low: Bool = false) -> PriceDayRow {
        PriceDayRow(productID: id, finish: finish, price: ShownPrice(amount: amount, isLow: low))
    }

    private func reader(_ data: Data) throws -> PriceDayReader {
        let url = tempDir().appending(path: "day.prices")
        try PriceDayFile.write(data, to: url)
        return try PriceDayReader(url: url)
    }

    @Test func aDayRoundTrips() throws {
        let rows: [Int: [PriceDayRow]] = [
            89: [row(700, "Normal", 1.5), row(700, "Foil", 9.5, low: true), row(12, "Normal", 0.25)],
            2: [row(5, "1st Edition", 3.1), row(5, "Unlimited", 2.0), row(4_000_000_000, "Normal", 7)],
        ]
        let day = try reader(PriceDayFile.data(day: "2026-11-16", rows: rows))
        #expect(day.day == "2026-11-16")
        #expect(day.prices(category: 89, productID: 700) == ["Normal": ShownPrice(amount: 1.5, isLow: false),
                                                             "Foil": ShownPrice(amount: 9.5, isLow: true)])
        #expect(day.prices(category: 89, productID: 12) == ["Normal": ShownPrice(amount: 0.25, isLow: false)])
        #expect(day.prices(category: 2, productID: 5) == ["1st Edition": ShownPrice(amount: 3.1, isLow: false),
                                                          "Unlimited": ShownPrice(amount: 2.0, isLow: false)])
        #expect(day.prices(category: 2, productID: 4_000_000_000) == ["Normal": ShownPrice(amount: 7, isLow: false)])
        #expect(day.prices(category: 89, productID: 701) == [:])
        #expect(day.prices(category: 89, productID: 5) == [:])
        #expect(day.prices(category: 1, productID: 700) == [:])
    }

    @Test func rowsAreFoundByBinarySearch() throws {
        let finishes = ["Normal", "Foil", "1st Edition"]
        var rows: [PriceDayRow] = []
        for i in 0..<10_000 {
            let id = 1_000_000 - i * 37
            rows.append(row(id, finishes[i % 3], Double(i + 1) / 100, low: i % 7 == 0))
        }
        let day = try reader(PriceDayFile.data(day: "2026-11-16", rows: [1: rows.shuffled()]))
        for r in rows {
            #expect(day.prices(category: 1, productID: r.productID) == [r.finish: r.price])
        }
        #expect(day.prices(category: 1, productID: 1_000_001) == [:])
        #expect(day.prices(category: 1, productID: 0) == [:])
    }

    @Test func aLowPriceKeepsItsMark() throws {
        let day = try reader(PriceDayFile.data(day: "2026-11-16", rows: [92: [row(1, "Normal", 21_474_836.47, low: true),
                                                                               row(2, "Normal", 0.01, low: true),
                                                                               row(3, "Normal", 0.01)]]))
        #expect(day.prices(category: 92, productID: 1) == ["Normal": ShownPrice(amount: 21_474_836.47, isLow: true)])
        #expect(day.prices(category: 92, productID: 2) == ["Normal": ShownPrice(amount: 0.01, isLow: true)])
        #expect(day.prices(category: 92, productID: 3) == ["Normal": ShownPrice(amount: 0.01, isLow: false)])
    }

    @Test func centsRoundTrip() throws {
        let kept = [0.01, 0.07, 12.4, 21_474_836.47]
        var rows = kept.enumerated().map { row($0.offset + 1, "Normal", $0.element) }
        // Not stored: over 2^31 − 1 cents, not a price (0, negative, not finite), under half a cent.
        let dropped = [1_000_000_000, 21_474_836.48, 0, -1, .infinity, .nan, 0.004]
        rows += dropped.enumerated().map { row($0.offset + 100, "Normal", $0.element) }
        let day = try reader(PriceDayFile.data(day: "2026-11-16", rows: [1: rows]))
        for (i, amount) in kept.enumerated() {
            #expect(day.prices(category: 1, productID: i + 1) == ["Normal": ShownPrice(amount: amount, isLow: false)])
        }
        for i in dropped.indices { #expect(day.prices(category: 1, productID: i + 100) == [:]) }
    }

    @Test func aFileThatIsNotADayFileIsRefused() throws {
        let dir = tempDir()
        let json = dir.appending(path: "a.prices")
        try Data(#"{"version": 1}"#.utf8).write(to: json)
        #expect(throws: PriceDayFileError.notADayFile) { try PriceDayReader(url: json) }
        var badDay = PriceDayFile.data(day: "2026-11-16", rows: [:])
        badDay.replaceSubrange(6..<16, with: Data("2026/11/16".utf8))
        let bad = dir.appending(path: "b.prices")
        try badDay.write(to: bad)
        #expect(throws: PriceDayFileError.notADayFile) { try PriceDayReader(url: bad) }
        var extra = PriceDayFile.data(day: "2026-11-16", rows: [1: [row(1, "Normal", 1)]])
        extra.append(0)
        let long = dir.appending(path: "c.prices")
        try extra.write(to: long)
        #expect(throws: PriceDayFileError.notADayFile) { try PriceDayReader(url: long) }
    }

    @Test func aNewerVersionIsRefused() throws {
        var data = PriceDayFile.data(day: "2026-11-16", rows: [1: [row(1, "Normal", 1)]])
        #expect(data[5] == PriceDayFile.version)
        data[5] = PriceDayFile.version + 1
        let url = tempDir().appending(path: "a.prices")
        try data.write(to: url)
        #expect(throws: PriceDayFileError.newerVersion) { try PriceDayReader(url: url) }
    }

    @Test func aShortFileIsTruncated() throws {
        let data = PriceDayFile.data(day: "2026-11-16", rows: [1: [row(1, "Normal", 1), row(2, "Foil", 2)],
                                                               89: [row(3, "Normal", 3)]])
        let url = tempDir().appending(path: "a.prices")
        for length in [0, 3, 5, 6, 12, 16, 17, 20, data.count - 9, data.count - 1] {
            try data.prefix(length).write(to: url)
            #expect(throws: PriceDayFileError.truncated) { try PriceDayReader(url: url) }
        }
        try data.write(to: url)
        #expect(try PriceDayReader(url: url).prices(category: 89, productID: 3).count == 1)
    }

    /// Every market and low price of the fixture archive, for the four games' categories.
    private func fixturePrices() throws -> [Int: [PriceRow]] {
        var rows: [Int: [PriceRow]] = [:]
        try PriceArchive.read(fixtureURL("prices-2026-01-02.ppmd.7z"),
                              categories: Set(Games.all.map(\.categoryID))) { category, _, found in
            rows[category, default: []] += found
        }
        return rows
    }

    @Test func theFixtureArchiveIsWholeCents() throws {
        var offending: [Double] = []
        var checked = 0
        for rows in try fixturePrices().values {
            for amount in rows.flatMap({ [$0.price.market, $0.price.low] }).compactMap({ $0 }) {
                checked += 1
                if abs(amount * 100 - (amount * 100).rounded()) >= 1e-6 { offending.append(amount) }
            }
        }
        #expect(checked > 0)
        #expect(offending.isEmpty, "not whole cents: \(offending)")
    }

    @Test func aFixtureDayIsSmall() throws {
        var rows: [Int: [PriceDayRow]] = [:]
        for (category, found) in try fixturePrices() {
            rows[category] = found.compactMap { r in r.price.shown.map { PriceDayRow(productID: r.productID, finish: r.finish, price: $0) } }
        }
        let count = rows.values.reduce(0) { $0 + $1.count }
        let data = PriceDayFile.data(day: "2026-01-02", rows: rows)
        print("price day fixture: \(data.count) bytes, \(count) rows, \(Double(data.count) / Double(max(count, 1))) bytes per row")
        #expect(count > 0)
        #expect(data.count < 9 * count + 1024)
        let day = try reader(data)
        for (category, list) in rows {
            for r in list { #expect(day.prices(category: category, productID: r.productID)[r.finish] == r.price) }
        }
    }
}
