import Foundation

/// A game's profile (G1), kept as `profile` in the game's file: whether the user follows the game, and his roles in it.
/// Every member is `true` unless the file says otherwise (A30: a file without the key is all on).
nonisolated struct GameProfile: Sendable, Equatable {
    var followed = true
    var player = true
    var collector = true

    /// Every member on: a game without a file, a file without `profile`, a refused file.
    static let all = GameProfile()

    /// The members this build owns in the file's `profile` object; any other key there is kept.
    static let storedKeys: Set<String> = ["followed", "player", "collector"]
}
