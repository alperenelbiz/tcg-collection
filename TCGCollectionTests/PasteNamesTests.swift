import Foundation
import Testing
@testable import TCGCollection2

/// Counts the reads of a game's names that `PasteNames` asks for.
private actor Reads {
    private(set) var count = 0
    func add() { count += 1 }
}

/// Final fix B1: the names a paste ranks its unknown names against, kept in memory per (game, catalog version) for the
/// run: only the first paste with an unknown name of a game reads them.
struct PasteNamesTests {
    private static let names: [(cardKey: String, name: String)] = [("stardust dragon", "Stardust Dragon"), ("mist", "Mist")]

    @Test func theNamesAreReadOncePerGameAndCatalogVersion() async throws {
        let reads = Reads()
        let cache = PasteNames { _ in
            await reads.add()
            return Self.names
        }
        let first = try await cache.index(game: "yu-gi-oh", version: 1)
        #expect(first.nearest("Stardust Dragn", limit: 5).first?.name == "Stardust Dragon")
        _ = try await cache.index(game: "yu-gi-oh", version: 1)
        #expect(await reads.count == 1)
        _ = try await cache.index(game: "riftbound", version: 1)
        #expect(await reads.count == 2)
        _ = try await cache.index(game: "yu-gi-oh", version: 2)                 // the catalog changed
        #expect(await reads.count == 3)
        _ = try await cache.index(game: "riftbound", version: 2)                // dropped with version 1
        #expect(await reads.count == 4)
    }

    /// A read that fails stores nothing: the next paste reads again.
    @Test func aFailedReadIsNotKept() async throws {
        let reads = Reads()
        let cache = PasteNames { _ in
            await reads.add()
            if await reads.count == 1 { throw CancellationError() }
            return Self.names
        }
        await #expect(throws: CancellationError.self) { try await cache.index(game: "yu-gi-oh", version: 1) }
        _ = try await cache.index(game: "yu-gi-oh", version: 1)
        _ = try await cache.index(game: "yu-gi-oh", version: 1)
        #expect(await reads.count == 2)
    }
}
