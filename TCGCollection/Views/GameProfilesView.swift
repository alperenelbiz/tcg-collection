import SwiftUI

/// One game's row of `GameProfilesView`: its profile, which controls are on, and why they are off.
nonisolated struct ProfileRow: Equatable, Sendable, Identifiable {
    let gameID: String
    let name: String
    let profile: GameProfile
    /// The "followed" checkbox is on: the game can change, and it is not the last followed game (G3).
    let canFollow: Bool
    /// "Player" and "Collector" are on: the game can change and is followed.
    let canChooseRoles: Bool
    /// Only for a game that cannot change: why (shown under the row).
    let problem: String?
    var id: String { gameID }
}

/// The rows of the games-and-roles view (A29, G3), pure: the Settings pane and the onboarding sheet make them from their
/// own profiles (the library's, a draft).
nonisolated enum ProfileRows {
    enum Member: Sendable { case followed, player, collector }

    /// One row per game of `games`, in their order. A game without an entry in `profiles` is all on; one without an entry
    /// in `canChange` cannot change. `problems` is read only for a game that cannot change.
    static func rows(games: [GameDefinition], profiles: [String: GameProfile], canChange: [String: Bool],
                     problems: [String: String]) -> [ProfileRow] {
        let followed = GameSelection.followed(profiles, games: games.map(\.id))
        return games.map { game in
            let profile = profiles[game.id] ?? .all
            let can = canChange[game.id] ?? false
            // G3: only a followed game can be the last one (`canTurnOff` is true for a game that is not followed).
            let isLast = profile.followed && !GameSelection.canTurnOff(game: game.id, followed: followed)
            return ProfileRow(gameID: game.id, name: game.name, profile: profile, canFollow: can && !isLast,
                              canChooseRoles: can && profile.followed, problem: can ? nil : problems[game.id])
        }
    }

    /// The onboarding draft's rows (G11): every game can be ticked and unticked (no "last followed" rule: "Continue" is
    /// off until one is ticked), the roles only of a ticked game, no problem line (nothing is written before "Continue").
    static func draftRows(games: [GameDefinition], profiles: [String: GameProfile]) -> [ProfileRow] {
        games.map { game in
            let profile = profiles[game.id] ?? .all
            return ProfileRow(gameID: game.id, name: game.name, profile: profile, canFollow: true,
                              canChooseRoles: profile.followed, problem: nil)
        }
    }

    /// The Settings pane's rows: `rows`, except while onboarding is due or open (`onboarding`): then every control is off
    /// and no problem line shows, so no toggle writes a game file before "Continue" (which would then overwrite it).
    static func settingsRows(games: [GameDefinition], profiles: [String: GameProfile], canChange: [String: Bool],
                             problems: [String: String], onboarding: Bool) -> [ProfileRow] {
        guard onboarding else { return rows(games: games, profiles: profiles, canChange: canChange, problems: problems) }
        return games.map { game in
            ProfileRow(gameID: game.id, name: game.name, profile: profiles[game.id] ?? .all, canFollow: false,
                       canChooseRoles: false, problem: nil)
        }
    }

    /// The one line under the Settings pane's table: the note, or while onboarding is due or open, where to go first.
    static func settingsNote(onboarding: Bool) -> String {
        onboarding ? "Finish the first-run question in the main window first."
            : "A game or a role you turn off is hidden. Its cards, lists and decks stay in your folder."
    }

    /// `profiles` with one member of one game flipped (a game without an entry starts from all on). Every other member
    /// and game is kept: turning `followed` on keeps the roles the game had.
    static func toggled(_ profiles: [String: GameProfile], game: String, member: Member) -> [String: GameProfile] {
        var profile = profiles[game] ?? .all
        switch member {
        case .followed: profile.followed.toggle()
        case .player: profile.player.toggle()
        case .collector: profile.collector.toggle()
        }
        var result = profiles
        result[game] = profile
        return result
    }
}

