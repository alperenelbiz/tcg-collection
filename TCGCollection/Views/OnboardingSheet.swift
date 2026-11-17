import SwiftUI

/// The first-run question (G11, A29), pure: when it is asked, the draft it starts from, and what "Continue" writes.
nonisolated enum Onboarding {
    /// G11: the question is asked once a folder has been read (`loaded`: the library is loaded and the folder is not
    /// missing; the ledger's ruling) and the folder has no game file of any known game (a placeholder iCloud has not
    /// downloaded counts as a file; A30: the owner's folder is never asked). A Release build asks on any such folder; a
    /// Debug build only with `-store` and `-onboarding YES` (fails closed), so the UI tests' fresh roots do not all ask.
    static func isDue(loaded: Bool, hasGameFile: Bool, isDebugBuild: Bool, hasStore: Bool, asked: Bool) -> Bool {
        guard loaded, !hasGameFile else { return false }
        return isDebugBuild ? hasStore && asked : true
    }

    /// The draft the sheet starts from: no game ticked; a game, once ticked, has both roles on.
    static func draft(games: [GameDefinition]) -> [String: GameProfile] {
        Dictionary(uniqueKeysWithValues: games.map { ($0.id, GameProfile(followed: false, player: true, collector: true)) })
    }

    /// "Continue" is on once a game is ticked.
    static func canContinue(_ draft: [String: GameProfile]) -> Bool {
        draft.values.contains { $0.followed }
    }

    /// What "Continue" writes for a game: a ticked game as chosen; a game not ticked (or missing from the draft) not
    /// followed, with both roles on (roles chosen on a game unticked again are not kept).
    static func written(_ profile: GameProfile?) -> GameProfile {
        guard let profile, profile.followed else { return GameProfile(followed: false, player: true, collector: true) }
        return profile
    }
}

/// The first-run question, one screen (A29, "The look of the new parts"): "What do you collect?", one sentence, the games
/// and roles (`GameProfilesView` on a draft) and "Continue". It cannot be dismissed (no Cancel, no Esc); nothing is
/// written before "Continue" (`AppModel.finishOnboarding`).
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Onboarding.draft(games: Games.all)

    var body: some View {
        #if os(iOS)
        // Phase 6A: on the iPhone a large sheet that scrolls (four games of two rows each, the problem line, Continue).
        ScrollView { content }
            .presentationDetents([.large])
            .presentationBackground(Theme.ground)
            .interactiveDismissDisabled(true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-sheet")
        #else
        content
            .presentationBackground(Theme.ground)
            .interactiveDismissDisabled(true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-sheet")
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you collect?")
                    .font(Theme.onboardingTitleFont)
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("onboarding-title")
                Text("Tick the games you follow. You can change this later in Settings.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GameProfilesView(profiles: $draft, rows: ProfileRows.draftRows(games: Games.all, profiles: draft))
                .padding(.top, 20)
            // Final fix A2: why the last "Continue" could not finish (the folder is missing, a write failed); the sheet
            // stays open and "Continue" can be clicked again.
            if let problem = model.onboardingProblem {
                Text(problem)
                    .font(Theme.lineFont)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.lineGap)
                    .accessibilityIdentifier("onboarding-problem")
            }
            HStack {
                Spacer()
                Button("Continue") {
                    let chosen = draft
                    Task { await model.finishOnboarding(chosen) }
                }
                .sheetDefaultButton()
                .disabled(!Onboarding.canContinue(draft) || model.finishingOnboarding)
                .accessibilityIdentifier("onboarding-continue")
            }
            .padding(.top, 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Theme.sheetPadding)
        #if os(macOS)
        .frame(width: Theme.settingsWidth)
        #endif
    }
}
