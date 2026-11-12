import Foundation
import Testing
@testable import TCGCollection2

/// The Riftbound fixture's cards, a hand-made plain basic rune, a Yu-Gi-Oh! card and a Magic basic land.
private let knownProducts: [Int: ProductRecord] = {
    let data = try! fixture("products-89.json")
    var all = try! ProductParser.products(data, game: Games.game("riftbound")!).cards
    all.append(product(id: 900001, game: "riftbound", name: "Calm Rune", number: "R02", rarity: "Common", cardType: "Rune"))
    all.append(product(id: 800001, game: "yu-gi-oh", name: "Blue-Eyes White Dragon", cardType: "Normal Monster"))
    all.append(product(id: 900100, game: "magic-the-gathering", name: "Forest - Full Art", cardType: "Land"))
    return Dictionary(all.map { ($0.productID, $0) }, uniquingKeysWith: { first, _ in first })
}()

private func knownFixtureProducts(_ id: Int) -> ProductRecord? { knownProducts[id] }

private func line(_ n: Int = 2, id: Int, productLine: String = "Riftbound: League of Legends Trading Card Game",
                  name: String = "N", condition: String = "Near Mint", finish: String = "Normal", quantity: Int = 1) -> CSVLine {
    CSVLine(line: n, productID: id, productLine: productLine, name: name, setName: "", number: "", rarity: "",
            condition: condition, finish: finish, quantity: quantity)
}

private let current = ["riftbound": [CollectionRow(productID: 721334, finish: "Foil", count: 1, condition: "", name: "Dockside Lock-Up"),
                                     CollectionRow(productID: 555, finish: "Normal", count: 2, condition: "Mint", name: "Only Here")]]

struct ImportComparisonTests {
    private func riftboundComparison() throws -> ImportComparison {
        let lines = try CollectionCSV.parse(fixture("collection-riftbound.csv")).lines
        let (comparisons, other) = CollectionImport.compare(lines: lines, current: current, known: knownFixtureProducts, games: Games.all)
        #expect(other.isEmpty)
        return try #require(comparisons.first)
    }

    @Test func theThreeGroups() throws {
        let lines = try CollectionCSV.parse(fixture("collection-riftbound.csv")).lines
        let (comparisons, other) = CollectionImport.compare(lines: lines, current: current, known: knownFixtureProducts, games: Games.all)
        let c = try #require(comparisons.first); #expect(comparisons.count == 1 && other.isEmpty && c.gameID == "riftbound")
        #expect(c.changed.map { "\($0.key.productID) \($0.old)->\($0.new) \($0.condition)" } == ["721334 1->3 Near Mint, Lightly Played"])
        #expect(c.missing.map(\.key.productID) == [555]); #expect(c.notRecognised.map(\.reason) == ["not in the catalog"]); #expect(c.ignoredBasics.count == 1)
        #expect(c.new.map { "\($0.key.productID) \($0.name) \($0.old)->\($0.new)" } == ["722282 Calm Rune (R02a) 0->4", "721337 Kai'Sa, Rebel 0->3"])
        #expect(c.missing[0].name == "Only Here" && c.missing[0].old == 2 && c.missing[0].new == 0 && c.missing[0].condition == "Mint")
        #expect(c.notRecognised[0].line == 6 && c.ignoredBasics[0].reason == "basic rune" && c.ignoredBasics[0].line == 5)
    }

