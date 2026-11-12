import Foundation
import Testing
@testable import TCGCollection2

struct CSVTextTests {
    @Test func quotesCommasAndLineEnds() {
        #expect(CSVText.rows("a,b\r\n\"x, \"\"y\"\"\",2\n\n\"multi\nline\",3") == [["a", "b"], ["x, \"y\"", "2"], ["multi\nline", "3"]])
        #expect(CSVText.rows("\u{FEFF}a,b\n1,2") == [["a", "b"], ["1", "2"]]); #expect(CSVText.rows("") == []); #expect(CSVText.rows("a,,c") == [["a", "", "c"]])
    }

    @Test func recordsKnowTheirPhysicalLine() {
        let records = CSVText.records("h\r\n\"two\nlines\",1\n\nnext\r\nlast")
        #expect(records.map(\.line) == [1, 2, 5, 6])
        #expect(CSVText.records("a\rb").map(\.line) == [1, 2])
    }

    @Test func aQuotedEmptyCellIsNotAnEmptyLine() {
        #expect(CSVText.rows("a\n\"\"\nb") == [["a"], [""], ["b"]])
        #expect(CSVText.rows("a,b,\n") == [["a", "b", ""]])
    }

    @Test func textDecodesUTF8ThenWindows1252() {
        #expect(CSVText.text(Data("café".utf8)) == "café")
        #expect(CSVText.text(Data([0x63, 0x61, 0x66, 0xE9])) == "café")          // Windows-1252 é
        #expect(CSVText.text(Data()) == "")
    }

    @Test func textFallsBackToLatin1ForUndefinedWindows1252Bytes() {
        #expect(CSVText.text(Data([0x61, 0x81, 0x62])) == "a\u{81}b")
    }

    @Test func anUnterminatedQuoteIsReportedWithItsLine() {
        let scan = CSVText.scan("h\n1,\"abc\n2,x\n3,y")
        #expect(scan.records.map(\.cells) == [["h"]] && scan.unterminatedQuoteAt == 2)
        let ok = CSVText.scan("h\n1,\"a\"\"b\" c\n2,x")
        #expect(ok.unterminatedQuoteAt == nil && ok.records.count == 3)
    }
}
