import Foundation
import Testing
@testable import TCGCollection2

/// A29, G3, G10: the rows of the games-and-roles view (the Settings pane, later the onboarding sheet).
struct GameProfilesViewTests {
    private let ids = ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"]
    private let allCan = ["magic-the-gathering": true, "yu-gi-oh": true, "riftbound": true, "cyberpunk": true]
    private let off = GameProfile(followed: false, player: true, collector: true)

    private func rows(_ profiles: [String: GameProfile], canChange: [String: Bool]? = nil,
                      problems: [String: String] = [:]) -> [ProfileRow] {
        ProfileRows.rows(games: Games.all, profiles: profiles, canChange: canChange ?? allCan, problems: problems)
    }

    /// One row per game, in the games' order, with its name and its profile (all on without an entry).
    @Test func fourRowsInTheGamesOrder() {
        let made = rows(["cyberpunk": GameProfile(followed: true, player: false, collector: true)])
        #expect(made.map(\.gameID) == ids)
        #expect(made.map(\.name) == ["Magic: The Gathering", "Yu-Gi-Oh!", "Riftbound", "Cyberpunk TCG"])
        #expect(made.map(\.profile) == [.all, .all, .all, GameProfile(followed: true, player: false, collector: true)])
        #expect(made.allSatisfy { $0.canFollow && $0.canChooseRoles && $0.problem == nil })
    }

    /// A game that is not followed: its roles are shown as they are, and their controls are off; its own checkbox is on.
    @Test func aGameNotFollowedHasItsRoleControlsOff() {
        let made = rows(["yu-gi-oh": GameProfile(followed: false, player: false, collector: true)])
        let ygo = made[1]
        #expect(ygo.profile == GameProfile(followed: false, player: false, collector: true))
        #expect(ygo.canFollow && !ygo.canChooseRoles)
        #expect(made[0].canChooseRoles && made[2].canChooseRoles && made[3].canChooseRoles)
    }

    /// G3: the only followed game's checkbox is off; its roles stay on. The games that are not followed can be turned on.
    @Test func theOnlyFollowedGameCannotBeTurnedOff() {
        let made = rows(["magic-the-gathering": off, "yu-gi-oh": off, "cyberpunk": off])
        #expect(made.map(\.canFollow) == [true, true, false, true])
        #expect(made[2].canChooseRoles)
        // Two followed games: both can be turned off.
        #expect(rows(["magic-the-gathering": off, "yu-gi-oh": off]).map(\.canFollow) == [true, true, true, true])
    }

    /// A game that cannot change (its file refused, not downloaded, no folder): every control off, and its sentence. The
    /// sentence of a game that can change is not shown.
    @Test func aGameThatCannotChangeHasEveryControlOffAndItsSentence() {
        var can = allCan
        can["riftbound"] = false
        let made = rows([:], canChange: can, problems: ["riftbound": "riftbound.json was written by a newer version of the app.",
                                                        "cyberpunk": "ignored"])
        #expect(!made[2].canFollow && !made[2].canChooseRoles)
        #expect(made[2].problem == "riftbound.json was written by a newer version of the app.")
        #expect(made[3].problem == nil && made[3].canFollow)
        // A game without an entry in `canChange` cannot change.
        #expect(!rows([:], canChange: [:]).contains { $0.canFollow || $0.canChooseRoles })
    }

    /// `toggled` flips one member of one game and nothing else.
    @Test func toggledFlipsOneMemberAndNothingElse() {
        let start: [String: GameProfile] = ["riftbound": GameProfile(followed: true, player: true, collector: false)]
        let player = ProfileRows.toggled(start, game: "riftbound", member: .player)
        #expect(player == ["riftbound": GameProfile(followed: true, player: false, collector: false)])
        let collector = ProfileRows.toggled(start, game: "riftbound", member: .collector)
        #expect(collector == ["riftbound": GameProfile(followed: true, player: true, collector: true)])
        let followed = ProfileRows.toggled(start, game: "riftbound", member: .followed)
        #expect(followed == ["riftbound": GameProfile(followed: false, player: true, collector: false)])
        // A game without an entry starts from all on; the other entries are kept as they are.
        let other = ProfileRows.toggled(start, game: "cyberpunk", member: .player)
        #expect(other == ["riftbound": start["riftbound"]!, "cyberpunk": GameProfile(followed: true, player: false, collector: true)])
    }

