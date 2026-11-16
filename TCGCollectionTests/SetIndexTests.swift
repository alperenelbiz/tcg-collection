import Foundation
import Testing
@testable import TCGCollection2

struct SetIndexTests {
    private typealias Key = (number: String, name: String, id: Int)

    private func sorted(_ keys: [Key]) -> [Key] { keys.sorted(by: SetOrder.precedes) }

    @Test func numbersSortPieceByPiece() {
        let numbers = ["1", "2", "10", "10a", "BETB-EN001", "BETB-EN002", "T-01", ""]
        let keys = numbers.enumerated().map { (number: $0.element, name: "Card", id: $0.offset) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            #expect(sorted(keys.shuffled(using: &generator)).map(\.number) == numbers)
        }
    }

    @Test func aLetterAfterADigitRunComesBeforeTheNextNumber() {
        let keys: [Key] = [("3", "C", 3), ("2a", "B", 2), ("2", "A", 1)]
        #expect(sorted(keys).map(\.number) == ["2", "2a", "3"])
    }

    @Test func equalNumbersGoByNameThenID() {
        let keys: [Key] = [("5", "Beta", 1), ("5", "Alpha", 9), ("5", "Alpha", 3), ("", "Zed", 2), ("", "Abe", 7)]
        #expect(sorted(keys).map(\.id) == [3, 9, 1, 7, 2])
    }

    @Test func caseDoesNotMatter() {
        #expect(!SetOrder.precedes(("betb-en001", "A", 1), ("BETB-EN001", "A", 1)))
        #expect(!SetOrder.precedes(("BETB-EN001", "A", 1), ("betb-en001", "A", 1)))
        #expect(SetOrder.precedes(("betb-en001", "A", 1), ("BETB-EN002", "A", 1)))
        #expect(SetOrder.precedes(("BETB-EN002", "A", 1), ("betb-en010", "A", 1)))
        #expect(sorted([("t-01", "B", 2), ("T-01", "A", 1)]).map(\.id) == [1, 2])   // equal numbers: by name
    }

    /// Review Focus 3: mixed forms in one set give one order, the same on every run.
    @Test func mixedFormsKeepOneOrder() {
        let keys: [Key] = [("1", "A", 1), ("10", "B", 2), ("2a", "C", 3), ("", "D", 4), ("T-01", "E", 5),
                           ("BETB-EN010", "F", 6), ("2", "G", 7), ("02", "H", 8)]
        let first = sorted(keys).map(\.id)
        #expect(first == [1, 7, 8, 3, 2, 6, 5, 4])                    // "2" and "02" are equal numbers: by name
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 { #expect(sorted(keys.shuffled(using: &generator)).map(\.id) == first) }
    }

    @Test func aLongDigitRunDoesNotOverflow() {
        #expect(SetOrder.precedes(("99999999999999999999998", "A", 1), ("99999999999999999999999", "A", 2)))
        #expect(SetOrder.precedes(("9", "A", 1), ("99999999999999999999999", "A", 2)))
    }

    /// A number of only spaces is no number; spaces around a number do not count.
    @Test func numbersAreTrimmed() {
        let keys: [Key] = [("   ", "A", 1), (" 5", "B", 2), ("4 ", "C", 3), ("6", "D", 4), ("", "E", 5)]
        #expect(sorted(keys).map(\.id) == [3, 2, 4, 1, 5])
        #expect(!SetOrder.precedes(("5", "B", 2), (" 5", "B", 2)) && !SetOrder.precedes((" 5", "B", 2), ("5", "B", 2)))
    }

    /// The keyed sort (each product's pieces made once) gives the order of `precedes`.
    @Test func theKeyedSortGivesTheSameOrder() {
        let keys: [Key] = [("1", "A", 1), ("10", "B", 2), ("2a", "C", 3), ("", "D", 4), ("T-01", "E", 5),
                           ("BETB-EN010", "F", 6), ("2", "G", 7), ("02", "H", 8), (" 3 ", "I", 9), ("  ", "J", 10)]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let shuffled = keys.shuffled(using: &generator)
            #expect(SetOrder.sorted(shuffled) == sorted(shuffled).map(\.id))
        }
        #expect(SetOrder.sorted(keys) == [1, 7, 8, 3, 9, 2, 6, 5, 4, 10])
    }

    @Test func anIndexRoundTripsThroughItsFile() throws {
        let index = SetIndex(sets: [24819: [3, 1, 2], 7: [10]])
        let url = tempDir().appending(path: "sets-riftbound.json")
        try index.write(to: url)
        #expect(SetIndex.read(url) == index)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == #"{"sets":{"24819":[3,1,2],"7":[10]},"version":1}"#)
        #expect(index.products(of: 24819) == [3, 1, 2]); #expect(index.products(of: 1).isEmpty)
    }

    @Test func anotherVersionAMalformedFileAndNoFileReadAsNil() throws {
        let dir = tempDir()
        let newer = dir.appending(path: "newer.json")
        try Data(#"{"version":2,"sets":{"1":[1]}}"#.utf8).write(to: newer)
        #expect(SetIndex.read(newer) == nil)
        let malformed = dir.appending(path: "malformed.json")
        try Data(#"{"version":1,"sets":{"one":[1]}}"#.utf8).write(to: malformed)
        #expect(SetIndex.read(malformed) == nil)
        let notJSON = dir.appending(path: "not.json")
        try Data("not json".utf8).write(to: notJSON)
        #expect(SetIndex.read(notJSON) == nil)
        let noVersion = dir.appending(path: "no-version.json")
        try Data(#"{"sets":{"1":[1]}}"#.utf8).write(to: noVersion)
        #expect(SetIndex.read(noVersion) == nil)
        #expect(SetIndex.read(dir.appending(path: "missing.json")) == nil)
    }

    /// Only canonical decimal keys: "01", "+1" and " 1" would name set 1 a second time.
    @Test func aKeyThatIsNotCanonicalReadsAsNil() throws {
        let dir = tempDir()
        for (name, text) in [("zero", #"{"version":1,"sets":{"1":[1],"01":[2]}}"#),
                             ("plus", #"{"version":1,"sets":{"+1":[1]}}"#),
                             ("space", #"{"version":1,"sets":{" 1":[1]}}"#)] {
            let url = dir.appending(path: "\(name).json")
            try Data(text.utf8).write(to: url)
            #expect(SetIndex.read(url) == nil, "\(name)")
        }
        let good = dir.appending(path: "good.json")
        try Data(#"{"version":1,"sets":{"1":[1],"10":[2]}}"#.utf8).write(to: good)
        #expect(SetIndex.read(good) == SetIndex(sets: [1: [1], 10: [2]]))
    }

    /// Final fix A1: the stored value is the sets alone (no product -> set map is made at a decode); a changed `sets`
    /// is a changed index.
    @Test func theIndexIsItsSetsAlone() {
        let index = SetIndex(sets: [1: [10, 11], 2: [20]])
        #expect(Mirror(reflecting: index).children.map(\.label) == ["sets"])
        var changed = index
        changed.sets[3] = [30]
        changed.sets[2] = nil
        #expect(changed.sets == [1: [10, 11], 3: [30]])
        #expect(changed != index)
    }
}
