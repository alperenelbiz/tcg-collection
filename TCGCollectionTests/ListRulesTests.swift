import Testing
@testable import TCGCollection2

struct ListRulesTests {
    private let foil = PrintingKey(productID: 1, finish: "Foil")

    // MARK: Wanted

    @Test func settingAWantedCount() {
        var list = ListRules.settingWanted([], count: 2, cardKey: "bolt", name: "Lightning Bolt")
        #expect(list == [WantedEntry(cardKey: "bolt", name: "Lightning Bolt", count: 2, pinProductID: nil, pinFinish: nil)])
        #expect(list[0].pin == nil && list[0].id == "bolt")
        list = ListRules.pinning(list, cardKey: "bolt", to: foil)
        list = ListRules.settingWanted(list, count: 4, cardKey: "bolt", name: "ignored")
        // The pin and the name are kept on a count change.
        #expect(list == [WantedEntry(cardKey: "bolt", name: "Lightning Bolt", count: 4, pinProductID: 1, pinFinish: "Foil")])
        #expect(ListRules.settingWanted(list, count: 0, cardKey: "bolt", name: "").isEmpty)
        #expect(ListRules.settingWanted(list, count: -2, cardKey: "bolt", name: "").isEmpty)
        #expect(ListRules.settingWanted(list, count: 0, cardKey: "other", name: "") == list)
        // A new entry goes at the end, with no pin.
        let more = ListRules.settingWanted(list, count: 1, cardKey: "ring", name: "Sol Ring")
        #expect(more.map(\.cardKey) == ["bolt", "ring"]); #expect(more[1].pin == nil)
    }

    @Test func pinningAWantedCard() {
        let list = [WantedEntry(cardKey: "bolt", name: "B", count: 1, pinProductID: nil, pinFinish: nil),
                    WantedEntry(cardKey: "ring", name: "R", count: 2, pinProductID: nil, pinFinish: nil)]
        let pinned = ListRules.pinning(list, cardKey: "bolt", to: foil)
        #expect(pinned[0].pin == foil); #expect(pinned[0].pinProductID == 1 && pinned[0].pinFinish == "Foil")
        #expect(pinned[1] == list[1]); #expect(pinned[0].count == 1)
        #expect(ListRules.pinning(pinned, cardKey: "bolt", to: nil) == list)                // cleared by nil
        #expect(ListRules.pinning(list, cardKey: "unknown", to: foil) == list)              // an unknown card: nothing
    }

    // MARK: For sale

    @Test func settingAForSaleCount() {
        var list = ListRules.settingForSale([], count: 2, key: foil, name: "A", owned: 3)
        #expect(list == [SaleEntry(productID: 1, finish: "Foil", count: 2, name: "A")])
        #expect(list[0].key == foil && list[0].id == foil)
        list = ListRules.settingForSale(list, count: 5, key: foil, name: "ignored", owned: 3)
        #expect(list == [SaleEntry(productID: 1, finish: "Foil", count: 3, name: "A")])     // clamped to owned
        #expect(ListRules.settingForSale(list, count: 0, key: foil, name: "", owned: 3).isEmpty)
        #expect(ListRules.settingForSale(list, count: -1, key: foil, name: "", owned: 3).isEmpty)
        #expect(ListRules.settingForSale([], count: 2, key: foil, name: "A", owned: 0).isEmpty)   // owned 0: no entry
        #expect(ListRules.settingForSale(list, count: 2, key: foil, name: "", owned: 0).isEmpty)
        let two = ListRules.settingForSale(list, count: 1, key: .init(productID: 2, finish: "Normal"), name: "B", owned: 1)
        #expect(two.map(\.productID) == [1, 2])
    }

