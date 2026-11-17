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

    /// The members of `new` that differ from `old` (the profile a view rendered), set onto `current` (the profile of this
    /// moment); every other member of `current` is kept (final fix A4).
    static func applying(_ new: GameProfile, over old: GameProfile, onto current: GameProfile) -> GameProfile {
        var result = current
        if new.followed != old.followed { result.followed = new.followed }
        if new.player != old.player { result.player = new.player }
        if new.collector != old.collector { result.collector = new.collector }
        return result
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

/// The Settings window's one pane "Games" (G10): `GameProfilesView` on the library's profiles. Every toggle writes that
/// game's profile at once (`setProfile`; no Save button), then tells the model (`profilesChanged`, which also runs by
/// itself on the library's change).
struct GamesSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let profiles = Self.profiles(model.library)
        // Task 5: while the first-run question is due or open, nothing here can change (it would write before "Continue").
        let onboarding = model.onboardingDue
        VStack(alignment: .leading, spacing: Theme.ruleSpacing) {
            GameProfilesView(profiles: Self.binding(model: model, rendered: profiles), rows: Self.rows(model))
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

    /// Every game's profile as the library holds it.
    static func profiles(_ library: UserLibrary) -> [String: GameProfile] {
        Dictionary(uniqueKeysWithValues: Games.all.map { ($0.id, library.profile(game: $0.id)) })
    }

    /// The pane's rows from the library and the model (the Settings lock while the first-run question is due).
    static func rows(_ model: AppModel) -> [ProfileRow] {
        let library = model.library
        let ids = Games.all.map(\.id)
        let canChange = Dictionary(uniqueKeysWithValues: ids.map { ($0, library.canSetProfile(game: $0)) })
        let problems = Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.problem(library, game: $0)) })
        return ProfileRows.settingsRows(games: Games.all, profiles: profiles(library), canChange: canChange,
                                        problems: problems, onboarding: model.onboardingDue)
    }

    /// The pane's binding over the profiles `rendered` with the view. A toggle (`toggled` flips one member of one game)
    /// writes only that game, and only the member that differs from the rendered value, onto the library's profile of
    /// that moment (final fix A4): a second toggle before a re-render does not write the first one back.
    static func binding(model: AppModel, rendered: [String: GameProfile]) -> Binding<[String: GameProfile]> {
        let library = model.library
        return Binding(
            get: { rendered },
            set: { changed in
                for id in Games.all.map(\.id) where changed[id] != rendered[id] {
                    let current = library.profile(game: id)
                    library.setProfile(ProfileRows.applying(changed[id] ?? .all, over: rendered[id] ?? .all, onto: current),
                                       game: id)
                }
                model.profilesChanged()
            })
    }

    /// Why the game's profile cannot change: its problem (`problem(game:)`), else no folder (the import sheet's
    /// sentence), else the folder not read yet ("Reading your collection…", the card page's sentence).
    static func problem(_ library: UserLibrary, game: String) -> String {
        // B9: a folder not read yet says the app's existing sentence.
        library.problem(game: game) ?? (library.folder == nil ? ImportModel.noFolder : "Reading your collection…")
    }
}
