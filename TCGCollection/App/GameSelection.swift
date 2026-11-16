import Foundation

/// Which games the app shows and updates (G3, G4), from the games' profiles. Pure.
nonisolated enum GameSelection {
    /// The followed games, in the order of `games` (the games' fixed order). A game without an entry in `profiles` is
    /// followed. G3: when no game is followed (a hand edit, two devices), every game counts as followed.
    static func followed(_ profiles: [String: GameProfile], games: [String]) -> [String] {
        let followed = games.filter { profiles[$0]?.followed ?? true }
        return followed.isEmpty ? games : followed
    }

    /// G4: the game to show when `asked` is wanted (stored, launched, or on screen): itself when it is followed, else the
    /// first followed game.
    static func shown(asked: String, followed: [String]) -> String {
        followed.contains(asked) ? asked : followed.first ?? asked
    }

    /// G3: false when turning `game` off would leave no followed game (it is the only one). True for any other game, also
    /// one that is not followed (there is nothing to turn off).
    static func canTurnOff(game: String, followed: [String]) -> Bool {
        followed != [game]
    }
}
