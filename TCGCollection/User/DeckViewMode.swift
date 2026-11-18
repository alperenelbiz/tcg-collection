import Foundation

/// A58: how the deck page lays out its cards: the gallery (cells with pictures) or the list (one row per card). One choice
/// for every deck, kept on this device only (a preference, `key`), never in the user folder. The first time, the gallery.
nonisolated enum DeckViewMode: String, Sendable, CaseIterable {
    case gallery, list

    /// The preference's key.
    static let key = "deckViewMode"

    /// The stored value; nil or a value this build does not know is the gallery.
    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .gallery
    }
}
