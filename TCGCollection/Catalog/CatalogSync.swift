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
    /// gameID: sets fetched for the first time.
    let newSets: [String: Int]
}

nonisolated enum SyncPlan {
    private static let recentDays = 90.0

    /// The group ids to fetch, in the order of `sets` (D5).
    static func due(sets: [SetRecord], fetchDates: [Int: Date], now: Date, rebuild: Bool) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return sets.filter { set in
            if rebuild { return true }
            guard let fetched = fetchDates[set.groupID] else { return true }
            let isRecent = set.publishedOn.map { now.timeIntervalSince($0) < recentDays * 86_400 } ?? true
            return isRecent && !calendar.isDate(fetched, inSameDayAs: now)
        }.map(\.groupID)
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

    func run(games: [GameDefinition], now: Date, rebuild: Bool,
             progress: @Sendable (SyncProgress) -> Void) async -> SyncResult {
        var fetched = 0, failed = 0, failedSetLists = 0
        var newSets: [String: Int] = [:]
        for game in games {
            // A cancelled sync stops: the sets it did not reach are not failed, only not fetched yet.
            if Task.isCancelled { break }
            guard let plan = await plan(for: game, now: now, rebuild: rebuild) else {
                failedSetLists += 1
                continue
            }
            var done = 0, gameFailed = 0
            let total = plan.due.count
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
                    var stored = false
                    if case .cards(let cards) = fetch {
                        stored = (try? await store.replaceProducts(of: groupID, with: cards, at: now)) != nil
                    }
                    if !stored { try? await store.markFailed(groupID) }
                    done += 1
                    if stored {
                        fetched += 1
                        if plan.neverFetched.contains(groupID) { newSets[game.id, default: 0] += 1 }
                    } else {
                        failed += 1
                        gameFailed += 1
                    }
                    progress(SyncProgress(gameID: game.id, done: done, total: total, failed: gameFailed))
                    startNext()
                }
            }
        }
        return SyncResult(fetched: fetched, failed: failed, failedSetLists: failedSetLists, newSets: newSets)
    }

    /// Fetches and stores the set list of one game. Nil when that fails.
    private func plan(for game: GameDefinition, now: Date, rebuild: Bool) async -> (due: [Int], neverFetched: Set<Int>)? {
        do {
            let body = try await client.groups(category: game.categoryID)
            try await store.upsertSets(try ProductParser.sets(body, game: game))
            let sets = try await store.sets(game: game.id)
            let dates = try await store.fetchDates(game: game.id)
            let due = SyncPlan.due(sets: sets, fetchDates: dates, now: now, rebuild: rebuild)
            return (due, Set(due.filter { dates[$0] == nil }))
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
