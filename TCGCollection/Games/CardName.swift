import Foundation

nonisolated enum CardName {
    /// The product name without every trailing bracket group, such as `(Borderless) (0329)` or
    /// `[1st Edition]`. A name that is only a bracket, or has the bracket in the middle, stays whole.
    static func base(_ productName: String) -> String {
        var name = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        while let start = trailingGroupStart(name) {
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
