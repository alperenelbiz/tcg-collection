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
}
