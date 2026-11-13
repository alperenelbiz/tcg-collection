import Testing
import Foundation
@testable import TCGCollection2

struct GameUserFileTests {
    @Test func unknownKeysSurviveARewrite() throws {
        let json = #"{"version":1,"collection":[{"productID":721334,"finish":"Foil","count":2,"condition":"Near Mint","name":"Dockside Lock-Up"}],"wanted":[{"card":"x"}],"future":{"a":1}}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.collection = CollectionRules.setting(file.collection, count: 3, for: .init(productID: 721334, finish: "Foil"), name: "")
        let object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        #expect((object["wanted"] as? [[String: String]])?.first?["card"] == "x")
        #expect((object["future"] as? [String: Int])?["a"] == 1)
        #expect(try GameUserFile(data: try file.data()).collection == [.init(productID: 721334, finish: "Foil", count: 3, condition: "Near Mint", name: "Dockside Lock-Up")])
    }

    @Test func aNewerFileIsRefused() {
        #expect(throws: GameUserFileError.newerVersion(2)) { try GameUserFile(data: Data(#"{"version":2,"collection":[]}"#.utf8)) }
    }

    @Test func badRowsAreCleanedOnRead() throws {
        let json = #"{"version":1,"collection":[{"productID":1,"finish":"Normal","count":2},{"productID":1,"finish":"Normal","count":1},{"productID":2,"finish":"Foil","count":0},{"productID":3,"finish":"Foil","count":-4}]}"#
        #expect(try GameUserFile(data: Data(json.utf8)).collection == [.init(productID: 1, finish: "Normal", count: 3, condition: "", name: "")])
    }

    @Test func anEmptyFileAndGarbage() throws {
        #expect(try GameUserFile(data: try GameUserFile().data()).collection.isEmpty)
        #expect(throws: (any Error).self) { try GameUserFile(data: Data("not json".utf8)) }
        #expect(throws: GameUserFileError.notAnObject) { try GameUserFile(data: Data("[1,2]".utf8)) }
    }

    @Test func missingKeysAndMalformedRowsAreTolerated() throws {
        #expect(try GameUserFile(data: Data("{}".utf8)).collection.isEmpty)
        let json = #"{"collection":[{"finish":"Foil","count":1},{"productID":1,"count":1},{"productID":1,"finish":"Foil"},{"productID":"1","finish":"Foil","count":1},{"productID":1,"finish":"Foil","count":true},{"productID":4,"finish":"Foil","count":1.5},"x",7,{"productID":5,"finish":"Normal","count":1}]}"#
        #expect(try GameUserFile(data: Data(json.utf8)).collection == [.init(productID: 5, finish: "Normal", count: 1, condition: "", name: "")])
    }

