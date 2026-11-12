import Foundation

nonisolated enum CollectionCSVError: Error, Equatable {
    /// The file is empty, is not text, or its header has no `Product ID` or no quantity column.
    case notATCGplayerExport
}

/// One usable row of a TCGplayer collection export.
nonisolated struct CSVLine: Sendable, Equatable {
    /// The 1-based physical line the row starts on (the header is line 1).
    let line: Int
    let productID: Int
    let productLine: String
    let name: String
    let setName: String
    let number: String
    let rarity: String
    let condition: String
    /// The `Printing` cell; `Normal` when empty.
    let finish: String
    let quantity: Int
}

/// A row that is not imported, with the reason a person can read.
nonisolated struct SkippedLine: Sendable, Equatable {
    let line: Int
    let name: String
    let reason: String
}

nonisolated enum CollectionCSV {
    /// Reads a TCGplayer collection export. Columns are found by header name (trimmed, any case, any order).
    /// Quantity: `Add to Quantity` when it is not empty, else `Total Quantity`; it must be a whole number above 0.
    /// `lines` and `skipped` are in file order.
    static func parse(_ data: Data) throws -> (lines: [CSVLine], skipped: [SkippedLine]) {
        guard let text = CSVText.text(data) else { throw CollectionCSVError.notATCGplayerExport }
        let records = CSVText.records(text)
        guard let header = records.first else { throw CollectionCSVError.notATCGplayerExport }

        var index: [String: Int] = [:]
        for (i, name) in header.cells.enumerated() {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if index[key] == nil { index[key] = i }
        }
        let idColumn = index["product id"]
        let addColumn = index["add to quantity"], totalColumn = index["total quantity"]
        guard let idColumn, addColumn != nil || totalColumn != nil else { throw CollectionCSVError.notATCGplayerExport }

        func cell(_ cells: [String], _ column: Int?) -> String {
            guard let column, column < cells.count else { return "" }
            return cells[column].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [CSVLine] = []
        var skipped: [SkippedLine] = []
        for record in records.dropFirst() {
            let cells = record.cells
            let name = cell(cells, index["product name"])
            func skip(_ reason: String) { skipped.append(SkippedLine(line: record.line, name: name, reason: reason)) }

            let idText = cell(cells, idColumn)
            guard !idText.isEmpty, idText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let productID = Int(idText) else {
                skip("no product id"); continue
            }
            let add = cell(cells, addColumn)
            let quantityText = add.isEmpty ? cell(cells, totalColumn) : add
            guard !quantityText.hasPrefix("+"), let quantity = Int(quantityText) else {      // "2.0" and "+2" are not whole numbers here
                skip("quantity is not a number"); continue
            }
            guard quantity > 0 else { skip("quantity is 0"); continue }

            let printing = cell(cells, index["printing"])
            lines.append(CSVLine(line: record.line, productID: productID, productLine: cell(cells, index["product line"]),
                                 name: name, setName: cell(cells, index["set name"]), number: cell(cells, index["number"]),
                                 rarity: cell(cells, index["rarity"]), condition: cell(cells, index["condition"]),
                                 finish: printing.isEmpty ? "Normal" : printing, quantity: quantity))
        }
        return (lines, skipped)
    }
}
