import Foundation
import Testing
@testable import TCGCollection2

struct CollectionCSVTests {
    @Test func theOddFileParses() throws {                                    // Review Focus 2
        let (lines, skipped) = try CollectionCSV.parse(fixture("collection-odd.csv"))
        #expect(lines.map(\.name) == ["Heimerdinger, \"Academy\" Instructor", "Last Row"]); #expect(lines[0].quantity > 0)
        #expect(skipped.map(\.reason).sorted() == ["no product id", "quantity is 0", "quantity is not a number"])
        // lines are physical, 1-based, the header is line 1; the empty line 6 is counted
        #expect(lines.map(\.line) == [2, 7]); #expect(skipped.map(\.line) == [3, 4, 5])
        #expect(skipped.map(\.name) == ["Bad Quantity", "Zero Quantity", "No Id"])
    }

    @Test func totalQuantityIsTheFallbackAndPrintingDefaultsToNormal() throws {
        let lines = try CollectionCSV.parse(fixture("collection-riftbound.csv")).lines
        let last = try #require(lines.last)
        #expect(last.productID == 722282 && last.quantity == 4 && last.finish == "Normal")
        #expect(lines.first.map { ($0.productID, $0.quantity, $0.finish, $0.condition) }! == (721334, 2, "Foil", "Near Mint"))
        #expect(lines[0].productLine == "Riftbound: League of Legends Trading Card Game" && lines[0].setName == "Origins")
        #expect(lines[0].number == "136/167" && lines[0].rarity == "Epic")
    }

    @Test func aFileThatIsNotAnExportIsRefused() {
        #expect(throws: CollectionCSVError.notATCGplayerExport) { try CollectionCSV.parse(Data("name,count\nA,1".utf8)) }
        #expect(throws: CollectionCSVError.notATCGplayerExport) { try CollectionCSV.parse(Data()) }
        #expect(throws: CollectionCSVError.notATCGplayerExport) { try CollectionCSV.parse(Data("Product ID,Product Name\n1,A".utf8)) }
    }

    @Test func columnsAreFoundByNameInAnyOrderAndShortRowsReadEmpty() throws {
        let csv = "Printing,  product id ,EXTRA,Total Quantity,Product Name\nFoil,12,x,3,A\nFoil,13\n,14,,,B\n"
        let (lines, skipped) = try CollectionCSV.parse(Data(csv.utf8))
        #expect(lines.map { "\($0.productID) \($0.finish) \($0.quantity) \($0.name)" } == ["12 Foil 3 A"])
        #expect(skipped.map(\.reason) == ["quantity is not a number", "quantity is not a number"])
        #expect(skipped.map(\.name) == ["", "B"])
    }

    @Test func theQuantityRule() throws {
        let csv = "Product ID,Total Quantity,Add to Quantity\n1,9,2\n2,5,\n3,5,x\n4,5,2.0\n5,,\n6,3,-1\n7,3,0\n08,1,1\n9a,1,1\n"
        let (lines, skipped) = try CollectionCSV.parse(Data(csv.utf8))
        #expect(lines.map { "\($0.productID):\($0.quantity)" } == ["1:2", "2:5", "8:1"])
        #expect(skipped.map(\.reason) == ["quantity is not a number", "quantity is not a number", "quantity is not a number",
                                          "quantity is 0", "quantity is 0", "no product id"])
    }

    @Test func aQuotedLineBreakShiftsTheLaterLines() throws {
        let csv = "Product ID,Product Name,Add to Quantity\n1,\"two\nlines\",1\n2,B,x\n"
        #expect(try CollectionCSV.parse(Data(csv.utf8)).skipped.map(\.line) == [4])
    }

    @Test func aWindows1252FileParses() throws {
        var data = Data("Product ID,Product Name,Add to Quantity\n1,Caf".utf8); data.append(0xE9); data.append(Data(",1".utf8))
        #expect(try CollectionCSV.parse(data).lines.map(\.name) == ["Café"])
    }

    @Test func aBigFileParsesQuickly() throws {
        var csv = "Product ID,Product Name,Add to Quantity\n"
        for i in 1...20_000 { csv += "\(i),\"Name, \(i)\",1\n" }
        let start = ContinuousClock.now
        #expect(try CollectionCSV.parse(Data(csv.utf8)).lines.count == 20_000)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
