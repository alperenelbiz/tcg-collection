import Testing
@testable import TCGCollection2

/// The join of a list screen with the catalog (`CatalogJoin`, shared by the Collection, For Sale and Wanted): when it reads,
/// what it keeps of a failed or cancelled read, and a game without products.
@MainActor
struct CatalogJoinTests {
    private func key(_ library: Int, game: String = "riftbound") -> CollectionJoin {
        CollectionJoin(game: game, libraryVersion: library, catalogVersion: 1, priceDay: nil, catalogSettled: true)
    }

    private struct ReadFailed: Error {}

    /// Before the folder is read there is no join. Then once per key: the same key again reads nothing (a return to the
    /// screen), a new key reads again. The read is given the game.
    @Test func aJoinRunsOncePerKey() async throws {
        let store = try await filledStore()
        let join = CatalogJoin<[Int]>()
        var games: [String] = []
        func read(_ value: [Int]) -> (CatalogStore, String) async throws -> [Int] {
            { _, game in games.append(game); return value }
        }
        #expect(await join.run(key(1), loaded: false, reader: store, read: read([1])) == nil)
        #expect(games.isEmpty && join.joined == nil && join.read == nil)

        #expect(await join.run(key(1), loaded: true, reader: store, read: read([1])) == [1])
        #expect(join.read == [1] && join.joined == key(1) && !join.failed && join.catalogHasProducts)
        #expect(await join.run(key(1), loaded: true, reader: store, read: read([2])) == nil)
        #expect(join.read == [1] && games == ["riftbound"])
        #expect(await join.run(key(2), loaded: true, reader: store, read: read([2])) == [2])
        #expect(join.read == [2] && join.joined == key(2) && games == ["riftbound", "riftbound"])
    }

    /// A read that throws keeps the last good read and marks the join failed, with its key: the same key is then tried
    /// again (the next appearance of the screen), and a success clears the failure.
    @Test func aFailedJoinKeepsTheLastReadAndIsTriedAgain() async throws {
        let store = try await filledStore()
        let join = CatalogJoin<[Int]>()
        await join.run(key(1), loaded: true, reader: store) { _, _ in [1] }
        let failed = await join.run(key(2), loaded: true, reader: store) { _, _ in throw ReadFailed() }
        #expect(failed == nil && join.failed && join.joined == key(2) && join.read == [1])
        #expect(await join.run(key(2), loaded: true, reader: store) { _, _ in [3] } == [3])
        #expect(!join.failed && join.read == [3])
    }

    /// A game the catalog has no product of: the join ends (its key is kept, nothing is due) but stores no read, so the
    /// screen lists its rows alone.
    @Test func aGameWithoutProductsStoresNoRead() async throws {
        let store = try await filledStore()
        let join = CatalogJoin<[Int]>()
        await join.run(key(1), loaded: true, reader: store) { _, _ in [1] }
        let none = key(2, game: "no-such-game")
        #expect(await join.run(none, loaded: true, reader: store) { _, _ in [2] } == nil)
        #expect(join.read == nil && !join.catalogHasProducts && join.joined == none && !join.failed)
    }

    /// A cancelled join (the screen went away, or its key changed while it read) stores nothing: not its read, not a
    /// failure, not its key. Both when the read throws on the cancellation and when it returns anyway.
    @Test func aCancelledJoinStoresNothing() async throws {
        let store = try await filledStore()
        let join = CatalogJoin<[Int]>()
        await join.run(key(1), loaded: true, reader: store) { _, _ in [1] }
        let throwing = Task { await join.run(key(2), loaded: true, reader: store) { _, _ in
            try await Task.sleep(for: .seconds(10))
            return [2]
        } }
        try await Task.sleep(for: .milliseconds(50))
        throwing.cancel()
        #expect(await throwing.value == nil)
        let returning = Task { await join.run(key(3), loaded: true, reader: store) { _, _ in
            try? await Task.sleep(for: .seconds(10))
            return [3]
        } }
        try await Task.sleep(for: .milliseconds(50))
        returning.cancel()
        #expect(await returning.value == nil)
        #expect(join.read == [1] && join.joined == key(1) && !join.failed && join.catalogHasProducts)
    }
}
