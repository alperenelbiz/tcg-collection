import Foundation
import Testing
@testable import TCGCollection2

/// G7–G9: what the player and collector roles show, and the decks every deck-derived number takes.
@MainActor
struct GameSectionsTests {
    private let playerOff = GameProfile(player: false)
    private let collectorOff = GameProfile(collector: false)
    private let bothOff = GameProfile(player: false, collector: false)

    private func deck(_ id: String, active: Bool = true, use: Int = 2) -> Deck {
        Deck(id: id, name: "Wind", format: "standard", active: active,
             cards: [DeckCard(cardKey: "dockside lock up", name: "Dockside Lock-Up", section: "main", count: use)])
    }

    /// The player role shows the decks; the collector role shows Sets; each alone.
    @Test func theRolesShowTheirSections() {
        #expect(GameSections.showsDecks(.all)); #expect(GameSections.showsSets(.all))
        #expect(!GameSections.showsDecks(playerOff)); #expect(GameSections.showsSets(playerOff))
        #expect(GameSections.showsDecks(collectorOff)); #expect(!GameSections.showsSets(collectorOff))
        #expect(!GameSections.showsDecks(bothOff)); #expect(!GameSections.showsSets(bothOff))
    }

    /// A deck screen without the player role, or of a deck that is gone, and Sets without the collector role open the
    /// Collection; with the role, as before. G9: with both roles off the Collection, Wanted, For Sale and All cards stay.
    @Test func aScreenOfARoleThatIsOffOpensTheCollection() {
        let exists: (String) -> Bool = { $0 == "a" }
        #expect(GameSections.screen(.deck("a"), profile: .all, deckExists: exists) == .deck("a"))
        #expect(GameSections.screen(.deck("b"), profile: .all, deckExists: exists) == .collection)
        #expect(GameSections.screen(.deck("a"), profile: playerOff, deckExists: exists) == .collection)
        #expect(GameSections.screen(.deck("a"), profile: collectorOff, deckExists: exists) == .deck("a"))
        #expect(GameSections.screen(.sets, profile: .all, deckExists: exists) == .sets)
        #expect(GameSections.screen(.sets, profile: playerOff, deckExists: exists) == .sets)
        #expect(GameSections.screen(.sets, profile: collectorOff, deckExists: exists) == .collection)
        for screen in [Screen.collection, .wanted, .forSale, .allCards] {
            #expect(GameSections.screen(screen, profile: bothOff, deckExists: { _ in false }) == screen, "\(screen)")
        }
        #expect(GameSections.screen(.sets, profile: bothOff, deckExists: exists) == .collection)
        #expect(GameSections.screen(.deck("a"), profile: bothOff, deckExists: exists) == .collection)
    }

    /// Phase 6A: the iPhone's deck list follows the player role, as a deck does.
    @Test func theDeckListFollowsThePlayerRole() {
        #expect(GameSections.screen(.decks, profile: .all, deckExists: { _ in false }) == .decks)
        #expect(GameSections.screen(.decks, profile: collectorOff, deckExists: { _ in false }) == .decks)
        #expect(GameSections.screen(.decks, profile: playerOff, deckExists: { _ in false }) == .collection)
        #expect(GameSections.screen(.decks, profile: bothOff, deckExists: { _ in false }) == .collection)
    }

    /// Without the player role no deck is in play; with it, every deck of the file, in its order.
    @Test func theDecksInPlayFollowThePlayerRole() {
        let decks = [deck("a"), deck("b", active: false)]
        #expect(GameSections.decks(decks, profile: .all) == decks)
        #expect(GameSections.decks(decks, profile: collectorOff) == decks)
        #expect(GameSections.decks(decks, profile: playerOff).isEmpty)
        #expect(GameSections.decks(decks, profile: bothOff).isEmpty)
    }

    /// The Sold dialog has no deck message without the player role (G7): its input is the decks in play.
    @Test func theSoldMessageIsNilWithoutThePlayerRole() {
        let riftbound = Games.game("riftbound")!
        let entry = CollectionEntry(row: CollectionRow(productID: 721334, finish: "Normal", count: 1, condition: "",
                                                       name: "Dockside Lock-Up"),
                                    product: product(id: 721334, name: "Dockside Lock-Up"), setName: "", price: nil,
                                    copiesOfCard: 2)
        let decks = [deck("a")]
        #expect(SaleList.soldMessage(for: entry, forSale: 1, game: riftbound,
                                     decks: GameSections.decks(decks, profile: .all), sharing: [:]) != nil)
        #expect(SaleList.soldMessage(for: entry, forSale: 1, game: riftbound,
                                     decks: GameSections.decks(decks, profile: playerOff), sharing: [:]) == nil)
    }

    /// Two active decks use 2 copies each of a card owned twice: one card pending. Without the player role the count is 0
    /// and the sidebar's watcher hands no count (nil), so no notice is said and the base of the role's time stays.
    @Test func noPendingCountWithoutThePlayerRole() {
        let decks = [deck("a"), deck("b")]
        let read = DeckRead(printings: ["dockside lock up": [product(id: 721334, name: "Dockside Lock-Up")]],
                            keys: ["dockside lock up"], ownedByCard: ["dockside lock up": 2], kinds: [:], basics: [])
        #expect(DeckPage.pendingCount(decks: GameSections.decks(decks, profile: .all), sharing: [:], read: read) == 1)
        #expect(DeckPage.pendingCount(decks: GameSections.decks(decks, profile: playerOff), sharing: [:], read: read) == 0)
        #expect(GameSections.watchedPendingCount(loaded: true, profile: .all, decks: decks, sharing: [:], read: read) == 1)
        #expect(GameSections.watchedPendingCount(loaded: true, profile: playerOff, decks: decks, sharing: [:], read: read) == nil)
        #expect(GameSections.watchedPendingCount(loaded: false, profile: .all, decks: decks, sharing: [:], read: read) == nil)
        #expect(GameSections.watchedPendingCount(loaded: true, profile: .all, decks: [deck("a", active: false)], sharing: [:],
                                                 read: nil) == 0)
    }
}
