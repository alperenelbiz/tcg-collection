import Foundation

nonisolated struct SyncProgress: Sendable, Equatable {
    let gameID: String
    let done: Int
    let total: Int
    let failed: Int
}

nonisolated struct SyncResult: Sendable, Equatable {
    let fetched: Int
    /// Sets whose products could not be fetched or stored.
    let failed: Int
    /// Games whose set list could not be loaded (no network at first launch fails here). Not counted in `failed`.
    var failedSetLists = 0
    /// Sets removed from the store because the game excludes them (A6). A removal changes what the store holds.
    var removedSets = 0
    /// gameID: sets fetched for the first time.
    let newSets: [String: Int]
}

nonisolated enum SyncPlan {
    private static let recentDays = 90.0

    /// The group ids to fetch, in the order of `sets` (D5). No set is fetched twice in one day (UTC), not even by a
    /// rebuild or a rule change: `rebuild` fetches every set that was not fetched today. A set stored under an older
    /// `CatalogRules.version` is fetched once more (P3). A set missing from `rulesVersions` (no products) counts as current.
    static func due(sets: [SetRecord], fetchDates: [Int: Date], rulesVersions: [Int: Int], now: Date, rebuild: Bool) -> [Int] {
        sets.filter { set in
            guard let fetched = fetchDates[set.groupID] else { return true }
            if fetchedToday(fetched, now: now) { return false }
            if rebuild || isOld(rulesVersions[set.groupID]) { return true }
            return set.publishedOn.map { now.timeIntervalSince($0) < recentDays * 86_400 } ?? true
        }.map(\.groupID)
    }

    /// True when `version` is below the app's rules version. Nil (no row) is current.
    static func isOld(_ version: Int?) -> Bool {
        version.map { $0 < CatalogRules.version } ?? false
    }

    /// Same UTC day as `now`.
    static func fetchedToday(_ fetched: Date, now: Date) -> Bool {
        utc.isDate(fetched, inSameDayAs: now)
    }

    /// The UTC day of `date` as `yyyy-MM-dd`.
    static func utcDay(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

actor CatalogSync {
    private static let maxConcurrent = 4

    private let store: CatalogStore
    private let client: any TCGCSVFetching

    init(store: CatalogStore, client: any TCGCSVFetching) {
        self.store = store
        self.client = client
    }

    /// `changing` is called once per game, before the step stores or fails the game's first set, and after it removed
    /// a set of the game (A6): from then on the game's derived files may be stale (the set index's due mark, phase 4A
    /// final fix A3).
    func run(games: [GameDefinition], now: Date, rebuild: Bool,
             changing: @Sendable (String) -> Void = { _ in },
             progress: @Sendable (SyncProgress) -> Void) async -> SyncResult {
        var fetched = 0, failed = 0, failedSetLists = 0, removedSets = 0
        var newSets: [String: Int] = [:]
        for game in games {
            // A cancelled sync stops: the sets it did not reach are not failed, only not fetched yet.
            if Task.isCancelled { break }
            guard let plan = await plan(for: game, now: now, rebuild: rebuild) else {
                // A set list request cancelled (the iPhone went to the background, Task 1B) is no failure.
                if Task.isCancelled { break }
                failedSetLists += 1
                continue
            }
            removedSets += plan.removed
            var told = plan.removed > 0
            if told { changing(game.id) }
            // The progress line counts the whole game: `total` is every set of the game that it keeps, `done` is the
            // sets that are not due any more in this run (B11), so it moves during a re-fetch too.
            var stillDue = plan.due.count, gameFailed = 0
            let total = plan.total
            if plan.due.isEmpty && total > 0 { progress(SyncProgress(gameID: game.id, done: total, total: total, failed: 0)) }
            // At most `maxConcurrent` child tasks are alive: a new one starts when one ends.
            // Fetch and parse run in the children; the store is written here, one set at a time.
            // A cancelled group (the sync's task was cancelled) starts no new child.
            await withTaskGroup(of: (Int, Fetch).self) { group in
                var pending = plan.due.makeIterator()
                func startNext() {
                    guard let groupID = pending.next() else { return }
                    let client = self.client
                    _ = group.addTaskUnlessCancelled { (groupID, await Self.fetchCards(groupID, game: game, client: client)) }
                }
                for _ in 0..<Self.maxConcurrent { startNext() }
                while let (groupID, fetch) = await group.next() {
                    if case .cancelled = fetch {
                        // The set stays as it was: a cancelled fetch says nothing about it.
                        group.cancelAll()
                        continue
                    }
                    if !told {
                        told = true
                        changing(game.id)
                    }
                    var stored = false
                    if case .cards(let cards) = fetch {
                        stored = (try? await store.replaceProducts(of: groupID, with: cards, at: now)) != nil
                    }
                    if !stored { try? await store.markFailed(groupID) }
                    if stored {
                        fetched += 1
                        if plan.neverFetched.contains(groupID) {
                            newSets[game.id, default: 0] += 1
                        }
                    } else {
                        failed += 1
                        gameFailed += 1
                    }
                    stillDue -= 1
                    progress(SyncProgress(gameID: game.id, done: total - stillDue, total: total, failed: gameFailed))
                    startNext()
                }
            }
        }
        return SyncResult(fetched: fetched, failed: failed, failedSetLists: failedSetLists, removedSets: removedSets, newSets: newSets)
    }

    /// Fetches and stores the set list of one game. Nil when that fails.
    /// `total` is every set of the game that it keeps. Sets the game excludes (A6) are not stored, and removed when an
    /// earlier rules version stored them: removing is not a fetch, so it happens on any day.
    private func plan(for game: GameDefinition, now: Date, rebuild: Bool) async
        -> (due: [Int], neverFetched: Set<Int>, total: Int, removed: Int)? {
        do {
            let body = try await client.groups(category: game.categoryID)
            let listed = try ProductParser.sets(body, game: game)
            let excluded = Set(listed.filter { game.excludesSet(named: $0.name) }.map(\.groupID))
            let removed = try await store.removeSets(Array(excluded))
            try await store.upsertSets(listed.filter { !game.excludesSet(named: $0.name) })
            let sets = try await store.sets(game: game.id)
            let dates = try await store.fetchDates(game: game.id)
            let versions = try await store.rulesVersions(game: game.id)
            let due = SyncPlan.due(sets: sets, fetchDates: dates, rulesVersions: versions, now: now, rebuild: rebuild)
            return (due, Set(due.filter { dates[$0] == nil }), sets.count, removed)
        } catch {
            return nil
        }
    }

    /// What the fetch of one set gave.
    private enum Fetch: Sendable {
        /// Zero cards is a success.
        case cards([ProductRecord])
        /// The fetch or the parse failed: the set is marked failed.
        case failed
        /// The task was cancelled (`CancellationError`, `URLError.cancelled`).
        case cancelled
    }

    private static func fetchCards(_ groupID: Int, game: GameDefinition, client: any TCGCSVFetching) async -> Fetch {
        do {
            let body = try await client.products(category: game.categoryID, group: groupID)
            return .cards(try ProductParser.products(body, game: game).cards)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }
}
