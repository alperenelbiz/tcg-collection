import Foundation
import Testing
@testable import TCGCollection2

struct PriceArchiveTests {
    @Test func readsOnlyTheAskedCategories() throws {
        var seen: [String] = []; var rows = 0
        try PriceArchive.read(fixtureURL("prices-2026-01-02.ppmd.7z"), categories: [89, 92]) { c, g, r in seen.append("\(c)/\(g)"); rows += r.count }
        #expect(seen.sorted() == ["89/24819", "92/24884"]); #expect(rows == 21)
        #expect(PriceArchive.day(of: fixtureURL("prices-2026-01-02.ppmd.7z")) == "2026-01-02")
    }

    @Test func readsNullPricesAndFinishes() throws {
        var found: [PriceRow] = []
        try PriceArchive.read(fixtureURL("prices-2026-01-02.ppmd.7z"), categories: [89]) { _, _, r in found += r }
        #expect(found.contains(PriceRow(productID: 721334, finish: "Foil", price: Price(market: nil, low: 9.5, mid: nil, high: nil))))
    }

    @Test func aFileThatIsNotAnArchiveThrows() {
        #expect(throws: PriceArchiveError.self) { try PriceArchive.read(fixtureURL("not-an-archive.7z"), categories: [89]) { _, _, _ in } }
        #expect(PriceArchive.day(of: fixtureURL("not-an-archive.7z")) == nil)
    }

    @Test func aCutArchiveThrows() throws {
        let cut = URL.temporaryDirectory.appending(path: UUID().uuidString + ".7z")
        defer { try? FileManager.default.removeItem(at: cut) }
        try Data(contentsOf: fixtureURL("prices-2026-01-02.ppmd.7z")).prefix(300).write(to: cut)
        #expect(throws: PriceArchiveError.self) { try PriceArchive.read(cut, categories: [89, 92]) { _, _, _ in } }
    }
}
