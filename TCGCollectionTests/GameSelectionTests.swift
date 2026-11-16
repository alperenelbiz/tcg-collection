import Foundation
import Testing
@testable import TCGCollection2

/// G3, G4: which games the app shows, and which one is on screen.
struct GameSelectionTests {
    private let games = ["magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"]

    private func off(_ ids: String...) -> [String: GameProfile] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, GameProfile(followed: false, player: true, collector: true)) })
    }

    @Test func theFollowedGamesAreInTheGamesOrder() {
        #expect(GameSelection.followed(off("yu-gi-oh"), games: games) == ["magic-the-gathering", "riftbound", "cyberpunk"])
        // A profile listed in another order does not change the order.
        var profiles = off("magic-the-gathering")
        profiles["cyberpunk"] = .all
        profiles["riftbound"] = .all
        #expect(GameSelection.followed(profiles, games: games) == ["yu-gi-oh", "riftbound", "cyberpunk"])
        // A game without a profile entry is followed.
        #expect(GameSelection.followed([:], games: games) == games)
    }

    /// G3: when the files say no game is followed, every game counts as followed.
    @Test func noGameFollowedMeansEveryGame() {
        #expect(GameSelection.followed(off("magic-the-gathering", "yu-gi-oh", "riftbound", "cyberpunk"), games: games) == games)
    }

    /// G4: a followed game stays on screen; one that is not shows the first followed game.
    @Test func theGameShownIsFollowed() {
        #expect(GameSelection.shown(asked: "riftbound", followed: ["yu-gi-oh", "riftbound"]) == "riftbound")
        #expect(GameSelection.shown(asked: "magic-the-gathering", followed: ["yu-gi-oh", "riftbound"]) == "yu-gi-oh")
        #expect(GameSelection.shown(asked: "unknown", followed: ["cyberpunk"]) == "cyberpunk")
    }

    /// G3: the last followed game cannot be turned off.
    @Test func theOnlyFollowedGameCannotBeTurnedOff() {
        #expect(!GameSelection.canTurnOff(game: "riftbound", followed: ["riftbound"]))
        #expect(GameSelection.canTurnOff(game: "riftbound", followed: ["riftbound", "cyberpunk"]))
        #expect(GameSelection.canTurnOff(game: "cyberpunk", followed: ["riftbound", "cyberpunk"]))
    }
}
