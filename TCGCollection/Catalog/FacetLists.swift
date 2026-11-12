import Foundation

/// The values of the Rarity and Type filter menus of one game. Reading them from the store takes seconds for Magic, so
/// they are kept in `facets-<game>.json` and rewritten at the end of a catalog step that changed the game (P4).
nonisolated struct FacetLists: Codable, Sendable, Equatable {
    var rarities: [String]
    var types: [String]

    /// Nil when the file does not exist or cannot be decoded.
    static func read(_ url: URL) -> FacetLists? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FacetLists.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
