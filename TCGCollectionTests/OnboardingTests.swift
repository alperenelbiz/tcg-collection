import Foundation
import Testing
@testable import TCGCollection2

/// G11, A29, A30: when the first-run question is asked, its draft, and the rows it shows.
struct OnboardingTests {
    private let off = GameProfile(followed: false, player: true, collector: true)

    /// A Release build asks on a new folder only once that folder is read (`loaded`: read and not missing); a folder with
    /// a game file (A30: the owner's) is never asked.
    @Test func aReleaseBuildAsksOnALoadedNewFolder() {
        #expect(Onboarding.isDue(loaded: true, hasGameFile: false, isDebugBuild: false, hasStore: false, asked: false))
        #expect(!Onboarding.isDue(loaded: true, hasGameFile: true, isDebugBuild: false, hasStore: false, asked: false))
        #expect(!Onboarding.isDue(loaded: false, hasGameFile: false, isDebugBuild: false, hasStore: false, asked: false))
        #expect(!Onboarding.isDue(loaded: false, hasGameFile: true, isDebugBuild: false, hasStore: false, asked: false))
    }

    /// A Debug build asks only with `-store` and `-onboarding YES` (fails closed): the UI tests' fresh roots do not all open
    /// it, and a Debug build without `-store` never does.
    @Test func aDebugBuildAsksOnlyWithAStoreAndTheFlag() {
        #expect(!Onboarding.isDue(loaded: true, hasGameFile: false, isDebugBuild: true, hasStore: true, asked: false))
        #expect(Onboarding.isDue(loaded: true, hasGameFile: false, isDebugBuild: true, hasStore: true, asked: true))
        #expect(!Onboarding.isDue(loaded: true, hasGameFile: true, isDebugBuild: true, hasStore: true, asked: true))
        #expect(!Onboarding.isDue(loaded: true, hasGameFile: false, isDebugBuild: true, hasStore: false, asked: true))
        #expect(!Onboarding.isDue(loaded: true, hasGameFile: false, isDebugBuild: true, hasStore: false, asked: false))
        #expect(!Onboarding.isDue(loaded: false, hasGameFile: false, isDebugBuild: true, hasStore: true, asked: true))
    }

    /// The draft: every game not followed, both roles on (a ticked game starts with both roles).
    @Test func theDraftHasNoGameTicked() {
        let draft = Onboarding.draft(games: Games.all)
        #expect(draft == Dictionary(uniqueKeysWithValues: Games.all.map { ($0.id, off) }))
        #expect(!Onboarding.canContinue(draft))
        let ticked = ProfileRows.toggled(draft, game: "riftbound", member: .followed)
        #expect(ticked["riftbound"] == .all)
        #expect(Onboarding.canContinue(ticked))
        #expect(!Onboarding.canContinue([:]))
    }

    /// What "Continue" writes per game: a followed game as chosen; a game not ticked is not followed, both roles on (the
    /// roles chosen on a game unticked again are not kept); a game missing from the draft is not followed.
    @Test func whatContinueWritesPerGame() {
        let player = GameProfile(followed: true, player: false, collector: true)
        #expect(Onboarding.written(player) == player)
        #expect(Onboarding.written(.all) == .all)
        #expect(Onboarding.written(GameProfile(followed: false, player: false, collector: false)) == off)
        #expect(Onboarding.written(nil) == off)
    }

    /// The draft's rows: every game can be ticked and unticked (no "last followed" rule: "Continue" is off until one is
    /// ticked); the roles only of a ticked game; no problem line.
    @Test func theDraftsRowsLetEveryGameBeTicked() {
        let draft = Onboarding.draft(games: Games.all)
        let rows = ProfileRows.draftRows(games: Games.all, profiles: draft)
        #expect(rows.map(\.gameID) == Games.all.map(\.id))
        #expect(rows.allSatisfy { $0.canFollow && !$0.canChooseRoles && $0.problem == nil })
        let one = ProfileRows.toggled(draft, game: "yu-gi-oh", member: .followed)
        let ticked = ProfileRows.draftRows(games: Games.all, profiles: one)
        #expect(ticked.map(\.canFollow) == [true, true, true, true])          // the only ticked game can be unticked
        #expect(ticked.map(\.canChooseRoles) == [false, true, false, false])
        #expect(ticked[1].profile == .all)
    }

    /// While onboarding is due or open, the Settings pane shows its rows with every control off, no problem line, and one
    /// sentence in place of its note: its toggles would write game files before "Continue".
    @Test func settingsIsLockedWhileOnboardingIsDue() {
        let ids = Games.all.map(\.id)
        let profiles = Dictionary(uniqueKeysWithValues: ids.map { ($0, GameProfile.all) })
        let can = Dictionary(uniqueKeysWithValues: ids.map { ($0, true) })
        let problems = Dictionary(uniqueKeysWithValues: ids.map { ($0, "x") })
        let locked = ProfileRows.settingsRows(games: Games.all, profiles: profiles, canChange: can, problems: problems,
                                              onboarding: true)
        #expect(locked.count == 4)
        #expect(locked.allSatisfy { !$0.canFollow && !$0.canChooseRoles && $0.problem == nil })
        #expect(locked.map(\.profile) == [.all, .all, .all, .all])
        let open = ProfileRows.settingsRows(games: Games.all, profiles: profiles, canChange: can, problems: problems,
                                            onboarding: false)
        #expect(open == ProfileRows.rows(games: Games.all, profiles: profiles, canChange: can, problems: problems))
        #expect(ProfileRows.settingsNote(onboarding: true) == "Finish the first-run question in the main window first.")
        #expect(ProfileRows.settingsNote(onboarding: false)
                == "A game or a role you turn off is hidden. Its cards, lists and decks stay in your folder.")
    }
}
