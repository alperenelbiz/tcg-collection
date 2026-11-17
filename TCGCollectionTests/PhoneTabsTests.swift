import Testing
@testable import TCGCollection2

/// Phase 6A (A50): the iPhone's tabs and the model's screens.
struct PhoneTabsTests {
    /// For Sale is inside the Collection tab (A50).
    @Test func forSaleIsInTheCollectionTab() {
        #expect(PhoneTabs.tab(of: .forSale) == .collection)
        #expect(PhoneTabs.tab(of: .collection) == .collection)
        #expect(PhoneTabs.tab(of: .wanted) == .wanted)
        #expect(PhoneTabs.tab(of: .sets) == .sets)
        #expect(PhoneTabs.tab(of: .allCards) == .search)
    }

    /// Task 2 review m1: the selection never names a tab that this render's tab bar lacks; it names the Collection then.
    @Test func theSelectionIsAlwaysATabOfTheBar() {
        let noDecks = PhoneTabs.tabs(profile: GameProfile(followed: true, player: false, collector: true))
        #expect(PhoneTabs.selection(of: .deck("a"), tabs: noDecks) == .collection)
        #expect(PhoneTabs.selection(of: .decks, tabs: noDecks) == .collection)
        #expect(PhoneTabs.selection(of: .sets, tabs: noDecks) == .sets)
        let noSets = PhoneTabs.tabs(profile: GameProfile(followed: true, player: true, collector: false))
        #expect(PhoneTabs.selection(of: .sets, tabs: noSets) == .collection)
        #expect(PhoneTabs.selection(of: .forSale, tabs: noSets) == .collection)
        #expect(PhoneTabs.selection(of: .wanted, tabs: noSets) == .wanted)
        #expect(PhoneTabs.selection(of: .allCards, tabs: noSets) == .search)
    }

    /// The deck list and every deck are in the Decks tab.
    @Test func aDeckIsInTheDecksTab() {
        #expect(PhoneTabs.tab(of: .deck("a")) == .decks)
        #expect(PhoneTabs.tab(of: .decks) == .decks)
    }

    /// A tab opens on its last screen, else on its root.
    @Test func aTabReturnsToItsLastScreen() {
        #expect(PhoneTabs.screen(for: .decks, last: [.decks: .deck("a")]) == .deck("a"))
        #expect(PhoneTabs.screen(for: .collection, last: [.collection: .forSale]) == .forSale)
        #expect(PhoneTabs.screen(for: .collection, last: [:]) == .collection)
        #expect(PhoneTabs.screen(for: .wanted, last: [:]) == .wanted)
        #expect(PhoneTabs.screen(for: .decks, last: [:]) == .decks)
        #expect(PhoneTabs.screen(for: .sets, last: [:]) == .sets)
        #expect(PhoneTabs.screen(for: .search, last: [:]) == .allCards)
        // A last screen of another tab is not taken.
        #expect(PhoneTabs.screen(for: .wanted, last: [.wanted: .sets]) == .wanted)
    }

    /// Decks with the player role, Sets with the collector role (G7, G8); search always last.
    @Test func theTabsFollowTheRoles() {
        #expect(PhoneTabs.tabs(profile: .all) == [.collection, .wanted, .decks, .sets, .search])
        #expect(PhoneTabs.tabs(profile: GameProfile(player: false)) == [.collection, .wanted, .sets, .search])
        #expect(PhoneTabs.tabs(profile: GameProfile(collector: false)) == [.collection, .wanted, .decks, .search])
        #expect(PhoneTabs.tabs(profile: GameProfile(player: false, collector: false)) == [.collection, .wanted, .search])
    }

    /// The iPhone's deck list is stored as "decks".
    @Test func theDeckListIsStoredAsDecks() {
        #expect(Screen(storedValue: "decks") == .decks)
        #expect(Screen.decks.storedValue == "decks")
    }

    /// The Mac has no deck list: a stored "decks" opens the Collection there; the iPhone keeps it (with the player role).
    @Test func theDeckListIsOnlyOnTheIPhone() {
        #expect(Screen.checked(.decks, profile: .all, deckIDs: [], hasDeckList: false) == .collection)
        #expect(Screen.checked(.decks, profile: .all, deckIDs: [], hasDeckList: true) == .decks)
        #expect(Screen.checked(.decks, profile: GameProfile(player: false), deckIDs: [], hasDeckList: true) == .collection)
        #expect(Screen.checked(.wanted, profile: .all, deckIDs: [], hasDeckList: false) == .wanted)
    }

    /// The status line on the iPhone shows only while there is something to say.
    @Test func thePhoneStatusShowsOnlyWhileThereIsSomethingToSay() {
        #expect(!PhoneStatus.shows(status: .idle("Catalog up to date"), notice: nil))
        #expect(PhoneStatus.shows(status: .syncing("Riftbound: 1 / 3 sets"), notice: nil))
        #expect(PhoneStatus.shows(status: .failed("Catalog: 1 set failed"), notice: nil))
        #expect(PhoneStatus.shows(status: .idle("Catalog up to date"), notice: "Imported: 2 new"))
        #expect(PhoneStatus.shows(status: .idle("Catalog up to date"), notice: nil, downloading: true))
    }
}
