import Foundation
import Testing
@testable import TCGCollection2

@MainActor
struct WantedViewTests {
    /// Wanted lists nothing before a join of the game has ended, then lays the live list on the last join: a count or a
    /// pin changed since shows at once, a card added since is pending. The catalog counts as settled as it was for that
    /// join (as the Collection's `theListUsesTheSettledStateOfItsOwnJoin`).
    @Test func wantedLaysTheLiveListOnItsLastJoin() throws {
        let twin = [product(id: 1, groupID: 10, name: "Twin"), product(id: 2, groupID: 11, name: "Twin (Showcase)")]
        let state = WantedScreenState(gameID: "riftbound")
        #expect(state.sort == .name)
        let none: (WantedEntry, [ProductRecord]) -> ShownPrice? = { _, _ in nil }
        let wanted = [WantedEntry(cardKey: "twin", name: "Twin", count: 1, pinProductID: nil, pinFinish: nil)]
        #expect(state.join.content(wanted: wanted, decks: [], sharing: [:], price: none) == nil)          // no join has ended yet

        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 1, priceDay: nil, catalogSettled: false)
        state.join.catalogHasProducts = true
        state.join.read = WantedRead(printings: ["twin": twin], keys: ["twin"], setNames: [10: "Set A", 11: "Set B"])
        // Since the join: Twin pinned to its second printing at 3, and Gone Card added.
        let live = [WantedEntry(cardKey: "twin", name: "Twin", count: 3, pinProductID: 2, pinFinish: "Normal"),
                    WantedEntry(cardKey: "gone card", name: "Gone Card", count: 1, pinProductID: nil, pinFinish: nil)]
        let during = try #require(state.join.content(wanted: live, decks: [], sharing: [:], price: none))
        #expect(during.cards.map(\.shown?.productID) == [2, nil] && during.cards.map(\.entry.count) == [3, 1])
        #expect(during.countText(for: during.cards[0]) == "×3 · Set B")
        #expect(!during.settled && during.note == CollectionList.catalogDownloading)
        #expect(during.cards.map { during.link(for: $0) } == [.card, .none])

        // The same read, made on a settled catalog: Gone Card was not looked up, so it is still pending.
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 2, priceDay: nil, catalogSettled: true)
        let settled = try #require(state.join.content(wanted: live, decks: [], sharing: [:], price: none))
        #expect(settled.settled && settled.note == nil)
        #expect(settled.cards.map { settled.link(for: $0) } == [.card, .none])
    }

    /// Fix rounds 1 and 2: a pin on another printing or finish than the one shown is named on the card page: the pinned
    /// printing's set, number and rarity (a part the product lacks is left out), and its finish when that is not the
    /// printing's first finish line; the shown product with another finish; a printing that left the catalog.
    @Test func aPinOnAnotherPrintingIsNamed() {
        let printings = [
            719834: PinPrinting(set: "Beyond the Brave", number: "BETB-EN001", rarity: "Super Rare", firstFinish: "1st Edition"),
            719835: PinPrinting(set: "Beyond the Brave", number: "BETB-EN001", rarity: "Starlight Rare", firstFinish: "1st Edition"),
            7: PinPrinting(set: "Origins", number: "", rarity: "Rare", firstFinish: "Normal"),
            9: PinPrinting(set: "", number: "", rarity: "", firstFinish: "Normal"),
        ]
        let shown = PrintingKey(productID: 719835, finish: "1st Edition")
        func text(_ id: Int, _ finish: String, shown: PrintingKey? = shown) -> String {
            WantedLine.pinnedText(PrintingKey(productID: id, finish: finish), shown: shown, printings: printings)
        }
        // Another printing of the same set: its number and rarity tell it apart.
        #expect(text(719834, "1st Edition") == "Pinned to Beyond the Brave · BETB-EN001 · Super Rare")
        #expect(text(719834, "Unlimited") == "Pinned to Beyond the Brave · BETB-EN001 · Super Rare · Unlimited")
        // The product shown, another finish.
        #expect(text(719835, "Unlimited") == "Pinned to Unlimited of this printing")
        // A part the product lacks is left out; a product with none of them.
        #expect(text(7, "Normal") == "Pinned to Origins · Rare")
        #expect(text(9, "Normal") == "Pinned to another printing")
        // A printing that left the catalog, also on the page of a card that left it (nothing shown).
        #expect(text(1, "Normal") == "Pinned to a printing that left the catalog")
        #expect(text(719834, "1st Edition", shown: nil) == "Pinned to Beyond the Brave · BETB-EN001 · Super Rare")
    }

    /// Phase 4B (G7): without the player role Wanted is the hand-added list. Two active decks miss Dockside Lock-Up (2
    /// each, none owned: one card pending) and Twin is wanted once by hand. With the role off (the file's profile) the list
    /// is Twin alone at `×1`: no decks' part, nothing pending, and the join reads no deck card. The role turned on brings
    /// the decks' part back from the file.
    @Test func withoutThePlayerRoleWantedIsTheHandAddedList() async throws {
        let root = tempRoot()
        let user = AppPaths.userTestRoot(root)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("""
        {"version": 1, "collection": [],
         "wanted": [{"cardKey": "twin", "name": "Twin", "count": 1}],
         "decks": [{"id": "a", "name": "Wind", "format": "standard", "active": true,
                    "cards": [{"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 2}]},
                   {"id": "b", "name": "Cheap", "format": "standard", "active": true,
                    "cards": [{"cardKey": "dockside lock up", "name": "Dockside Lock-Up", "section": "main", "count": 2}]}],
         "profile": {"player": false}}
        """.utf8).write(to: user.appending(path: "riftbound.json"))
        let model = AppModel(options: LaunchOptions(arguments: ["app", "-store", root.path, "-offline", "YES", "-game", "riftbound"]),
                             catalogClient: FakeCatalog(groups: Data(), products: Data()), archiveClient: FakeArchive(),
                             fetcher: FakeFetcher())
        await model.start()
        #expect(model.library.decks(game: "riftbound").count == 2)                    // the file keeps them
        #expect(model.decksInPlay(game: "riftbound").isEmpty)

        let wanted = model.library.wanted(game: "riftbound")
        let printings = ["twin": [product(id: 1, name: "Twin")], "dockside lock up": [product(id: 2, name: "Dockside Lock-Up")]]
        var read = WantedRead(printings: printings, keys: ["twin", "dockside lock up"], setNames: [:])
        read.ownedByCard = [:]
        let none: (WantedEntry, [ProductRecord]) -> ShownPrice? = { _, _ in nil }
        func listed() -> WantedContent {
            let decks = model.decksInPlay(game: "riftbound")
            return WantedList.content(wanted, decks: decks, sharing: model.library.sharing(game: "riftbound"), read: read,
                                      joinFailed: false, catalogHasProducts: true, catalogSettled: true, price: none)
        }
        #expect(WantedList.joinKeys(wanted: wanted, decks: model.decksInPlay(game: "riftbound")) == ["twin"])
        let off = listed()
        #expect(off.cards.map(\.id) == ["twin"])
        #expect(off.cards.map { off.countText(for: $0) } == ["×1"])
        #expect(off.cards.filter(\.pending).isEmpty)

        model.library.setProfile(.all, game: "riftbound")
        #expect(WantedList.joinKeys(wanted: wanted, decks: model.decksInPlay(game: "riftbound")) == ["twin", "dockside lock up"])
        let on = listed()
        #expect(on.cards.map(\.id).sorted() == ["dockside lock up", "twin"])
        #expect(on.cards.first { $0.id == "dockside lock up" }?.pending == true)
    }
}
