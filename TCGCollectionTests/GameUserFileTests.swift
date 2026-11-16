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

    /// Fix round 1: a sold record is never edited. A record with a key of its own that this build cannot read (a price as
    /// text or null, `priceIsLow` as a number or missing, `name` as a number) is kept as it is, raw, after the records
    /// read; a record with every key right is read.
    @Test func aSoldRecordWithAnUnreadableKeyIsKeptRaw() throws {
        let json = #"{"sold":[{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","price":"12.50","priceIsLow":false},{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","priceIsLow":1},{"productID":1,"finish":"Normal","count":1,"name":5,"day":"2026-11-13","priceIsLow":false},{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13","price":null,"priceIsLow":false},{"productID":1,"finish":"Normal","count":1,"name":"A","day":"2026-11-13"},{"productID":2,"finish":"Normal","count":1,"name":"B","day":"2026-11-13","price":2,"priceIsLow":true}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.sold == [SoldRecord(productID: 2, finish: "Normal", count: 1, name: "B", day: "2026-11-13", price: 2, priceIsLow: true)])
        file.sold.append(SoldRecord(productID: 3, finish: "Normal", count: 1, name: "C", day: "2026-11-14", price: nil, priceIsLow: false))
        let sold = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sold"] as! [[String: Any]]
        #expect(sold.count == 7)
        #expect(sold[0]["productID"] as? Int == 2); #expect(sold[1]["productID"] as? Int == 3)
        #expect(sold[2]["price"] as? String == "12.50")
        #expect(sold[3]["priceIsLow"] as? Int == 1); #expect(sold[3]["priceIsLow"] as? Bool != false)
        #expect(sold[4]["name"] as? Int == 5)
        #expect(sold[5]["price"] is NSNull)
        #expect(Set(sold[6].keys) == ["productID", "finish", "count", "name", "day"])
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    /// Fix round 1: a half pin (one of the two pin keys, or one of the wrong type) reads as no pin, and its keys stay in
    /// the file through other changes until the pin is set or cleared.
    @Test func aHalfPinIsKeptUntilThePinIsSetOrCleared() throws {
        let json = #"{"wanted":[{"cardKey":"a","name":"A","count":1,"pinProductID":3},{"cardKey":"b","name":"B","count":1,"pinProductID":"3","pinFinish":"Foil"},{"cardKey":"c","name":"C","count":1,"pinFinish":"Foil"},{"cardKey":"d","name":"D","count":1,"pinProductID":4,"pinFinish":"Foil"}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.wanted.map(\.pin) == [nil, nil, nil, PrintingKey(productID: 4, finish: "Foil")])
        #expect(file.wanted.prefix(3).allSatisfy { $0.pinProductID == nil && $0.pinFinish == nil })
        for i in file.wanted.indices { file.wanted[i].count = 2 }                // a change elsewhere on each entry
        var entries = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["wanted"] as! [[String: Any]]
        #expect(entries[0]["pinProductID"] as? Int == 3); #expect(entries[0]["pinFinish"] == nil)
        #expect(entries[1]["pinProductID"] as? String == "3"); #expect(entries[1]["pinFinish"] as? String == "Foil")
        #expect(entries[2]["pinProductID"] == nil); #expect(entries[2]["pinFinish"] as? String == "Foil")
        #expect(entries.map { $0["count"] as? Int } == [2, 2, 2, 2])
        #expect(try GameUserFile(data: try file.data()).wanted.map(\.pin) == file.wanted.map(\.pin))
        // Set on a; set then cleared on b; cleared on d (a whole pin): the half pins of a and b are gone, c keeps its own.
        file.wanted = ListRules.pinning(file.wanted, cardKey: "a", to: .init(productID: 7, finish: "Normal"))
        file.wanted = ListRules.pinning(file.wanted, cardKey: "b", to: .init(productID: 8, finish: "Foil"))
        file.wanted = ListRules.pinning(file.wanted, cardKey: "b", to: nil)
        file.wanted = ListRules.pinning(file.wanted, cardKey: "d", to: nil)
        entries = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["wanted"] as! [[String: Any]]
        #expect(entries[0]["pinProductID"] as? Int == 7); #expect(entries[0]["pinFinish"] as? String == "Normal")
        #expect(entries[1]["pinProductID"] == nil); #expect(entries[1]["pinFinish"] == nil)
        #expect(entries[2]["pinFinish"] as? String == "Foil")
        #expect(entries[3]["pinProductID"] == nil); #expect(entries[3]["pinFinish"] == nil)
    }

    /// Final fix B3: a `null` pin key is no pin key. An entry with `null` pin keys reads as unpinned and is not a half pin:
    /// the next write of the entry leaves no pin key. A half pin with one `null` key keeps its other key.
    @Test func aNullPinKeyIsNoPinKey() throws {
        let json = #"{"wanted":[{"cardKey":"a","name":"A","count":1,"pinProductID":null,"pinFinish":null},{"cardKey":"b","name":"B","count":1,"pinProductID":null,"pinFinish":"Foil"}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.wanted.map(\.pin) == [nil, nil])
        for i in file.wanted.indices { file.wanted[i].count = 2 }
        let entries = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["wanted"] as! [[String: Any]]
        #expect(Set(entries[0].keys) == ["cardKey", "name", "count"])
        #expect(entries[1]["pinFinish"] as? String == "Foil")
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

    // MARK: Phase 3A task 3: decks

    /// The exact text a phase 2C build writes with its three lists and no decks.
    private let phase2CText = """
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
          "forSale" : [
            {
              "count" : 1,
              "finish" : "Foil",
              "name" : "Dockside Lock-Up",
              "productID" : 721334
            }
          ],
          "sold" : [
            {
              "count" : 1,
              "day" : "2026-11-13",
              "finish" : "Foil",
              "name" : "Dockside Lock-Up",
              "price" : 0.07,
              "priceIsLow" : false,
              "productID" : 721334
            }
          ],
          "version" : 1,
          "wanted" : [
            {
              "cardKey" : "dockside lock-up",
              "count" : 2,
              "name" : "Dockside Lock-Up",
              "pinFinish" : "Foil",
              "pinProductID" : 721334
            }
          ]
        }

        """

    private let decksJSON = #"{"version":1,"collection":[{"productID":1,"finish":"Normal","count":2,"condition":"","name":"A"}],"decks":[{"id":"d1","name":"Burn","format":"constructed","active":true,"note":"deck note","cards":[{"cardKey":"bolt","name":"Lightning Bolt","section":"deck","count":4,"foil":true},{"cardKey":"ring","name":"Sol Ring","section":"deck","count":1},{"cardKey":"bolt","name":"Lightning Bolt","section":"sideboard","count":1}]},{"id":"d2","name":"Other","format":"future-format","active":false,"cards":[{"cardKey":"x","name":"X","section":"future-section","count":2}]}]}"#

    /// Review Focus 1: a phase 2C file opens with no decks, and a read and `data()` keep its exact bytes.
    @Test func aPhase2CFileReadsWithNoDecksAndKeepsItsBytes() throws {
        let file = try GameUserFile(data: Data(phase2CText.utf8))
        #expect(file.decks.isEmpty)
        #expect(file.wanted.count == 1 && file.forSale.count == 1 && file.sold.count == 1)
        #expect(try file.data() == Data(phase2CText.utf8))
    }

    /// Decks are read, written and read again unchanged; an unknown format or section id is kept as written.
    @Test func decksRoundTrip() throws {
        let file = try GameUserFile(data: Data(decksJSON.utf8))
        #expect(file.decks == [
            Deck(id: "d1", name: "Burn", format: "constructed", active: true, cards: [
                DeckCard(cardKey: "bolt", name: "Lightning Bolt", section: "deck", count: 4),
                DeckCard(cardKey: "ring", name: "Sol Ring", section: "deck", count: 1),
                DeckCard(cardKey: "bolt", name: "Lightning Bolt", section: "sideboard", count: 1)]),
            Deck(id: "d2", name: "Other", format: "future-format", active: false, cards: [
                DeckCard(cardKey: "x", name: "X", section: "future-section", count: 2)])])
        let data = try file.data()
        #expect(try GameUserFile(data: data) == file)
        #expect(try GameUserFile(data: data).data() == data)
        let decks = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["decks"] as! [[String: Any]]
        #expect(Set(decks[1].keys) == ["id", "name", "format", "active", "cards"])
        #expect(decks[1]["active"] as? Bool == false); #expect(decks[1]["format"] as? String == "future-format")
        let cards = decks[1]["cards"] as! [[String: Any]]
        #expect(Set(cards[0].keys) == ["cardKey", "name", "section", "count"])
        #expect(cards[0]["section"] as? String == "future-section")
    }

    /// A deck's own unknown keys and a deck card's unknown keys survive a change of another deck, a change of that deck,
    /// and a move of that card to another section.
    @Test func aDecksAndADeckCardsUnknownKeysSurviveAChange() throws {
        var file = try GameUserFile(data: Data(decksJSON.utf8))
        file.decks[1] = DeckRules.setting(file.decks[1], count: 3, cardKey: "x", name: "X", section: "future-section")
        func first() throws -> [String: Any] {
            ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]
        }
        var deck = try first(), cards = deck["cards"] as! [[String: Any]]
        #expect(deck["note"] as? String == "deck note"); #expect(cards[0]["foil"] as? Bool == true)
        file.decks[0].name = "Burn 2"
        file.decks[0] = DeckRules.setting(file.decks[0], count: 2, cardKey: "ring", name: "", section: "deck")
        file.decks[0] = DeckRules.setting(file.decks[0], count: 3, cardKey: "bolt", name: "", section: "deck")
        deck = try first(); cards = deck["cards"] as! [[String: Any]]
        #expect(deck["note"] as? String == "deck note"); #expect(deck["name"] as? String == "Burn 2")
        #expect(cards[0]["foil"] as? Bool == true); #expect(cards[0]["count"] as? Int == 3); #expect(cards[1]["foil"] == nil)
        // A move gives the card another key (card, section); its unknown keys go with it.
        file.decks[0] = DeckRules.moving(file.decks[0], cardKey: "bolt", from: "deck", to: "commander")
        cards = try first()["cards"] as! [[String: Any]]
        let moved = try #require(cards.first { $0["section"] as? String == "commander" })
        #expect(moved["foil"] as? Bool == true); #expect(moved["count"] as? Int == 3)
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    /// A deck that cannot be parsed (no `id`, `cards` not an array, a second deck of one id, not an object) is kept as
    /// written, in its order, after the parsed decks. An id addresses exactly one deck.
    @Test func unparseableDecksSurviveAtTheEnd() throws {
        let json = #"{"decks":[{"name":"no id","cards":[]},{"id":"c","name":"C","cards":"x"},{"id":"a","name":"A","format":"constructed","cards":[]},{"id":"a","name":"second A","cards":[]},7]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks.map(\.id) == ["a"]); #expect(file.decks[0].name == "A")
        file.decks[0].name = "A changed"
        let decks = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [Any]
        #expect(decks.count == 5)
        #expect((decks[0] as! [String: Any])["name"] as? String == "A changed")
        #expect((decks[1] as! [String: Any])["name"] as? String == "no id")
        #expect((decks[2] as! [String: Any])["cards"] as? String == "x")
        #expect((decks[3] as! [String: Any])["name"] as? String == "second A")
        #expect(Set((decks[3] as! [String: Any]).keys) == ["id", "name", "cards"])
        #expect(decks[4] as? Int == 7)
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    /// A deck card that cannot be parsed (no `cardKey`, a count that is not a whole number, no section) is kept as written
    /// inside its deck, after the parsed cards, through a change of that deck.
    @Test func unparseableDeckCardsSurviveInsideTheirDeck() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"constructed","cards":[{"name":"no key","section":"deck","count":1},{"cardKey":"b","section":"deck","count":"2"},"x",{"cardKey":"c","name":"C","section":"deck","count":1},{"cardKey":"d","name":"D","count":1}]}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks[0].cards.map(\.id) == ["c|deck"])
        file.decks[0] = DeckRules.setting(file.decks[0], count: 2, cardKey: "c", name: "", section: "deck")
        let cards = ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [Any]
        #expect(cards.count == 5)
        #expect((cards[0] as! [String: Any])["count"] as? Int == 2)
        #expect((cards[1] as! [String: Any])["name"] as? String == "no key")
        #expect((cards[2] as! [String: Any])["count"] as? String == "2")
        #expect(cards[3] as? String == "x")
        #expect((cards[4] as! [String: Any])["cardKey"] as? String == "d")
        #expect(try GameUserFile(data: try file.data()) == file)
    }

    /// Final fix B8: the count of a deck's cards this build cannot read (kept raw inside it), for the deck page's line. It
    /// holds through a change of the deck and is not written: the file's text keeps every raw card as it was.
    @Test func aDecksUnreadableCardsAreCounted() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"constructed","cards":[{"name":"no key","section":"deck","count":1},"x",{"cardKey":"c","name":"C","section":"deck","count":1}]},{"id":"b","name":"B","cards":[]}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.unreadableCards(deck: "a") == 2)
        #expect(file.unreadableCards(deck: "b") == 0 && file.unreadableCards(deck: "none") == 0)
        file.decks[0] = DeckRules.setting(file.decks[0], count: 3, cardKey: "c", name: "", section: "deck")
        #expect(file.unreadableCards(deck: "a") == 2)
        let written = String(decoding: try file.data(), as: UTF8.self)
        #expect(!written.contains("unreadable"))
        let again = try GameUserFile(data: try file.data())
        #expect(again.unreadableCards(deck: "a") == 2)
    }

    /// Final fix B9: a second deck of one id is kept raw; when the first deck of that id is deleted, the raw duplicate is
    /// deleted with it, so the deleted deck cannot come back at the next read. Other raw decks stay.
    @Test func aDeletedDecksRawDuplicateGoesWithIt() throws {
        let json = #"{"decks":[{"id":"a","name":"A","cards":[]},{"id":"b","name":"B","cards":[]},{"id":"a","name":"second A","cards":[]},{"name":"no id"},{"id":"b","name":"second B","cards":[]}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks.map(\.id) == ["a", "b"])
        file.decks.removeAll { $0.id == "a" }
        let text = String(decoding: try file.data(), as: UTF8.self)
        #expect(!text.contains("second A") && !text.contains(#""A""#))
        #expect(text.contains("second B") && text.contains("no id"))
        let again = try GameUserFile(data: try file.data())
        #expect(again.decks.map(\.id) == ["b"])
    }

    @Test func decksOfTheWrongTypeRefuseTheFile() {
        #expect(throws: GameUserFileError.malformedList("decks")) { try GameUserFile(data: Data(#"{"decks":3}"#.utf8)) }
        #expect(throws: GameUserFileError.malformedList("decks")) { try GameUserFile(data: Data(#"{"decks":{"id":"a"}}"#.utf8)) }
        #expect(throws: Never.self) { try GameUserFile(data: Data(#"{"decks":null}"#.utf8)) }
    }

    /// Two cards of one (card, section) are summed into the first (its name filled when empty); one card in two sections
    /// stays two cards; a card with a count under 1 is dropped.
    @Test func deckCardsOfOneKeyAreMergedOnRead() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"constructed","cards":[{"cardKey":"bolt","name":"","section":"deck","count":1,"k":"first"},{"cardKey":"bolt","name":"Bolt","section":"sideboard","count":1},{"cardKey":"bolt","name":"Bolt","section":"deck","count":2,"k":"second"},{"cardKey":"z","name":"Z","section":"deck","count":0}]}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks[0].cards == [DeckCard(cardKey: "bolt", name: "Bolt", section: "deck", count: 3),
                                        DeckCard(cardKey: "bolt", name: "Bolt", section: "sideboard", count: 1)])
        let card = (((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [[String: Any]])[0]
        #expect(card["k"] as? String == "first")
    }

    /// A missing or empty name reads as "Deck", a missing `active` as false, missing `cards` as no cards, a missing
    /// `format` as "" (the game's first format in the views).
    @Test func missingDeckFieldsHaveDefaults() throws {
        let json = #"{"decks":[{"id":"a"},{"id":"b","name":"","format":"commander","active":true,"cards":null}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks == [Deck(id: "a", name: "Deck", format: "", active: false, cards: []),
                               Deck(id: "b", name: "Deck", format: "commander", active: true, cards: [])])
    }

    /// A deck key that is in the file stays there (also as `[]`); one that is not stays out while there is no deck.
    @Test func theDecksKeyStaysAsTheFileHasIt() throws {
        var file = try GameUserFile(data: Data(#"{"version":1,"collection":[],"decks":[]}"#.utf8))
        #expect((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as? [Any] != nil)
        file = try GameUserFile(data: Data(#"{"version":1,"collection":[]}"#.utf8))
        file.decks = [DeckRules.new(name: "A", format: "standard", id: "a")]
        #expect(((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as? [Any])?.count == 1)
        file.decks = []
        #expect((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] == nil)
    }

    /// Equality sees a change of the decks alone, so the library writes it.
    @Test func aDeckOnlyChangeMakesTheFileDifferent() throws {
        let file = try GameUserFile(data: Data(decksJSON.utf8))
        var changed = file
        changed.decks[0].active = false
        #expect(changed != file)
        #expect(!changed.hasSameLists(as: file))
    }

    /// Review Focus 1: a phase 2C build on another device rewrites the file to change a collection count. It parses the
    /// whole object, changes `collection` and writes with its options: `decks` comes back byte-equal and reads the same.
    @Test func aPhase2CRewriteKeepsTheDecks() throws {
        let file = try GameUserFile(data: Data(decksJSON.utf8))
        let ours = try file.data()
        var object = try JSONSerialization.jsonObject(with: ours) as! [String: Any]
        object["version"] = 1
        object["collection"] = [["productID": 1, "finish": "Normal", "count": 3, "condition": "", "name": "A"]]
        var rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        rewritten.append(0x0A)
        func decksText(_ data: Data) throws -> Data {
            let decks = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["decks"]!
            return try JSONSerialization.data(withJSONObject: decks, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        #expect(try decksText(rewritten) == decksText(ours))
        let oursText = String(decoding: ours, as: UTF8.self), rewrittenText = String(decoding: rewritten, as: UTF8.self)
        let decksPart: (String) -> Substring = { $0[$0.range(of: "\"decks\"")!.lowerBound..<$0.range(of: "\"version\"")!.lowerBound] }
        #expect(decksPart(rewrittenText) == decksPart(oursText))
        let back = try GameUserFile(data: rewritten)
        #expect(back.collection.map(\.count) == [3]); #expect(back.decks == file.decks)
        #expect(try decksText(back.data()) == decksText(ours))
    }

    // MARK: Phase 3A feedback 1: a deck card's printing (A18)

    /// The exact text this build writes for a deck with one card on a chosen printing and one without.
    private let printingText = """
        {
          "collection" : [
            {
              "condition" : "",
              "count" : 1,
              "finish" : "1st Edition",
              "name" : "Swiftwind Panther Warrior",
              "productID" : 719834
            }
          ],
          "decks" : [
            {
              "active" : false,
              "cards" : [
                {
                  "cardKey" : "swiftwind panther warrior",
                  "count" : 2,
                  "name" : "Swiftwind Panther Warrior",
                  "productID" : 719834,
                  "section" : "main"
                },
                {
                  "cardKey" : "stardust dragon",
                  "count" : 1,
                  "name" : "Stardust Dragon",
                  "section" : "extra"
                }
              ],
              "format" : "standard",
              "id" : "yg1",
              "name" : "Wind"
            }
          ],
          "version" : 1
        }

        """

    /// A card's `productID` is read and written; a card without one is written without the key, so a file with decks
    /// and no chosen printing keeps its exact bytes through a read and a rewrite.
    @Test func aDeckCardsPrintingRoundTrips() throws {
        let file = try GameUserFile(data: Data(printingText.utf8))
        #expect(file.decks[0].cards.map(\.productID) == [719834, nil])
        #expect(try file.data() == Data(printingText.utf8))
        let without = try GameUserFile(data: Data(decksJSON.utf8))
        #expect(without.decks.flatMap(\.cards).allSatisfy { $0.productID == nil })
        let written = try without.data()
        #expect(try GameUserFile(data: written).data() == written)
        let cards = ((try JSONSerialization.jsonObject(with: written) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [[String: Any]]
        #expect(cards.allSatisfy { $0["productID"] == nil })
    }

    /// Equality and `hasSameLists` see a printing change alone, so the library writes it.
    @Test func aPrintingOnlyChangeMakesTheFileDifferent() throws {
        let file = try GameUserFile(data: Data(printingText.utf8))
        var changed = file
        changed.decks[0].cards[1].productID = 5
        #expect(changed != file)
        #expect(!changed.hasSameLists(as: file))
    }

    /// A `productID` this build cannot read (not a whole number) reads as no printing and is written back as it was through
    /// other changes, until the printing is set (or set and cleared). A `null` is no key: the next write leaves none.
    @Test func anUnreadablePrintingIsKeptUntilItIsSetOrCleared() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"standard","cards":[{"cardKey":"p","name":"P","section":"main","count":1,"productID":"719834"},{"cardKey":"q","name":"Q","section":"main","count":1,"productID":1.5},{"cardKey":"r","name":"R","section":"main","count":1,"productID":null},{"cardKey":"s","name":"S","section":"main","count":1,"productID":true}]}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks[0].cards.map(\.productID) == [nil, nil, nil, nil])
        func cards() throws -> [[String: Any]] {
            ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [[String: Any]]
        }
        for i in file.decks[0].cards.indices { file.decks[0].cards[i].count = 2 }        // a change elsewhere on each card
        var written = try cards()
        #expect(written[0]["productID"] as? String == "719834")
        #expect((written[1]["productID"] as? NSNumber)?.doubleValue == 1.5)
        #expect(written[2]["productID"] == nil && written[2].keys.contains("productID") == false)
        #expect((written[3]["productID"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
        #expect(written.map { $0["count"] as? Int } == [2, 2, 2, 2])
        #expect(try GameUserFile(data: try file.data()).decks == file.decks)
        // A move keeps the unreadable value with the card (its object goes with it).
        file.decks[0] = DeckRules.moving(file.decks[0], cardKey: "s", from: "main", to: "side")
        #expect((try cards().first { $0["cardKey"] as? String == "s" })?["productID"] != nil)
        // Set on p; set then cleared on q: the unreadable values are gone.
        file.decks[0] = DeckRules.settingPrinting(file.decks[0], key: DeckCardKey(cardKey: "p", section: "main"), productID: 7)
        file.decks[0] = DeckRules.settingPrinting(file.decks[0], key: DeckCardKey(cardKey: "q", section: "main"), productID: 8)
        file.decks[0] = DeckRules.settingPrinting(file.decks[0], key: DeckCardKey(cardKey: "q", section: "main"), productID: nil)
        written = try cards()
        #expect(written[0]["productID"] as? Int == 7)
        #expect(written[1].keys.contains("productID") == false)
        #expect(try GameUserFile(data: try file.data()).decks == file.decks)
    }

    /// Fix round 1: "Any printing" (`setPrinting(nil)`) on a card whose `productID` this build cannot read clears the raw
    /// key too, as Wanted's `setPin(nil)` does (final fix B3 of phase 2C). A card that is gone changes nothing.
    @Test func clearingAnUnreadablePrintingDropsItsKey() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"standard","cards":[{"cardKey":"p","name":"P","section":"main","count":1,"productID":"719834"},{"cardKey":"q","name":"Q","section":"main","count":1,"productID":"x"}]}]}"#
        let read = try GameUserFile(data: Data(json.utf8))
        var file = read
        file.setPrinting(nil, deck: "a", key: DeckCardKey(cardKey: "p", section: "main"))
        #expect(file != read)
        let cards = ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [[String: Any]]
        #expect(cards[0].keys.contains("productID") == false)
        #expect(cards[1]["productID"] as? String == "x")
        var again = file
        again.setPrinting(nil, deck: "a", key: DeckCardKey(cardKey: "p", section: "main"))
        #expect(again == file)
        var gone = read
        gone.setPrinting(nil, deck: "a", key: DeckCardKey(cardKey: "p", section: "side"))
        gone.setPrinting(5, deck: "none", key: DeckCardKey(cardKey: "p", section: "main"))
        #expect(gone == read)
        file.setPrinting(9, deck: "a", key: DeckCardKey(cardKey: "q", section: "main"))
        #expect(file.decks[0].cards.map(\.productID) == [nil, 9])
    }

    /// Fix round 2: the note "printing set or cleared" is per line (deck, card, section): setting and clearing the Side
    /// line's printing does not stop the Main line's unreadable value from being written back. A line moved after its
    /// printing was cleared keeps the note with its object.
    @Test func touchingOneLinesPrintingKeepsTheOtherLinesUnreadableValue() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"standard","cards":[{"cardKey":"p","name":"P","section":"main","count":1,"productID":"x"},{"cardKey":"p","name":"P","section":"side","count":1,"productID":"y"}]}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.setPrinting(4, deck: "a", key: DeckCardKey(cardKey: "p", section: "side"))
        file.setPrinting(nil, deck: "a", key: DeckCardKey(cardKey: "p", section: "side"))
        func cards() throws -> [[String: Any]] {
            ((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [[String: Any]]
        }
        var written = try cards()
        #expect(written[0]["productID"] as? String == "x")
        #expect(written[1].keys.contains("productID") == false)
        // The same through `decks` directly (the didSet's note).
        var other = try GameUserFile(data: Data(json.utf8))
        other.decks[0] = DeckRules.settingPrinting(other.decks[0], key: DeckCardKey(cardKey: "p", section: "side"), productID: 3)
        other.decks[0] = DeckRules.settingPrinting(other.decks[0], key: DeckCardKey(cardKey: "p", section: "side"), productID: nil)
        let otherCards = ((try JSONSerialization.jsonObject(with: try other.data()) as! [String: Any])["decks"] as! [[String: Any]])[0]["cards"] as! [[String: Any]]
        #expect(otherCards[0]["productID"] as? String == "x")
        #expect(otherCards[1].keys.contains("productID") == false)
        // The cleared Side line moved to a section of its own: its object goes with it, and so does the note.
        file.decks[0] = DeckRules.moving(file.decks[0], cardKey: "p", from: "side", to: "extra")
        written = try cards()
        #expect(written[0]["productID"] as? String == "x")
        #expect(written[1]["section"] as? String == "extra" && written[1].keys.contains("productID") == false)
    }

    /// Cards of one (card, section) summed on read: the first one's printing wins; a first without one takes the first
    /// later one that has one.
    @Test func mergedDeckCardsKeepTheFirstPrinting() throws {
        let json = #"{"decks":[{"id":"a","name":"A","format":"standard","cards":[{"cardKey":"p","name":"P","section":"main","count":1,"productID":3},{"cardKey":"p","name":"P","section":"main","count":1,"productID":4},{"cardKey":"q","name":"Q","section":"main","count":1},{"cardKey":"q","name":"Q","section":"main","count":1,"productID":"x"},{"cardKey":"q","name":"Q","section":"main","count":1,"productID":6},{"cardKey":"q","name":"Q","section":"main","count":1,"productID":7}]}]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.decks[0].cards == [DeckCard(cardKey: "p", name: "P", section: "main", count: 2, productID: 3),
                                        DeckCard(cardKey: "q", name: "Q", section: "main", count: 4, productID: 6)])
        #expect(try GameUserFile(data: try file.data()).decks == file.decks)
    }

    /// A phase 2C build (decks unknown) and a phase 3A build (`productID` an unknown key of a card) keep the key: the 2C
    /// rewrite gives `decks` back byte-equal; the 3A rewrite of a count change writes its four keys over the card's object.
    @Test func aPhase2CAnd3ARewriteKeepThePrinting() throws {
        let ours = Data(printingText.utf8)
        // Phase 3A: parse, change a card's count, write its own keys over the object it read, write with its options.
        var object = try JSONSerialization.jsonObject(with: ours) as! [String: Any]
        var decks = object["decks"] as! [[String: Any]]
        var cards = decks[0]["cards"] as! [[String: Any]]
        let known: [String: Any] = ["cardKey": "swiftwind panther warrior", "name": "Swiftwind Panther Warrior",
                                    "section": "main", "count": 3]
        cards[0] = cards[0].filter { !["cardKey", "name", "section", "count"].contains($0.key) }.merging(known) { _, new in new }
        decks[0]["cards"] = cards
        object["decks"] = decks
        var rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        rewritten.append(0x0A)
        let back = try GameUserFile(data: rewritten)
        #expect(back.decks[0].cards.map(\.productID) == [719834, nil])
        #expect(back.decks[0].cards.map(\.count) == [3, 1])
        // Phase 2C: `decks` is an unknown key, written back as read.
        var phase2C = try JSONSerialization.jsonObject(with: ours) as! [String: Any]
        phase2C["collection"] = [["productID": 1, "finish": "Normal", "count": 3, "condition": "", "name": "A"]]
        var rewritten2C = try JSONSerialization.data(withJSONObject: phase2C, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        rewritten2C.append(0x0A)
        let text = String(decoding: rewritten2C, as: UTF8.self), oursText = String(decoding: ours, as: UTF8.self)
        let decksPart: (String) -> Substring = { $0[$0.range(of: "\"decks\"")!.lowerBound..<$0.range(of: "\"version\"")!.lowerBound] }
        #expect(decksPart(text) == decksPart(oursText))
        #expect(try GameUserFile(data: rewritten2C).decks == GameUserFile(data: ours).decks)
    }

    // MARK: Phase 3B task 2: the sharing answers (E1)

    private let sharingJSON = #"{"version":1,"collection":[{"productID":1,"finish":"Normal","count":2,"condition":"","name":"A"}],"sharing":[{"cardKey":"a","shared":true,"note":"kept"},{"cardKey":"b","shared":false}]}"#

    /// A phase 3A file (decks, no `sharing`) opens with no answers, and a read and `data()` keep its exact bytes.
    @Test func aPhase3AFileReadsWithNoSharingAndKeepsItsBytes() throws {
        let file = try GameUserFile(data: Data(printingText.utf8))
        #expect(file.sharing.isEmpty)
        #expect(file.decks.count == 1)
        #expect(try file.data() == Data(printingText.utf8))
    }

    /// Answers are read, written and read again unchanged; an entry's unknown key survives a change of its answer.
    @Test func sharingRoundTrips() throws {
        var file = try GameUserFile(data: Data(sharingJSON.utf8))
        #expect(file.sharing == [SharingEntry(cardKey: "a", shared: true), SharingEntry(cardKey: "b", shared: false)])
        let data = try file.data()
        #expect(try GameUserFile(data: data) == file)
        #expect(try GameUserFile(data: data).data() == data)
        func entries() throws -> [[String: Any]] {
            (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] as! [[String: Any]]
        }
        var written = try entries()
        #expect(written[0]["note"] as? String == "kept")
        #expect(Set(written[1].keys) == ["cardKey", "shared"])
        #expect(written[1]["shared"] as? Bool == false)
        #expect((written[1]["shared"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
        file.sharing[0].shared = false
        written = try entries()
        #expect(written[0]["note"] as? String == "kept"); #expect(written[0]["shared"] as? Bool == false)
        #expect(try GameUserFile(data: try file.data()).sharing == file.sharing)
    }

    /// E1: a second entry of a card key, an entry with an unreadable answer and a non-object are kept as written, in their
    /// order, after the parsed entries; the first entry of a card wins.
    @Test func aSecondEntryOfACardAndAnUnreadableOneAreKeptRaw() throws {
        let json = #"{"version":1,"sharing":[{"cardKey":"a","shared":true},{"cardKey":"a","shared":false},{"cardKey":"c","shared":"yes"},7]}"#
        let file = try GameUserFile(data: Data(json.utf8))
        #expect(file.sharing == [SharingEntry(cardKey: "a", shared: true)])
        #expect(Dictionary(uniqueKeysWithValues: file.sharing.map { ($0.cardKey, $0.shared) }) == ["a": true])
        let written = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] as! [Any]
        #expect(written.count == 4)
        #expect((written[0] as! [String: Any])["shared"] as? Bool == true)
        #expect((written[1] as! [String: Any])["cardKey"] as? String == "a")
        #expect((written[1] as! [String: Any])["shared"] as? Bool == false)
        #expect((written[2] as! [String: Any])["shared"] as? String == "yes")
        #expect(written[3] as? Int == 7)
        #expect(try GameUserFile(data: try file.data()) == file)
        // A number is no answer: `1` is not `true`.
        #expect(try GameUserFile(data: Data(#"{"sharing":[{"cardKey":"a","shared":1}]}"#.utf8)).sharing.isEmpty)
    }

    /// The rule of decks (final fix B9): when the parsed answer of a card is removed, a second entry of that card kept raw
    /// goes with it, so the removed answer cannot come back (flipped) at the next read. Other raw entries stay.
    @Test func aRemovedAnswersRawDuplicateGoesWithIt() throws {
        let json = #"{"version":1,"sharing":[{"cardKey":"a","shared":true},{"cardKey":"b","shared":true},{"cardKey":"a","shared":false},{"cardKey":"b","shared":false},"x"]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.sharing.removeAll { $0.cardKey == "a" }
        let written = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] as! [Any]
        #expect(written.count == 3)
        #expect((written[0] as! [String: Any])["cardKey"] as? String == "b")
        #expect((written[1] as! [String: Any])["cardKey"] as? String == "b")
        #expect(written[2] as? String == "x")
        let again = try GameUserFile(data: try file.data())
        #expect(again.sharing == [SharingEntry(cardKey: "b", shared: true)])
    }

    /// Final fix A4 (a): a card whose answer was removed and then answered again in the same run does not get its dropped
    /// raw duplicate back: the removal is remembered since the read.
    @Test func aCardAnsweredAgainAfterARemovalDoesNotGetItsDuplicateBack() throws {
        let json = #"{"version":1,"sharing":[{"cardKey":"a","shared":true},{"cardKey":"a","shared":false}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.sharing.removeAll { $0.cardKey == "a" }
        file.sharing.append(SharingEntry(cardKey: "a", shared: true))
        let written = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] as! [Any]
        #expect(written.count == 1)
        #expect((written[0] as! [String: Any])["shared"] as? Bool == true)
        #expect(try GameUserFile(data: try file.data()).sharing == [SharingEntry(cardKey: "a", shared: true)])
    }

    /// Final fix A4 (b): only a true second answer of the removed card goes (its `shared` a JSON boolean); an entry of that
    /// card with an unreadable answer, and one without `shared`, are kept raw.
    @Test func aRemovedAnswerTakesOnlyItsBooleanDuplicates() throws {
        let json = #"{"version":1,"sharing":[{"cardKey":"a","shared":true},{"cardKey":"a","shared":false},{"cardKey":"a","shared":"ask"},{"cardKey":"a","note":"no answer"}]}"#
        var file = try GameUserFile(data: Data(json.utf8))
        file.sharing.removeAll { $0.cardKey == "a" }
        let written = (try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] as! [Any]
        #expect(written.count == 2)
        #expect((written[0] as! [String: Any])["shared"] as? String == "ask")
        #expect((written[1] as! [String: Any])["note"] as? String == "no answer")
        #expect(try GameUserFile(data: try file.data()).sharing.isEmpty)
    }

    /// `sharing` that is neither an array nor null refuses the file; `null` reads as none, and the key is written back as
    /// `[]` (the file had it). A file without the key gets it once there is an answer, and loses it again with none.
    @Test func sharingThatIsNoListRefusesTheFile() throws {
        #expect(throws: GameUserFileError.malformedList("sharing")) { try GameUserFile(data: Data(#"{"sharing":{}}"#.utf8)) }
        #expect(throws: GameUserFileError.malformedList("sharing")) { try GameUserFile(data: Data(#"{"sharing":true}"#.utf8)) }
        let null = try GameUserFile(data: Data(#"{"version":1,"sharing":null}"#.utf8))
        #expect(null.sharing.isEmpty)
        #expect((try JSONSerialization.jsonObject(with: try null.data()) as! [String: Any])["sharing"] as? [Any] != nil)
        #expect(((try JSONSerialization.jsonObject(with: try null.data()) as! [String: Any])["sharing"] as? [Any])?.isEmpty == true)
        var file = try GameUserFile(data: Data(#"{"version":1,"collection":[]}"#.utf8))
        file.sharing = [SharingEntry(cardKey: "a", shared: true)]
        #expect(((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] as? [Any])?.count == 1)
        file.sharing = []
        #expect((try JSONSerialization.jsonObject(with: try file.data()) as! [String: Any])["sharing"] == nil)
    }

    /// Equality and `hasSameLists` see a change of the answers alone, so the library writes it.
    @Test func aSharingOnlyChangeMakesTheFileDifferent() throws {
        let file = try GameUserFile(data: Data(sharingJSON.utf8))
        var changed = file
        changed.sharing[1].shared = true
        #expect(changed != file)
        #expect(!changed.hasSameLists(as: file))
    }

    /// A phase 3A build on another device rewrites the file to change a collection count: it parses the whole object,
    /// changes `collection` and writes with its options. `sharing` (an unknown key there) comes back byte-equal and reads
    /// the same.
    @Test func aPhase3ARewriteKeepsSharing() throws {
        let file = try GameUserFile(data: Data(sharingJSON.utf8))
        let ours = try file.data()
        var object = try JSONSerialization.jsonObject(with: ours) as! [String: Any]
        object["version"] = 1
        object["collection"] = [["productID": 1, "finish": "Normal", "count": 3, "condition": "", "name": "A"]]
        var rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        rewritten.append(0x0A)
        let oursText = String(decoding: ours, as: UTF8.self), rewrittenText = String(decoding: rewritten, as: UTF8.self)
        let sharingPart: (String) -> Substring = { $0[$0.range(of: "\"sharing\"")!.lowerBound..<$0.range(of: "\"version\"")!.lowerBound] }
        #expect(sharingPart(rewrittenText) == sharingPart(oursText))
        let back = try GameUserFile(data: rewritten)
        #expect(back.collection.map(\.count) == [3]); #expect(back.sharing == file.sharing)
        let backText = String(decoding: try back.data(), as: UTF8.self)
        #expect(sharingPart(backText) == sharingPart(oursText))
    }
}
