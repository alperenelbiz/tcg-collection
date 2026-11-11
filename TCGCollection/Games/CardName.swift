import Foundation

nonisolated enum CardName {
    /// The product name without its trailing bracket groups, such as `(Borderless) (0329)` or
    /// `[1st Edition]`. Removal stops at a group whose text is in `game.keptBrackets` (any case).
    /// A name in `game.wholeNames`, a name that is only a bracket, or a bracket in the middle stays whole.
    static func base(_ productName: String, game: GameDefinition) -> String {
        var name = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !game.wholeNames.contains(name) else { return name }
        let kept = game.keptBrackets.map { $0.lowercased() }
        while let start = trailingGroupStart(name) {
            let inner = name[name.index(after: start)..<name.index(before: name.endIndex)]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if kept.contains(inner) { break }
            let rest = name[..<start].trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { break }
            name = rest
        }
        return name
    }

    /// Lowercase, accent-free text where every run of other characters is one space.
    static func searchKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = String(folded.unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " "
        })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Index of the opening bracket that matches the closing bracket at the end of `name`.
    private static func trailingGroupStart(_ name: String) -> String.Index? {
        guard let last = name.last, last == ")" || last == "]" else { return nil }
        var depth = 0
        var index = name.endIndex
        while index > name.startIndex {
            index = name.index(before: index)
            switch name[index] {
            case ")", "]": depth += 1
            case "(", "[":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}
