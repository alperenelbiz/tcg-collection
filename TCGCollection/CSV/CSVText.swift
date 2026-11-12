import Foundation

/// A small RFC 4180 reader: quoted fields, `""` inside quotes, commas and line breaks inside quotes,
/// CRLF, LF or a lone CR as a record end, a leading UTF-8 BOM, a last record without a line break.
nonisolated enum CSVText {
    /// One record: its cells and the 1-based physical line it starts on.
    struct Record: Equatable {
        let line: Int
        let cells: [String]
    }

    /// The cells of every non-empty record. An empty line (no cell text, no quotes) is skipped.
    static func rows(_ text: String) -> [[String]] {
        records(text).map(\.cells)
    }

    /// The text of a file: UTF-8 (with or without a BOM), else Windows-1252. Nil when neither fits.
    static func text(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// Like `rows`, with the physical line each record starts on (a quoted line break counts as a line).
    /// One pass over the UTF-8 bytes.
    static func records(_ text: String) -> [Record] {
        let bytes = Array(text.utf8)
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
        var records: [Record] = []
        var cells: [String] = []
        var cell: [UInt8] = []
        var inQuotes = false
        var cellQuoted = false          // the current cell opened with a quote
        var rowQuoted = false           // any cell of the record used quotes
        var line = 1
        var recordLine = 1
        var i = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }

        func endCell() {
            cells.append(String(decoding: cell, as: UTF8.self))
            cell.removeAll(keepingCapacity: true)
            cellQuoted = false
        }
        func endRecord(nextLine: Int) {
            endCell()
            if !(cells.count == 1 && cells[0].isEmpty && !rowQuoted) {
                records.append(Record(line: recordLine, cells: cells))
            }
            cells = []
            rowQuoted = false
            recordLine = nextLine
        }

        while i < bytes.count {
            let b = bytes[i]
            if inQuotes {
                if b == quote {
                    if i + 1 < bytes.count, bytes[i + 1] == quote { cell.append(quote); i += 1 } else { inQuotes = false }
                } else {
                    cell.append(b)
                    if b == lf { line += 1 } else if b == cr, !(i + 1 < bytes.count && bytes[i + 1] == lf) { line += 1 }
                }
            } else if b == quote, cell.isEmpty, !cellQuoted {
                inQuotes = true; cellQuoted = true; rowQuoted = true
            } else if b == comma {
                endCell()
            } else if b == lf || b == cr {
                if b == cr, i + 1 < bytes.count, bytes[i + 1] == lf { i += 1 }
                line += 1
                endRecord(nextLine: line)
            } else {
                cell.append(b)
            }
            i += 1
        }
        if !cell.isEmpty || !cells.isEmpty || rowQuoted { endRecord(nextLine: line) }
        return records
    }
}