    @Test func clampedLowersAndRemoves() {
        let collection = [CollectionRow(productID: 1, finish: "Foil", count: 2, condition: "", name: "A"),
                          CollectionRow(productID: 2, finish: "Normal", count: 5, condition: "", name: "B")]
        let list = [SaleEntry(productID: 1, finish: "Foil", count: 5, name: "A"),
                    SaleEntry(productID: 2, finish: "Normal", count: 3, name: "B"),
                    SaleEntry(productID: 3, finish: "Normal", count: 2, name: "C"),
                    SaleEntry(productID: 1, finish: "Normal", count: 1, name: "A")]
        let (clamped, lost) = ListRules.clamped(list, to: collection)
        #expect(clamped == [SaleEntry(productID: 1, finish: "Foil", count: 2, name: "A"),
                            SaleEntry(productID: 2, finish: "Normal", count: 3, name: "B")])
        #expect(lost == 3 + 2 + 1)
        #expect(ListRules.clamped(clamped, to: collection) == (clamped, 0))
        #expect(ListRules.clamped([], to: collection) == ([], 0))
    }

    // MARK: Selling

    private func file(owned: Int, forSale: Int, saleName: String = "A") -> GameUserFile {
        var file = GameUserFile()
        file.collection = [CollectionRow(productID: 1, finish: "Foil", count: owned, condition: "Near Mint", name: "A"),
                           CollectionRow(productID: 2, finish: "Normal", count: 1, condition: "", name: "Other")]
        file.forSale = [SaleEntry(productID: 1, finish: "Foil", count: forSale, name: saleName)]
        return file
    }

    @Test func sellingOneOfThreeForSale() throws {
        var before = file(owned: 4, forSale: 3)
        before.sold = [SoldRecord(productID: 9, finish: "Normal", count: 1, name: "Earlier", day: "2026-11-01", price: nil, priceIsLow: false)]
        let after = try #require(ListRules.selling(before, key: foil, count: 1, day: "2026-11-13",
                                                   price: ShownPrice(amount: 2.5, isLow: false)))
        #expect(after.collection.map(\.count) == [3, 1]); #expect(after.collection[0].condition == "Near Mint")
        #expect(after.forSale == [SaleEntry(productID: 1, finish: "Foil", count: 2, name: "A")])
        #expect(after.sold == before.sold + [SoldRecord(productID: 1, finish: "Foil", count: 1, name: "A", day: "2026-11-13",
                                                        price: 2.5, priceIsLow: false)])
    }

    @Test func sellingTheLastCopyRemovesBothRows() throws {
        let after = try #require(ListRules.selling(file(owned: 1, forSale: 1), key: foil, count: 1, day: "2026-11-13", price: nil))
        #expect(after.collection.map(\.productID) == [2]); #expect(after.forSale.isEmpty)
        #expect(after.sold == [SoldRecord(productID: 1, finish: "Foil", count: 1, name: "A", day: "2026-11-13", price: nil, priceIsLow: false)])
    }

    @Test func sellingMoreThanAreForSaleOrOwnedIsRefused() {
        let three = file(owned: 4, forSale: 3)
        #expect(ListRules.selling(three, key: foil, count: 4, day: "d", price: nil) == nil)          // 4 of 3 for sale
        #expect(ListRules.selling(three, key: foil, count: 0, day: "d", price: nil) == nil)
        #expect(ListRules.selling(three, key: foil, count: -1, day: "d", price: nil) == nil)
        #expect(ListRules.selling(three, key: .init(productID: 2, finish: "Normal"), count: 1, day: "d", price: nil) == nil)  // owned, not for sale
    }

    /// Review Focus 2: a file whose for-sale count is over its owned count sells at most what is owned. Fix round 1:
    /// `selling` lowers both counts by the copies sold and no more; what stays over is the clamp's (`UserLibrary`'s one
    /// clamp, which counts it for the notice), not taken off here unsaid.
    @Test func sellingNeverTakesMoreThanAreOwned() throws {
        let over = file(owned: 2, forSale: 5)
        #expect(ListRules.selling(over, key: foil, count: 3, day: "d", price: nil) == nil)
        let one = try #require(ListRules.selling(over, key: foil, count: 1, day: "d", price: nil))
        #expect(one.collection.map(\.count) == [1, 1]); #expect(one.forSale.map(\.count) == [4])
        #expect(ListRules.clamped(one.forSale, to: one.collection) == ([SaleEntry(productID: 1, finish: "Foil", count: 1, name: "A")], 3))
        let all = try #require(ListRules.selling(over, key: foil, count: 2, day: "d", price: nil))
        #expect(all.collection.map(\.productID) == [2]); #expect(all.forSale.map(\.count) == [3])
        #expect(ListRules.clamped(all.forSale, to: all.collection) == ([], 3))
        #expect(all.sold.map(\.count) == [2])
    }

    @Test func aLowPriceIsMarkedAndTheNameComesFromTheCollectionWhenEmpty() throws {
        let after = try #require(ListRules.selling(file(owned: 2, forSale: 2, saleName: ""), key: foil, count: 2, day: "2026-11-13",
                                                   price: ShownPrice(amount: 0.4, isLow: true)))
        #expect(after.sold == [SoldRecord(productID: 1, finish: "Foil", count: 2, name: "A", day: "2026-11-13", price: 0.4, priceIsLow: true)])
    }
}
