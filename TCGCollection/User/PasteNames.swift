import Foundation
import SwiftData

/// The names a paste ranks its unknown names against (final fix B1): each game's `DeckPaste.NameIndex`, built from the
/// game's names (`read`) and kept in memory for the run, per (game, catalog version). Only the first paste with an
/// unknown name of a game, on a catalog version, reads the names and builds the index; the next ones take it as it is.
/// A newer catalog version drops every index of an older one (the catalog changed). A read that fails or is cancelled
/// keeps nothing. `AppModel` owns one for every paste sheet.
actor PasteNames {
    private let read: @Sendable (String) async throws -> [(cardKey: String, name: String)]
    /// The catalog version the kept indexes were built on.
    private var version: Int?
    private var indexes: [String: DeckPaste.NameIndex] = [:]

    init(read: @escaping @Sendable (String) async throws -> [(cardKey: String, name: String)]) {
        self.read = read
    }

    /// Reads each game's names from the store file of `container`, in four key ranges at once
    /// (`CatalogStore.cardNames(game:container:)`; throwaway stores, never `reader`).
    init(container: ModelContainer) {
        self.init { try await CatalogStore.cardNames(game: $0, container: container) }
    }

    /// The index of `game` on catalog version `version`: the kept one, else read and built now (off the main thread).
    func index(game: String, version: Int) async throws -> DeckPaste.NameIndex {
        if self.version != version {
            indexes = [:]
            self.version = version
        }
        if let kept = indexes[game] { return kept }
        let names = try await read(game)
        try Task.checkCancellation()
        let built = DeckPaste.NameIndex(names)
        // A newer version may have come in while this one was read: then this index is not kept.
        if self.version == version { indexes[game] = built }
        return built
    }
}