    @Test func applyingKeepsWhatTheUserKeeps() throws {                       // the anti-goal
        let c = try riftboundComparison()
        let rows = try #require(current["riftbound"])
        let kept = CollectionImport.apply(c, to: rows, remove: [])
        #expect(kept.map { "\($0.productID) \($0.finish) \($0.count)" } == ["721334 Foil 3", "555 Normal 2", "722282 Normal 4", "721337 Normal 3"])
        #expect(kept[1] == rows[1])                                           // a kept row is untouched
        #expect(kept[0].condition == "Near Mint, Lightly Played" && kept[0].name == "Dockside Lock-Up")
        #expect(kept[2] == CollectionRow(productID: 722282, finish: "Normal", count: 4, condition: "Near Mint", name: "Calm Rune (R02a)"))
        let removed = CollectionImport.apply(c, to: rows, remove: [PrintingKey(productID: 555, finish: "Normal")])
        #expect(removed.map(\.productID) == [721334, 722282, 721337] && removed.map(\.count) == [3, 4, 3])
        // a key in `remove` that is not in group 3 removes nothing
        let notMissing = CollectionImport.apply(c, to: rows, remove: [PrintingKey(productID: 721334, finish: "Foil")])
        #expect(notMissing.count == 4)
        // no row of a not-recognised or an ignored basic line
        for result in [kept, removed] { #expect(!result.contains { $0.productID == 999999 || $0.productID == 900001 }) }
    }

    @Test func aMixedFileSplitsByGame() throws {
        let (comparisons, other) = CollectionImport.compare(lines: try CollectionCSV.parse(fixture("collection-mixed.csv")).lines, current: [:], known: knownFixtureProducts, games: Games.all)
        #expect(comparisons.map(\.gameID) == ["yu-gi-oh", "riftbound"]); #expect(other.map(\.reason) == ["not one of the four games"])
        #expect(other.map(\.name) == ["Pikachu"] && other[0].line == 5)
        #expect(comparisons.map { $0.new.count } == [1, 2])
    }

    @Test func magicBasicLandsAreImported() {                                 // A8
        let magic = "Magic: The Gathering"
        let (comparisons, _) = CollectionImport.compare(lines: [line(id: 900100, productLine: magic, name: "Forest - Full Art", quantity: 3)],
                                                        current: [:], known: knownFixtureProducts, games: Games.all)
        #expect(comparisons.first?.new.map(\.key.productID) == [900100] && comparisons.first?.ignoredBasics.isEmpty == true)
        #expect(Games.game("magic-the-gathering")!.isBasicPrinting(knownProducts[900100]!))
    }

    @Test func aProductOfAnotherGameIsNotRecognised() {
        let (comparisons, _) = CollectionImport.compare(lines: [line(id: 800001, name: "Blue-Eyes")], current: [:], known: knownFixtureProducts, games: Games.all)
        #expect(comparisons.first?.gameID == "riftbound" && comparisons.first?.notRecognised.map(\.reason) == ["not in the catalog"])
        #expect(comparisons.first?.new.isEmpty == true)
    }

    @Test func aGameWithOnlyUnusableLinesStillGetsAComparison() {
        let (comparisons, _) = CollectionImport.compare(lines: [line(id: 999999)], current: [:], known: knownFixtureProducts, games: Games.all)
        #expect(comparisons.count == 1 && comparisons[0].new.isEmpty && comparisons[0].notRecognised.count == 1)
    }

    @Test func theSameCountIsInNoGroupAndFinishIsExact() {
        let rows = ["riftbound": [CollectionRow(productID: 721334, finish: "Foil", count: 2, condition: "", name: "Dockside Lock-Up"),
                                  CollectionRow(productID: 721337, finish: "normal", count: 1, condition: "", name: "Kai'Sa, Rebel")]]
        let lines = [line(id: 721334, finish: "Foil", quantity: 2), line(id: 721337, finish: "Normal", quantity: 1)]
        let c = CollectionImport.compare(lines: lines, current: rows, known: knownFixtureProducts, games: Games.all).comparisons[0]
        #expect(c.changed.isEmpty && c.new.map(\.key.finish) == ["Normal"] && c.missing.map(\.key.finish) == ["normal"])
    }

    @Test func conditionsAreDistinctInFirstSeenOrder() {
        let lines = [line(id: 721334, condition: "Near Mint"), line(id: 721334, condition: "Lightly Played"),
                     line(id: 721334, condition: "Near Mint"), line(id: 721334, condition: "")]
        let c = CollectionImport.compare(lines: lines, current: [:], known: knownFixtureProducts, games: Games.all).comparisons[0]
        #expect(c.new.map(\.new) == [4] && c.new.map(\.condition) == ["Near Mint, Lightly Played"])
    }

    @Test func groupsAreSortedByNameFinishThenProduct() {
        let lines = [line(id: 721337, finish: "Normal"), line(id: 721334, finish: "Normal"), line(id: 721334, finish: "Foil"), line(id: 722282)]
        let c = CollectionImport.compare(lines: lines, current: [:], known: knownFixtureProducts, games: Games.all).comparisons[0]
        #expect(c.new.map { "\($0.key.productID) \($0.key.finish)" } == ["722282 Normal", "721334 Foil", "721334 Normal", "721337 Normal"])
    }
}
