import Foundation

/// One line of a pasted deck text, with its line number (from 1).
nonisolated struct DeckTextLine: Sendable, Equatable {
    let number: Int
    let kind: Kind

    nonisolated enum Kind: Sendable, Equatable {
        /// `Main Deck:`: the cards below it are in this section, by the name as written.
        case section(String)
        /// `3 Card name`, `3x Card name` or `3<tab>Card name`: the count as written (0 and 500 too) and the name.
        case card(count: Int, name: String)
        /// A blank line, or a line starting with `#`.
        case note
        /// A non-empty line that is none of these, such as a name without a count: never read as one copy.
        case unreadable(String)
    }
}

/// The text of a deck as the owner's old files have it (the old app's `DeckFile`): a line ending with `:` starts a section,
/// a line `N Card name` is a card, a line starting with `#` and a blank line are notes. Pure.
nonisolated enum DeckText {
    static func parse(_ text: String) -> [DeckTextLine] {
        // `\r\n` is one Character, and a newline: Windows, old Mac and Unix line ends all split here.
        var raw = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if raw.last?.isEmpty == true { raw.removeLast() }          // the last line end adds no line
        return raw.enumerated().map { DeckTextLine(number: $0.offset + 1, kind: kind(String($0.element))) }
    }

    /// White space and a byte order mark (U+FEFF, at the text's start or a line's start).
    private static let blank = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static func kind(_ line: String) -> DeckTextLine.Kind {
        let trimmed = line.trimmingCharacters(in: blank)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return .note }
        if trimmed.hasSuffix(":") { return .section(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)) }
        return card(trimmed).map { .card(count: $0.count, name: $0.name) } ?? .unreadable(trimmed)
    }

    /// Leading ASCII digits, then an optional `x` (glued to them, or alone between white space: `4x Name`, `4 x Name`), then
    /// white space and a name.
    private static func card(_ line: String) -> (count: Int, name: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let count = Int(digits) else { return nil }
        var rest = line[digits.endIndex...]
        let spaced = rest.drop { $0.isWhitespace }
        if let x = spaced.first, x == "x" || x == "X", spaced.dropFirst().first?.isWhitespace == true { rest = spaced.dropFirst() }
        guard rest.first?.isWhitespace == true else { return nil }
        let name = rest.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (count, name)
    }

    /// True for an unreadable line that starts with a count too large for `Int` and goes on with a name.
    static func hasTooLargeCount(_ line: String) -> Bool {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && Int(digits) == nil && line[digits.endIndex...].first?.isWhitespace == true
    }
}
