import Foundation

nonisolated enum CardName {
    /// The product name without its trailing bracket groups, such as `(Borderless) (0329)` or
    /// `[1st Edition]`. A group whose text is in `game.keptBrackets` (any case) survives wherever it
    /// stands in the run, once, at the end of the name. Removal stops when the rest is in `game.wholeNames`.
    /// A name that is only a bracket, or has a bracket in the middle, stays whole.
    static func base(_ productName: String, game: GameDefinition) -> String {
        var name = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = game.keptBrackets.map { $0.lowercased() }
        var keptGroup: String?
        while !game.wholeNames.contains(name), let start = trailingGroupStart(name) {
            let rest = name[..<start].trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { break }
            let group = String(name[start...])
            let inner = group.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
            if keptGroup == nil, kept.contains(inner) { keptGroup = group }
            name = rest
        }
        return keptGroup.map { "\(name) \($0)" } ?? name
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