    /// Turning `followed` on keeps the roles the game had.
    @Test func turningFollowedOnKeepsTheRoles() {
        let start: [String: GameProfile] = ["yu-gi-oh": GameProfile(followed: false, player: false, collector: true)]
        #expect(ProfileRows.toggled(start, game: "yu-gi-oh", member: .followed)
                == ["yu-gi-oh": GameProfile(followed: true, player: false, collector: true)])
    }

    /// G3 at the Settings rows' level (final fix C): every game `followed: false` (every game then counts as followed):
    /// no game is the last followed one, every game's box can be ticked, and every role is off until its game is.
    @Test func noGameFollowedLeavesEveryRowOpen() {
        let none = Dictionary(uniqueKeysWithValues: ids.map { ($0, off) })
        let made = rows(none)
        #expect(made.allSatisfy { $0.canFollow && !$0.canChooseRoles && !$0.profile.followed })
    }
}

/// The Settings pane on a real library and model (final fix A4, B9, C).
#if os(macOS)
@MainActor
struct GamesSettingsPaneTests {
    private func model(_ root: URL) -> AppModel {
        AppModel(options: .init(arguments: ["app", "-store", root.path, "-offline", "YES"]), catalogClient: NoNetwork(),
                 archiveClient: NoNetwork(), fetcher: NoNetwork())
    }

    /// A4: two toggles on one binding made at one render (Player off, then Collector off, before a re-render): both are
    /// written; the second does not write the first one back.
    @Test func twoTogglesOnAStaleBindingBothCount() async throws {
        let model = model(tempRoot())
        await model.start()
        let rendered = GamesSettingsPane.profiles(model.library)
        let binding = GamesSettingsPane.binding(model: model, rendered: rendered)
        binding.wrappedValue = ProfileRows.toggled(rendered, game: "riftbound", member: .player)
        binding.wrappedValue = ProfileRows.toggled(rendered, game: "riftbound", member: .collector)
        #expect(model.library.profile(game: "riftbound") == GameProfile(followed: true, player: false, collector: false))
        await model.library.flush()
        let stored = try GameUserFile(data: Data(contentsOf: try #require(model.library.folder).appending(path: "riftbound.json")))
        #expect(stored.profile == GameProfile(followed: true, player: false, collector: false))
    }

    /// B9: a folder not read yet says the app's existing sentence.
    @Test func aFolderNotReadYetSaysReadingYourCollection() {
        let library = UserLibrary(folder: tempDir(), watcher: nil)
        #expect(GamesSettingsPane.problem(library, game: "riftbound") == "Reading your collection…")
        let none = UserLibrary(folder: nil, watcher: nil)
        #expect(GamesSettingsPane.problem(none, game: "riftbound") == ImportModel.noFolder)
    }

    /// C: the row of a game whose file is an iCloud placeholder (not downloaded): its sentence, every box off.
    @Test func aPlaceholdersRowSaysWhyAndIsOff() async throws {
        let root = tempRoot()
        let user = AppPaths.userTestRoot(root)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data().write(to: user.appending(path: ".cyberpunk.json.icloud"))
        let model = model(root)
        await model.start()
        let row = try #require(GamesSettingsPane.rows(model).first { $0.gameID == "cyberpunk" })
        #expect(!row.canFollow); #expect(!row.canChooseRoles)
        #expect(row.problem == "cyberpunk.json is not downloaded from iCloud yet.")
    }

    /// C: a profile changed by a reload (another device) while the pane shows: its rows follow.
    @Test func theRowsFollowAReload() async throws {
        let root = tempRoot()
        let model = model(root)
        await model.start()
        #expect(GamesSettingsPane.rows(model).first { $0.gameID == "riftbound" }?.profile == .all)
        let file = try #require(model.library.folder).appending(path: "riftbound.json")
        try Data(#"{"version":1,"collection":[],"profile":{"collector":false}}"#.utf8).write(to: file)
        await model.library.fileChanged(file)?.value
        #expect(GamesSettingsPane.rows(model).first { $0.gameID == "riftbound" }?.profile == GameProfile(collector: false))
    }
}
#endif
