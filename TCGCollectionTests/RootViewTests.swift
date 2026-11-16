import Foundation
import SwiftUI
import Testing
@testable import TCGCollection2

/// The path of a screen's stack as the window keeps it (`Binding.kept(on:in:)`), and the switches made by code
/// (`AppModel.showRoot(of:)`).
@MainActor
struct RootViewTests {
    private final class Stored {
        var path = NavigationPath()
    }

    private func model(_ arguments: [String]) -> AppModel {
        AppModel(options: LaunchOptions(arguments: arguments), catalogClient: FakeCatalog(groups: Data(), products: Data()),
                 archiveClient: FakeArchive(), fetcher: FakeFetcher())
    }

    private func page(_ key: String) -> CardTarget {
        CardTarget(gameID: "riftbound", cardKey: key, startProductID: nil)
    }

    /// Fix round 1: the pages of a screen survive a visit to another one, because the write of a stack that leaves the
    /// window is not taken. Fix round 2: a switch made by code shows the screen's root; the next page opened there
    /// replaces the old pages; a later sidebar return shows what was last on show there.
    @Test func aSwitchByCodeShowsTheRoot() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-screen", "all-cards"])
        let stored = Stored()
        let path = Binding(get: { stored.path }, set: { stored.path = $0 }).kept(on: .allCards, in: model)
        path.wrappedValue.append(page("dockside lock up"))       // a page opened on All cards
        #expect(stored.path.count == 1 && path.wrappedValue.count == 1)

        model.screen = .wanted                                   // the sidebar
        path.wrappedValue = NavigationPath()                     // the stack leaving: not taken
        #expect(stored.path.count == 1)
        model.screen = .allCards                                 // the sidebar back: the kept page
        #expect(path.wrappedValue.count == 1 && !model.showsRoot(.allCards))

        model.screen = .wanted
        model.showRoot(of: .allCards)                            // "Search a card"
        #expect(model.screen == .allCards && model.showsRoot(.allCards))
        #expect(path.wrappedValue.isEmpty)                       // the root, whatever was kept
        path.wrappedValue.append(page("calm rune"))              // a page opened there replaces the old ones
        #expect(!model.showsRoot(.allCards) && stored.path.count == 1 && path.wrappedValue.count == 1)

        model.showRoot(of: .wanted)
        model.screen = .allCards                                 // a sidebar return, no page changed meanwhile
        #expect(path.wrappedValue.count == 1)
    }

    /// Phase 4A task 3: the Sets list keeps its pages (a set's page) across a sidebar switch, as the other lists do, and a
    /// switch made by code shows its root.
    @Test func theSetsListKeepsItsPages() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-screen", "sets"])
        #expect(model.screen == .sets)
        let stored = Stored()
        let path = Binding(get: { stored.path }, set: { stored.path = $0 }).kept(on: .sets, in: model)
        path.wrappedValue.append(SetPageTarget(groupID: 24819))  // a set opened on the list
        model.screen = .collection                               // the sidebar
        path.wrappedValue = NavigationPath()                     // the stack leaving: not taken
        #expect(stored.path.count == 1)
        model.screen = .sets                                     // the sidebar back: the kept page
        #expect(path.wrappedValue.count == 1)
        model.screen = .collection
        model.showRoot(of: .sets)                                // a switch made by code
        #expect(path.wrappedValue.isEmpty)
    }

    /// Phase 4B (G7, G8): a stored or launched screen through the game's profile: a deck without the player role and Sets
    /// without the collector role open the Collection; with the role, as before (a deck the file lacks opens the
    /// Collection too).
    @Test func aCheckedScreenFollowsTheRoles() {
        let playerOff = GameProfile(player: false), collectorOff = GameProfile(collector: false)
        #expect(Screen.checked(.deck("a"), profile: .all, deckIDs: ["a"]) == .deck("a"))
        #expect(Screen.checked(.deck("a"), profile: playerOff, deckIDs: ["a"]) == .collection)
        #expect(Screen.checked(.deck("c"), profile: .all, deckIDs: ["a"]) == .collection)
        #expect(Screen.checked(.sets, profile: .all, deckIDs: []) == .sets)
        #expect(Screen.checked(.sets, profile: collectorOff, deckIDs: []) == .collection)
        #expect(Screen.checked(.sets, profile: playerOff, deckIDs: []) == .sets)
        #expect(Screen.checked(.deck("a"), profile: collectorOff, deckIDs: ["a"]) == .deck("a"))
        #expect(Screen.checked(.wanted, profile: GameProfile(player: false, collector: false), deckIDs: []) == .wanted)
    }

    /// The import shows the imported game's Collection at its root (fix round 2), not a page kept on it: a page opened on
    /// the Collection and kept across a sidebar switch is not what the import shows.
    @Test func anImportShowsTheCollectionsRoot() async {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-screen", "collection"])
        let stored = Stored()
        let path = Binding(get: { stored.path }, set: { stored.path = $0 }).kept(on: .collection, in: model)
        path.wrappedValue.append(page("dockside lock up"))       // a page opened on the Collection
        model.screen = .allCards                                 // the sidebar: the page is kept
        path.wrappedValue = NavigationPath()                     // the stack leaving: not taken
        #expect(stored.path.count == 1)
        model.importing = ImportModel(unreadable: "x", fileName: "x.csv", library: model.library, reader: model.reader)
        await model.importApplied(.init(gameID: model.gameID, games: [model.gameID], summary: "2 new"))
        #expect(model.screen == .collection && model.showsRoot(.collection))
        #expect(path.wrappedValue.isEmpty)                       // the root: the kept page is dropped
    }
}
