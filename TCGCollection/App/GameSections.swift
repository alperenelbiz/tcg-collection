import Foundation

/// Which sections of a game the app shows, from the game's roles (G7–G9). Pure.
/// - The player role: everything about decks (the sidebar's Decks section, a deck screen, the card page's "Decks" block,
///   "Add to deck" and the sharing line, Wanted's decks' part, the Sold dialog's deck message, the sharing notice).
/// - The collector role: Sets (the sidebar's row, the Sets screen, the game's set-index scan).
/// Both may be off (G9): the game then has the Collection, Wanted (hand-added), For Sale and All cards. A role turned off
/// hides and stops; it never deletes: the decks and answers stay in the file and come back with the role.
nonisolated enum GameSections {
    /// G7: the game's deck sections are shown.
    static func showsDecks(_ profile: GameProfile) -> Bool { profile.player }

    /// G8: the game's Sets row and screen are shown, and its set index is made.
    static func showsSets(_ profile: GameProfile) -> Bool { profile.collector }

    /// B2 (final fix): a deck sheet's write action may write to the game: it is followed and has the player role.
    static func decksWritable(_ profile: GameProfile, followed: Bool) -> Bool { followed && showsDecks(profile) }

    /// The screen to show when `asked` is wanted (stored, launched, or on screen): a deck screen without the player role,
    /// or of a deck that is gone (`deckExists` false), and Sets without the collector role open the Collection; any other
    /// screen is itself.
    static func screen(_ asked: Screen, profile: GameProfile, deckExists: (String) -> Bool) -> Screen {
        switch asked {
        case .deck(let id): showsDecks(profile) && deckExists(id) ? asked : .collection
        case .sets: showsSets(profile) ? asked : .collection
        case .collection, .wanted, .forSale, .allCards: asked
        }
    }

    /// The decks every deck-derived number and view takes (G7): the game's decks with the player role, none without it.
    static func decks(_ decks: [Deck], profile: GameProfile) -> [Deck] {
        showsDecks(profile) ? decks : []
    }

    /// E8, the count the sidebar's watcher hands to `AppModel.pendingCountChanged`: nil while it is not known (the folder
    /// not read, no read of the active decks) and without the player role (G7: no sharing notice; the base of the role's
    /// time stays, so turning the role on again says nothing for cards that were pending before); 0 with no active deck.
    static func watchedPendingCount(loaded: Bool, profile: GameProfile, decks: [Deck], sharing: [String: Bool],
                                    read: DeckRead?) -> Int? {
        guard loaded, showsDecks(profile) else { return nil }
        return !decks.contains(where: \.active) ? 0 : DeckPage.pendingCount(decks: decks, sharing: sharing, read: read)
    }
}
