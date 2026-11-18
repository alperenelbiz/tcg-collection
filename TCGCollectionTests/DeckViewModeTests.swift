import Testing
@testable import TCGCollection2

/// A58: the deck page's view (gallery or list), one device preference for every deck; the gallery the first time.
struct DeckViewModeTests {
    @Test func anUnknownOrMissingValueIsTheGallery() {
        #expect(DeckViewMode(stored: nil) == .gallery)
        #expect(DeckViewMode(stored: "grid") == .gallery)
        #expect(DeckViewMode(stored: "") == .gallery)
        #expect(DeckViewMode(stored: "gallery") == .gallery)
        #expect(DeckViewMode(stored: "list") == .list)
        #expect(DeckViewMode.key == "deckViewMode")
        #expect(DeckViewMode.list.rawValue == "list")
    }
}