/// The games and roles (A29, "The look of the new parts"): a table without boxes, one row per game. A checkbox with the
/// game's name ("I follow this game"); right of it, in a fixed column each, "Player" and "Collector" (off while the game
/// is not followed). Under a row that cannot change, its problem sentence. It only shows and edits `profiles`: the
/// Settings pane binds it to the library, the onboarding sheet to a draft.
struct GameProfilesView: View {
    @Binding var profiles: [String: GameProfile]
    let rows: [ProfileRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.tableRowSpacing) {
            ForEach(rows) { row($0) }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ row: ProfileRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.lineGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.columnGap) {
                checkbox(row.name, isOn: row.profile.followed, enabled: row.canFollow, member: .followed, game: row.gameID)
                    .frame(maxWidth: .infinity, alignment: .leading)
                checkbox("Player", isOn: row.profile.player, enabled: row.canChooseRoles, member: .player, game: row.gameID)
                    .frame(width: Theme.profileRoleWidth, alignment: .leading)
                checkbox("Collector", isOn: row.profile.collector, enabled: row.canChooseRoles, member: .collector,
                         game: row.gameID)
                    .frame(width: Theme.profileRoleWidth, alignment: .leading)
            }
            if let problem = row.problem {
                Text(problem)
                    .font(Theme.lineFont)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile-problem-\(row.gameID)")
            }
        }
    }

    private func checkbox(_ title: String, isOn: Bool, enabled: Bool, member: ProfileRows.Member,
                          game: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { value in
                guard value != isOn else { return }
                profiles = ProfileRows.toggled(profiles, game: game, member: member)
            }))
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            // Not the accent (the sidebar row and the default button only): as the import sheet's "Remove".
            .tint(Theme.raised)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .disabled(!enabled)
            .accessibilityIdentifier("profile-\(Self.identifier(member))-\(game)")
    }

    private static func identifier(_ member: ProfileRows.Member) -> String {
        switch member {
        case .followed: "followed"
        case .player: "player"
        case .collector: "collector"
        }
    }
}

#if os(macOS)
/// The Settings window's one pane "Games" (G10): `GameProfilesView` on the library's profiles. Every toggle writes that
/// game's profile at once (`setProfile`; no Save button), then tells the model (`profilesChanged`, which also runs by
/// itself on the library's change).
struct GamesSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let ids = Games.all.map(\.id)
        let profiles = Dictionary(uniqueKeysWithValues: ids.map { ($0, library.profile(game: $0)) })
        let canChange = Dictionary(uniqueKeysWithValues: ids.map { ($0, library.canSetProfile(game: $0)) })
        let problems = Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.problem(library, game: $0)) })
        // Task 5: while the first-run question is due or open, nothing here can change (it would write before "Continue").
        let onboarding = model.onboardingDue
        VStack(alignment: .leading, spacing: Theme.ruleSpacing) {
            GameProfilesView(
                profiles: Binding(
                    get: { profiles },
                    set: { changed in
                        // `toggled` changes one game: only that game's profile is written.
                        for id in ids where changed[id] != profiles[id] {
                            library.setProfile(changed[id] ?? .all, game: id)
                        }
                        model.profilesChanged()
                    }),
                rows: ProfileRows.settingsRows(games: Games.all, profiles: profiles, canChange: canChange,
                                               problems: problems, onboarding: onboarding))
            Text(ProfileRows.settingsNote(onboarding: onboarding))
                .font(Theme.lineFont)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-note")
        }
        .padding(Theme.sheetPadding)
        .frame(width: Theme.settingsWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-games")
    }

    /// Why the game's profile cannot change: its problem (`problem(game:)`), else no folder, else the folder not read yet
    /// (the import sheet's sentences).
    private static func problem(_ library: UserLibrary, game: String) -> String {
        library.problem(game: game) ?? (library.folder == nil ? ImportModel.noFolder : "Your collection is not read yet.")
    }
}
#endif
