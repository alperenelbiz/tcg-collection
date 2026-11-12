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
}
