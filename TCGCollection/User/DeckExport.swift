import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A80: a deck as the text the Paste… sheet reads (`DeckText`), for sending the cards to someone. Pure.
/// The format's sections in order, then sections the format lacks (by id, in the order first seen); each non-empty
/// section as `<name>:` and one `<count> <name>` line per card, by name (case and accents ignored, ties by card key); a
/// blank line between sections. No printing, no deck name. Cards this build cannot read are not in `deck.cards`.
nonisolated enum DeckExport {
    static func text(_ deck: Deck, format: DeckFormat) -> String {
        var order = format.sections.map { ($0.id, $0.name) }
        for card in deck.cards where !order.contains(where: { $0.0 == card.section }) {
            order.append((card.section, card.section))
        }
        let blocks = order.compactMap { id, name -> String? in
            let cards = deck.cards.filter { $0.section == id }.sorted { a, b in
                let (x, y) = (sortKey(a), sortKey(b))
                return x != y ? x < y : a.cardKey < b.cardKey
            }
            guard !cards.isEmpty else { return nil }
            return ([name + ":"] + cards.map { "\($0.count) \(shownName($0))" }).joined(separator: "\n")
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    private static func shownName(_ card: DeckCard) -> String {
        let name = card.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? card.cardKey : name
    }

    private static func sortKey(_ card: DeckCard) -> String {
        shownName(card).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The export sheet's Copy: writes the text through `write` (the pasteboard in the app; a fake in the tests, which must
/// not write the Mac's pasteboard) and says "Copied" until the view clears `copied`.
@Observable final class DeckExportCopy {
    var copied = false
    private let write: @MainActor (String) -> Void

    init(write: @escaping @MainActor (String) -> Void) { self.write = write }

    func copy(_ text: String) {
        write(text)
        copied = true
    }
}

/// The system pasteboard, plain text.
enum Pasteboard {
    static func write(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
