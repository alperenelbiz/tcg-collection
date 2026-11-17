import Foundation

/// Phase 6A (A50): the iPhone's tabs. For Sale is inside the Collection tab; the Decks tab holds the deck list and every
/// deck; the search tab is All cards.
nonisolated enum PhoneTab: Hashable, Sendable {
    case collection, wanted, decks, sets, search
}

/// The map between the model's screens (`Screen`) and the iPhone's tabs. Pure.
nonisolated enum PhoneTabs {
    /// The tab a screen belongs to.
    static func tab(of screen: Screen) -> PhoneTab {
        switch screen {
        case .collection, .forSale: .collection
        case .wanted: .wanted
        case .deck, .decks: .decks
        case .sets: .sets
        case .allCards: .search
        }
    }

    /// The tab bar's selection for `screen` among the tabs of this render (`tabs(profile:)`): the screen's tab, or the
    /// Collection while that tab is gone (a role turned off by a reload removes the tab before the screen moves).
    static func selection(of screen: Screen, tabs: [PhoneTab]) -> PhoneTab {
        let own = tab(of: screen)
        return tabs.contains(own) ? own : .collection
    }

    /// The screen a tap on `tab` shows: the tab's last screen (`last[tab]`, when it belongs to the tab), else its root.
    static func screen(for tab: PhoneTab, last: [PhoneTab: Screen]) -> Screen {
        if let screen = last[tab], self.tab(of: screen) == tab { return screen }
        return root(of: tab)
    }

    /// `last` without a deck the game no longer has (final fix wave item 3): a deck deleted elsewhere is not the Decks
    /// tab's last screen, so a tap on Decks shows the deck list.
    static func keeping(_ last: [PhoneTab: Screen], deckIDs: Set<String>) -> [PhoneTab: Screen] {
        last.filter { _, screen in
            if case .deck(let id) = screen { return deckIDs.contains(id) }
            return true
        }
    }

    /// The screen a tab opens on first.
    static func root(of tab: PhoneTab) -> Screen {
        switch tab {
        case .collection: .collection
        case .wanted: .wanted
        case .decks: .decks
        case .sets: .sets
        case .search: .allCards
        }
    }

    /// The tabs of a game, in order: Decks with the player role (G7), Sets with the collector role (G8), search last.
    static func tabs(profile: GameProfile) -> [PhoneTab] {
        var tabs: [PhoneTab] = [.collection, .wanted]
        if GameSections.showsDecks(profile) { tabs.append(.decks) }
        if GameSections.showsSets(profile) { tabs.append(.sets) }
        tabs.append(.search)
        return tabs
    }
}

/// The iPhone's status line above the tab bar: shown only while there is something to say. Pure.
nonisolated enum PhoneStatus {
    /// True while a sync runs, after a failure, while a notice is on (`AppModel.statusNotice`), or while the 90-day
    /// download runs (`downloading`: `AppModel.backfillProgress` is set). An idle status alone ("Catalog up to date") is
    /// said in Settings only.
    static func shows(status: Status, notice: String?, downloading: Bool = false) -> Bool {
        if notice != nil || downloading { return true }
        switch status {
        case .idle: return false
        case .syncing, .failed: return true
        }
    }
}
