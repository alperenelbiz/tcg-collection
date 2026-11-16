import Testing
@testable import TCGCollection2

struct HistoryPlanTests {
    private let window = "2026-11-10"..."2026-11-14"
    private let price = ShownPrice(amount: 1.5, isLow: false)

    private func history(days: [String], products: [Int]) -> PriceHistory {
        PriceHistory(days: days,
                     products: Dictionary(uniqueKeysWithValues: products.map {
                         ($0, ["Normal": [ShownPrice?](repeating: price, count: days.count)])
                     }))
    }

    private func plan(archiveDays: Set<String>, failedDays: Set<String> = [],
                      games: [String: (history: PriceHistory?, tracked: Set<Int>)]) -> HistoryPlan {
        HistoryPlan.make(window: window, archiveDays: archiveDays, failedDays: failedDays, games: games)
    }

    @Test func aNewProductIsReadFromEveryArchiveInTheWindow() {
        let result = plan(archiveDays: ["2026-11-10", "2026-11-12", "2026-11-14"],
                          games: ["riftbound": (history: nil, tracked: [7])])
        #expect(result.days == ["2026-11-10", "2026-11-12", "2026-11-14"])
        #expect(result.reads == ["2026-11-10": ["riftbound": [7]], "2026-11-12": ["riftbound": [7]],
                                 "2026-11-14": ["riftbound": [7]]])
    }

    @Test func aKnownProductIsReadOnlyFromNewDays() {
        let old = history(days: ["2026-11-10", "2026-11-12"], products: [7])
        let result = plan(archiveDays: ["2026-11-10", "2026-11-12", "2026-11-14"],
                          games: ["riftbound": (history: old, tracked: [7, 8])])
        #expect(result.days == ["2026-11-10", "2026-11-12", "2026-11-14"])
        #expect(result.reads["2026-11-10"] == ["riftbound": [8]])
        #expect(result.reads["2026-11-12"] == ["riftbound": [8]])
        #expect(result.reads["2026-11-14"] == ["riftbound": [7, 8]])
    }

    @Test func aDayWithNothingNewIsNotPlanned() {
        let old = history(days: ["2026-11-10", "2026-11-12"], products: [7])
        let result = plan(archiveDays: ["2026-11-10", "2026-11-12"], games: ["riftbound": (history: old, tracked: [7])])
        #expect(result.days.isEmpty)
        #expect(result.reads.isEmpty)
    }

    @Test func aDayOutsideTheWindowIsNotRead() {
        let result = plan(archiveDays: ["2026-11-09", "2026-11-11", "2026-11-15"],
                          games: ["riftbound": (history: nil, tracked: [7])])
        #expect(result.days == ["2026-11-11"])
    }

    @Test func aFailedDayIsNotPlanned() {
        let result = plan(archiveDays: ["2026-11-11", "2026-11-12"], failedDays: ["2026-11-12"],
                          games: ["riftbound": (history: nil, tracked: [7])])
        #expect(result.days == ["2026-11-11"])
    }

    @Test func aDayInTheFileWithoutAnArchiveIsNotPlanned() {
        let old = history(days: ["2026-11-10", "2026-11-11"], products: [7])
        let result = plan(archiveDays: ["2026-11-11"], games: ["riftbound": (history: old, tracked: [7, 8])])
        #expect(result.days == ["2026-11-11"])
        #expect(result.reads == ["2026-11-11": ["riftbound": [8]]])
    }

    @Test func twoGamesShareOneReadOfADay() {
        let result = plan(archiveDays: ["2026-11-12"],
                          games: ["riftbound": (history: nil, tracked: [7]), "yu-gi-oh": (history: nil, tracked: [9])])
        #expect(result.days == ["2026-11-12"])
        #expect(result.reads == ["2026-11-12": ["riftbound": [7], "yu-gi-oh": [9]]])
    }

    @Test func aGameWithNothingToReadOnADayIsLeftOutOfThatDay() {
        let old = history(days: ["2026-11-12"], products: [7])
        let result = plan(archiveDays: ["2026-11-12"],
                          games: ["riftbound": (history: old, tracked: [7]), "yu-gi-oh": (history: nil, tracked: [9])])
        #expect(result.reads == ["2026-11-12": ["yu-gi-oh": [9]]])
    }

    @Test func nothingTrackedPlansNothing() {
        let result = plan(archiveDays: ["2026-11-11", "2026-11-12"],
                          games: ["riftbound": (history: history(days: ["2026-11-11"], products: [7]), tracked: []),
                                  "yu-gi-oh": (history: nil, tracked: [])])
        #expect(result.days.isEmpty)
        #expect(result.reads.isEmpty)
        #expect(plan(archiveDays: ["2026-11-11"], games: [:]).days.isEmpty)
    }

    // MARK: writes (H9)

    @Test func aNewDayOrANewProductWrites() {
        let old = history(days: ["2026-11-10"], products: [7])
        #expect(HistoryPlan.writes(old: old, new: history(days: ["2026-11-10", "2026-11-11"], products: [7])))
        #expect(HistoryPlan.writes(old: old, new: history(days: ["2026-11-10"], products: [7, 8])))
        #expect(HistoryPlan.writes(old: nil, new: history(days: ["2026-11-10"], products: [7])))
        #expect(HistoryPlan.writes(old: nil, new: history(days: [], products: [7])))
    }

    @Test func onlyARemovalDoesNotWrite() {
        let old = history(days: ["2026-11-10", "2026-11-11"], products: [7, 8])
        #expect(!HistoryPlan.writes(old: old, new: history(days: ["2026-11-10", "2026-11-11"], products: [7])))
        #expect(!HistoryPlan.writes(old: old, new: history(days: ["2026-11-11"], products: [7, 8])))
        #expect(!HistoryPlan.writes(old: old, new: history(days: ["2026-11-11"], products: [8])))
    }

    @Test func anEqualHistoryDoesNotWrite() {
        let old = history(days: ["2026-11-10"], products: [7])
        #expect(!HistoryPlan.writes(old: old, new: old))
        #expect(!HistoryPlan.writes(old: nil, new: PriceHistory()))
    }
}