    @Test func mergeKeepsTheFirstRowsPositionAndFillsEmptyFields() throws {
        let json = #"{"version":1,"collection":[{"productID":1,"finish":"A","count":1},{"productID":2,"finish":"A","count":1,"condition":"NM","name":"Two"},{"productID":1,"finish":"A","count":2,"condition":"LP","name":"One"},{"productID":2,"finish":"A","count":1,"condition":"DMG","name":"Other"}]}"#
        #expect(try GameUserFile(data: Data(json.utf8)).collection == [
            .init(productID: 1, finish: "A", count: 3, condition: "LP", name: "One"),
            .init(productID: 2, finish: "A", count: 2, condition: "NM", name: "Two")])
    }

    @Test func outputIsCanonical() throws {
        var file = GameUserFile()
        file.collection = [.init(productID: 1, finish: "Foil", count: 1, condition: "", name: "A/B")]
        let data = try file.data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\n  \"collection\""))
        #expect(text.range(of: "\"collection\"")!.lowerBound < text.range(of: "\"version\"")!.lowerBound)
        #expect(text.contains("\"A/B\""))
        #expect(try GameUserFile(data: data) == file)
        #expect(try GameUserFile(data: data).data() == data)
    }

    @Test func versionIsWrittenAsCurrentAndMissingCountsAsOne() throws {
        let file = try GameUserFile(data: Data(#"{"collection":[]}"#.utf8))
        let object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        #expect(object["version"] as? Int == GameUserFile.currentVersion)
    }

    @Test func equalityComparesCollectionAndUnknownKeys() throws {
        let a = try GameUserFile(data: Data(#"{"future":1}"#.utf8))
        let b = try GameUserFile(data: Data(#"{"future":2}"#.utf8))
        #expect(a != b)
        #expect(a == (try GameUserFile(data: Data(#"{"future":1,"version":1}"#.utf8))))
    }

    // MARK: Fix round 1

    @Test func aBadCollectionOrVersionRefusesTheFile() {
        #expect(throws: GameUserFileError.malformedCollection) { try GameUserFile(data: Data(#"{"collection":"x"}"#.utf8)) }
        #expect(throws: GameUserFileError.malformedCollection) { try GameUserFile(data: Data(#"{"collection":{"a":1}}"#.utf8)) }
        for v in [#""2""#, "2.5", "true", "null", "0", "-1"] {
            #expect(throws: GameUserFileError.malformedVersion) { try GameUserFile(data: Data("{\"version\":\(v),\"collection\":[]}".utf8)) }
        }
        #expect(throws: GameUserFileError.newerVersion(3)) { try GameUserFile(data: Data(#"{"version":3.0}"#.utf8)) }
        #expect(throws: Never.self) { try GameUserFile(data: Data(#"{"version":1,"collection":null}"#.utf8)) }
    }

    @Test func anUnknownRowKeySurvivesACountChange() throws {
        let json = #"{"collection":[{"productID":1,"finish":"Foil","count":2,"addedAt":"2026-01-01"}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.collection = CollectionRules.setting(file.collection, count: 5, for: .init(productID: 1, finish: "Foil"), name: "")
        let object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        let row = (object["collection"] as! [[String: Any]])[0]
        #expect(row["addedAt"] as? String == "2026-01-01"); #expect(row["count"] as? Int == 5)
    }

    @Test func unparseableRowsAndNonObjectsSurviveAtTheEnd() throws {
        let json = #"{"collection":[{"productID":"x","finish":"Foil","count":1,"keep":true},7,{"productID":1,"finish":"Normal","count":1}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.collection.count == 1)
        file.collection = CollectionRules.setting(file.collection, count: 2, for: .init(productID: 1, finish: "Normal"), name: "")
        let rows = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["collection"] as! [Any]
        #expect(rows.count == 3)
        #expect((rows[0] as! [String: Any])["productID"] as? Int == 1)
        #expect((rows[1] as! [String: Any])["keep"] as? Bool == true)
        #expect(rows[2] as? Int == 7)
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    @Test func aRemovedRowIsGoneWithItsUnknownKeys() throws {
        let json = #"{"collection":[{"productID":1,"finish":"Normal","count":1,"extra":1},{"productID":2,"finish":"Normal","count":0,"extra":2}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.collection = CollectionRules.setting(file.collection, count: 0, for: .init(productID: 1, finish: "Normal"), name: "")
        let rows = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["collection"] as! [Any]
        #expect(rows.isEmpty)
    }

    @Test func mergeKeepsTheFirstRowsUnknownKeys() throws {
        let json = #"{"collection":[{"productID":1,"finish":"A","count":1,"k":"first"},{"productID":1,"finish":"A","count":1,"k":"second","j":1}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        let row = ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["collection"] as! [[String: Any]])[0]
        #expect(row["k"] as? String == "first"); #expect(row["j"] == nil); #expect(row["count"] as? Int == 2)
    }

    @Test func finishIsTrimmedAndEmptyReadsAsNormal() throws {
        let json = #"{"collection":[{"productID":1,"finish":" Foil\n","count":1},{"productID":2,"finish":"  ","count":1},{"productID":3,"finish":"foil","count":1}]}"#
        let c = try GameUserFile(data: Data(json.utf8)).collection
        #expect(c.map(\.finish) == ["Foil", "Normal", "foil"])
    }

    // MARK: Phase 2C task 2: wanted, forSale, sold

    /// The exact text a phase 2B build writes for one row (pretty-printed, sorted keys, a final newline).
    private let phase2BText = """
        {
          "collection" : [
            {
              "condition" : "Near Mint",
              "count" : 2,
              "finish" : "Foil",
              "name" : "Dockside Lock-Up",
              "productID" : 721334
            }
          ],
          "version" : 1
        }

        """

    /// Review Focus 1: a phase 2B file opens with three empty lists, and a read and a rewrite keep its bytes: no key is
    /// added for an empty list, also after a change of the collection.
    @Test func aPhase2BFileReadsWithEmptyListsAndKeepsItsBytes() throws {
        var file = try GameUserFile(data: Data(phase2BText.utf8))
        #expect(file.wanted.isEmpty && file.forSale.isEmpty && file.sold.isEmpty)
        #expect(try file.data() == Data(phase2BText.utf8))
        file.collection[0].count = 3
        let object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        #expect(Set(object.keys) == ["collection", "version"])
        #expect(Set((try JSONSerialization.jsonObject(with: try GameUserFile().data()) as! [String: Any]).keys) == ["collection", "version"])
    }

    /// The three lists are read, written and read again unchanged; a nil pin and a nil price write no key.
    @Test func theThreeListsRoundTrip() throws {
        let json = #"{"version":1,"collection":[{"productID":1,"finish":"Foil","count":3,"condition":"","name":"A"}],"wanted":[{"cardKey":"bolt","name":"Lightning Bolt","count":4},{"cardKey":"ring","name":"Sol Ring","count":1,"pinProductID":9,"pinFinish":"Foil"}],"forSale":[{"productID":1,"finish":"Foil","count":2,"name":"A"}],"sold":[{"productID":1,"finish":"Foil","count":1,"name":"A","day":"2026-11-13","price":2.5,"priceIsLow":false},{"productID":2,"finish":"Normal","count":1,"name":"B","day":"2026-11-14","priceIsLow":true}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.wanted == [WantedEntry(cardKey: "bolt", name: "Lightning Bolt", count: 4, pinProductID: nil, pinFinish: nil),
                                WantedEntry(cardKey: "ring", name: "Sol Ring", count: 1, pinProductID: 9, pinFinish: "Foil")])
        #expect(file.wanted[0].pin == nil); #expect(file.wanted[1].pin == PrintingKey(productID: 9, finish: "Foil"))
        #expect(file.wanted.map(\.id) == ["bolt", "ring"])
        #expect(file.forSale == [SaleEntry(productID: 1, finish: "Foil", count: 2, name: "A")])
        #expect(file.forSale[0].key == PrintingKey(productID: 1, finish: "Foil")); #expect(file.forSale[0].id == file.forSale[0].key)
        #expect(file.sold == [SoldRecord(productID: 1, finish: "Foil", count: 1, name: "A", day: "2026-11-13", price: 2.5, priceIsLow: false),
                              SoldRecord(productID: 2, finish: "Normal", count: 1, name: "B", day: "2026-11-14", price: nil, priceIsLow: true)])
        let data = try file.data()
        #expect(try GameUserFile(data: data) == file)
        #expect(try GameUserFile(data: data).data() == data)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let wanted = object["wanted"] as! [[String: Any]], sold = object["sold"] as! [[String: Any]]
        #expect(Set(wanted[0].keys) == ["cardKey", "name", "count"])
        #expect(Set(sold[1].keys) == ["productID", "finish", "count", "name", "day", "priceIsLow"])
        #expect(sold[0]["price"] as? Double == 2.5)
    }

    /// A key this app does not know survives in an entry of each list, through a change of that entry and of another one.
    @Test func anEntrysUnknownKeySurvivesAChange() throws {
        let json = #"{"collection":[{"productID":1,"finish":"Normal","count":2},{"productID":2,"finish":"Normal","count":2}],"wanted":[{"cardKey":"a","name":"A","count":1,"note":"x"},{"cardKey":"b","name":"B","count":1}],"forSale":[{"productID":1,"finish":"Normal","count":1,"name":"A","note":"x"},{"productID":2,"finish":"Normal","count":1,"name":"B"}],"sold":[{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","priceIsLow":false,"note":"x"}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.wanted[0].count = 3                                                // the entry with the key
        file.wanted[1].count = 2                                                // another entry
        file.forSale[1].count = 2
        file.sold.append(SoldRecord(productID: 2, finish: "Normal", count: 1, name: "B", day: "2026-11-14", price: 1, priceIsLow: false))
        let object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        let wanted = object["wanted"] as! [[String: Any]], forSale = object["forSale"] as! [[String: Any]]
        let sold = object["sold"] as! [[String: Any]]
        #expect(wanted[0]["note"] as? String == "x"); #expect(wanted[0]["count"] as? Int == 3); #expect(wanted[1]["note"] == nil)
        #expect(forSale[0]["note"] as? String == "x"); #expect(forSale[1]["count"] as? Int == 2)
        #expect(sold.count == 2); #expect(sold[0]["note"] as? String == "x"); #expect(sold[1]["note"] == nil)
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    /// The app owns an entry's own keys: a pin taken away, or a price that is not there, leaves no key behind.
    @Test func aClearedPinLeavesNoKey() throws {
        let json = #"{"wanted":[{"cardKey":"a","name":"A","count":1,"pinProductID":3,"pinFinish":"Foil","note":"x"}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.wanted[0].pinProductID = nil; file.wanted[0].pinFinish = nil
        let entry = ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["wanted"] as! [[String: Any]])[0]
        #expect(Set(entry.keys) == ["cardKey", "name", "count", "note"])
        #expect(try GameUserFile(data: try file.data()).wanted[0].pin == nil)
    }

    /// Entries that cannot be parsed survive, in their order, after the parsed ones, in each list.
    @Test func unparseableEntriesSurviveAtTheEnd() throws {
        let json = #"{"wanted":["x",{"name":"no key","count":1},{"cardKey":"a","name":"A","count":1}],"forSale":[{"productID":"1","finish":"Normal","count":1},{"productID":1,"finish":"Normal","count":1}],"sold":[7,{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","priceIsLow":false}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.wanted.map(\.cardKey) == ["a"]); #expect(file.forSale.count == 1); #expect(file.sold.count == 1)
        file.wanted[0].count = 2
        file.forSale[0].count = 2
        file.sold.append(file.sold[0])
        let object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        let wanted = object["wanted"] as! [Any], forSale = object["forSale"] as! [Any], sold = object["sold"] as! [Any]
        #expect(wanted.count == 3)
        #expect((wanted[0] as! [String: Any])["cardKey"] as? String == "a")
        #expect(wanted[1] as? String == "x")
        #expect((wanted[2] as! [String: Any])["name"] as? String == "no key")
        #expect(forSale.count == 2)
        #expect((forSale[0] as! [String: Any])["count"] as? Int == 2); #expect((forSale[1] as! [String: Any])["productID"] as? String == "1")
        #expect(sold.count == 3); #expect(sold[2] as? Int == 7)
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    /// A list of the wrong type makes the file one the app must not rewrite, as a malformed `collection` does; `null` is
    /// an empty list.
    @Test func aListOfTheWrongTypeRefusesTheFile() {
        #expect(throws: GameUserFileError.malformedList("wanted")) { try GameUserFile(data: Data(#"{"version":1,"wanted":3}"#.utf8)) }
        #expect(throws: GameUserFileError.malformedList("forSale")) { try GameUserFile(data: Data(#"{"forSale":{"a":1}}"#.utf8)) }
        #expect(throws: GameUserFileError.malformedList("sold")) { try GameUserFile(data: Data(#"{"sold":"x"}"#.utf8)) }
        #expect(throws: Never.self) { try GameUserFile(data: Data(#"{"wanted":null,"forSale":null,"sold":null}"#.utf8)) }
    }

    /// Two wanted entries of one card are summed into the first (its pin and position; an empty name is filled); two
    /// for-sale entries of one printing are summed; a for-sale finish and a pin's finish are trimmed, an empty one is
    /// `Normal`; an entry with a count under 1 is dropped.
    @Test func entriesOfOneKeyAreMergedOnRead() throws {
        let json = #"{"collection":[{"productID":1,"finish":"Foil","count":9}],"wanted":[{"cardKey":"a","name":"","count":1,"pinProductID":1,"pinFinish":" Foil "},{"cardKey":"b","name":"B","count":1},{"cardKey":"a","name":"A","count":2,"pinProductID":2,"pinFinish":"Normal"},{"cardKey":"z","name":"Z","count":0}],"forSale":[{"productID":1,"finish":" Foil ","count":1},{"productID":1,"finish":"Foil","count":2,"name":"F"},{"productID":3,"finish":"","count":1},{"productID":4,"finish":"Normal","count":0}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.wanted == [WantedEntry(cardKey: "a", name: "A", count: 3, pinProductID: 1, pinFinish: "Foil"),
                                WantedEntry(cardKey: "b", name: "B", count: 1, pinProductID: nil, pinFinish: nil)])
        #expect(file.forSale == [SaleEntry(productID: 1, finish: "Foil", count: 3, name: "F"),
                                 SaleEntry(productID: 3, finish: "Normal", count: 1, name: "")])
    }

    /// Review Focus 2: a file whose for-sale count is over its owned count (edited by hand, a conflict version) reads as
    /// it is; the library clamps it at the next change.
    @Test func forSaleOverTheCollectionReadsAsItIs() throws {
        let json = #"{"collection":[{"productID":1,"finish":"Normal","count":2}],"forSale":[{"productID":1,"finish":"Normal","count":5},{"productID":2,"finish":"Normal","count":1}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.forSale.map(\.count) == [5, 1])
    }

    /// A list key that is in the file stays there (also as `[]`); one that is not stays out while its list is empty.
    @Test func aListKeyStaysAsTheFileHasIt() throws {
        var file = try GameUserFile(data: Data(#"{"version":1,"collection":[],"wanted":[],"forSale":null}"#.utf8))
        var object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        #expect(Set(object.keys) == ["collection", "version", "wanted", "forSale"])
        #expect((object["wanted"] as? [Any])?.isEmpty == true); #expect((object["forSale"] as? [Any])?.isEmpty == true)
        file.sold = [SoldRecord(productID: 1, finish: "Normal", count: 1, name: "A", day: "2026-11-13", price: nil, priceIsLow: false)]
        object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        #expect((object["sold"] as? [Any])?.count == 1)
        file.sold = []
        object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        #expect(object["sold"] == nil)
    }

    /// A price is written as it reads (`0.07`), not with 17 digits (`0.070000000000000007`): the owner may correct the log
    /// by hand. It reads back as the same number.
    @Test func aSoldPriceIsWrittenShort() throws {
        var file = GameUserFile()
        file.sold = [0.07, 199.99, 3].map {
            SoldRecord(productID: 1, finish: "Normal", count: 1, name: "A", day: "2026-11-13", price: $0, priceIsLow: false)
        }
        let data = try file.data(), text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"price\" : 0.07,")); #expect(text.contains("\"price\" : 199.99,")); #expect(text.contains("\"price\" : 3,"))
        #expect(try GameUserFile(data: data).sold.map(\.price) == [0.07, 199.99, 3])
        #expect(try GameUserFile(data: data).data() == data)
    }

    /// Review Focus 1: the phase 2B build on the other device keeps the three lists as unknown keys while it changes a
    /// count. Its rewrite is JSONSerialization of the object it read, which turns a price 0.07 into 0.070000000000000007;
    /// JSONSerialization reads that back as an NSDecimalNumber whose `doubleValue` is not 0.07. The lists come back equal.
    @Test func aPhase2BRewriteKeepsTheThreeLists() throws {
        var file = GameUserFile()
        file.collection = [.init(productID: 1, finish: "Normal", count: 3, condition: "", name: "A")]
        file.wanted = [WantedEntry(cardKey: "a", name: "A", count: 2, pinProductID: 1, pinFinish: "Normal")]
        file.forSale = [SaleEntry(productID: 1, finish: "Normal", count: 2, name: "A")]
        file.sold = [0.07, 199.99, 12.34, 3].map {
            SoldRecord(productID: 1, finish: "Normal", count: 1, name: "A", day: "2026-11-13", price: $0, priceIsLow: false)
        }
        // What the phase 2B build's `data()` does: the object it read, its own collection, its options.
        var object = try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any]
        object["version"] = 1
        object["collection"] = [["productID": 1, "finish": "Normal", "count": 2, "condition": "", "name": "A"]]
        var rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        rewritten.append(0x0A)
        let back = try GameUserFile(data: rewritten)
        #expect(back.collection.map(\.count) == [2])
        #expect(back.wanted == file.wanted); #expect(back.forSale == file.forSale); #expect(back.sold == file.sold)
        #expect(String(decoding: try back.data(), as: UTF8.self).contains("\"price\" : 0.07,"))
    }

    /// The sold log is never merged: two equal records stay two, each with its own unknown keys.
    @Test func soldRecordsAreNeverMerged() throws {
        let json = #"{"sold":[{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","priceIsLow":false,"n":1},{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","priceIsLow":false,"n":2}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.sold.count == 2)
        file.sold.append(file.sold[0])
        let sold = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sold"] as! [[String: Any]]
        #expect(sold.map { $0["n"] as? Int } == [1, 2, nil])
    }
}
