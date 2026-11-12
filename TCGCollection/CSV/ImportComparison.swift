import Foundation

/// What an import would do to one game's collection, shown before anything changes.
nonisolated struct ImportComparison: Sendable, Equatable {
    nonisolated struct Change: Sendable, Equatable, Identifiable {
        let key: PrintingKey
        let name: String
        /// The count in the collection (0 for a new printing).
        let old: Int
        /// The count in the file (0 for a missing printing).
        let new: Int
        let condition: String
        var id: PrintingKey { key }
    }

    let gameID: String
    /// In the file, not in the collection.
    let new: [Change]
    /// In both, with a different count.
    let changed: [Change]
    /// In the collection, not in the file. Nothing removes them unless the user chooses.
    let missing: [Change]
    let notRecognised: [SkippedLine]
    let ignoredBasics: [SkippedLine]
}

nonisolated enum CollectionImport {
    /// Splits the lines by game (through `Product Line`) and compares each game's printings with its rows.
    /// One comparison per game that has lines, in the order of `games`. `pricedFinishes` gives the finishes the price
    /// table has for a product, in their own spelling (`finish(_:)` of `compare(game:…)`).
    static func compare(lines: [CSVLine], current: [String: [CollectionRow]], known: (Int) -> ProductRecord?,
                        pricedFinishes: (Int) -> [String] = { _ in [] },
                        games: [GameDefinition]) -> (comparisons: [ImportComparison], otherGames: [SkippedLine]) {
        var byGame: [String: [CSVLine]] = [:]
        var otherGames: [SkippedLine] = []
        for line in lines {
            if let game = games.first(where: { g in g.productLines.contains { $0.caseInsensitiveCompare(line.productLine) == .orderedSame } }) {
                byGame[game.id, default: []].append(line)
            } else {
                otherGames.append(SkippedLine(line: line.line, name: line.name, reason: "not one of the four games"))
            }
        }
        let comparisons = games.compactMap { game in
            byGame[game.id].map {
                compare(game: game, lines: $0, rows: current[game.id] ?? [], known: known, pricedFinishes: pricedFinishes)
            }
        }
        return (comparisons, otherGames)
    }

    private struct Printing {
        var name: String
        var count = 0
        var conditions: [String] = []
    }

    private static func compare(game: GameDefinition, lines: [CSVLine], rows: [CollectionRow],
                                known: (Int) -> ProductRecord?, pricedFinishes: (Int) -> [String]) -> ImportComparison {
        var owned: [PrintingKey: CollectionRow] = [:]
        for row in rows where owned[row.key] == nil { owned[row.key] = row }
        // The finish of a line, matched ignoring case (the card page, the file's clean-up and the price lookup compare
        // it as written): a collection row's spelling of that product, else a priced finish's, else the file's, trimmed.
        // An earlier line's choice is kept with the rows' spellings, so lines that differ only by case sum into one row.
        var spellings: [Int: [String]] = [:]
        for row in rows { spellings[row.productID, default: []].append(row.finish) }
        func finish(_ line: CSVLine) -> String {
            let written = line.finish.trimmingCharacters(in: .whitespacesAndNewlines)
            let same = { (spelling: String) in spelling.caseInsensitiveCompare(written) == .orderedSame }
            if let chosen = spellings[line.productID]?.first(where: same) { return chosen }
            let chosen = pricedFinishes(line.productID).first(where: same) ?? written
            spellings[line.productID, default: []].append(chosen)
            return chosen
        }

        var listed: Set<PrintingKey> = []           // every printing the file names, imported or not
        var notRecognised: [SkippedLine] = []
        var ignoredBasics: [SkippedLine] = []
        var printings: [PrintingKey: Printing] = [:]
        for line in lines {
            let key = PrintingKey(productID: line.productID, finish: finish(line))
            listed.insert(key)
            guard let product = known(line.productID), product.gameID == game.id else {
                notRecognised.append(SkippedLine(line: line.line, name: line.name, reason: "not in the catalog"))
                continue
            }
            if game.altArtBasicsAreNormal, game.isBasicPrinting(product) {
                ignoredBasics.append(SkippedLine(line: line.line, name: line.name, reason: "basic rune"))
                continue
            }
            var entry = printings[key] ?? Printing(name: product.name)
            entry.count = min(entry.count + min(line.quantity, CollectionCSV.maxQuantity), CollectionCSV.maxQuantity)
            if !line.condition.isEmpty, !entry.conditions.contains(line.condition) { entry.conditions.append(line.condition) }
            printings[key] = entry
        }

        var new: [ImportComparison.Change] = [], changed: [ImportComparison.Change] = []
        for (key, entry) in printings {
            let condition = entry.conditions.joined(separator: ", ")
            if let row = owned[key] {
                if row.count != entry.count {
                    changed.append(.init(key: key, name: entry.name, old: row.count, new: entry.count,
                                         condition: condition.isEmpty ? row.condition : condition))
                }
            } else {
                new.append(.init(key: key, name: entry.name, old: 0, new: entry.count, condition: condition))
            }
        }
        // A file the catalog cannot read (nothing imported) never offers to remove anything.
        let missing = printings.isEmpty ? [] : owned.values.filter { !listed.contains($0.key) }
            .map { ImportComparison.Change(key: $0.key, name: $0.name, old: $0.count, new: 0, condition: $0.condition) }

        return ImportComparison(gameID: game.id, new: sorted(new), changed: sorted(changed), missing: sorted(missing),
                                notRecognised: notRecognised, ignoredBasics: ignoredBasics)
    }

    /// By name (any case), then finish, then product id.
    private static func sorted(_ changes: [ImportComparison.Change]) -> [ImportComparison.Change] {
        changes.sorted { a, b in
            let order = a.name.caseInsensitiveCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            if a.key.finish != b.key.finish { return a.key.finish < b.key.finish }
            return a.key.productID < b.key.productID
        }
    }

    /// The rows after the import. Rows keep their order; a changed row keeps its place and takes the file's count and
    /// condition; new rows are appended in the comparison's order; a `missing` row is removed only when its key is in
    /// `remove`; every other row is untouched. `rows` must be the rows of the comparison's own game (`gameID`):
    /// applying a comparison to another game's rows is the caller's error and is not guarded.
    static func apply(_ comparison: ImportComparison, to rows: [CollectionRow], remove: Set<PrintingKey>) -> [CollectionRow] {
        let changes = Dictionary(comparison.changed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let removable = Set(comparison.missing.map(\.key)).intersection(remove)
        var result: [CollectionRow] = []
        var present: Set<PrintingKey> = []
        for var row in rows {
            if removable.contains(row.key) { continue }
            if let change = changes[row.key] {
                row.count = change.new
                row.condition = change.condition
            }
            present.insert(row.key)
            result.append(row)
        }
        for change in comparison.new where !present.contains(change.key) {
            present.insert(change.key)
            result.append(CollectionRow(productID: change.key.productID, finish: change.key.finish, count: change.new,
                                        condition: change.condition, name: change.name))
        }
        return result
    }
}
