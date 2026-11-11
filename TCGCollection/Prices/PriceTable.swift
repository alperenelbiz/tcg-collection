import Foundation
import Observation

nonisolated struct GamePrices: Codable, Sendable {
    var day: String
    var finishes: [String]
    /// productID: finish index: price
    var rows: [Int: [Int: Price]]
}

nonisolated struct FinishPrice: Sendable, Equatable {
    let finish: String
    let price: Price
}

/// Current prices of every game, in memory. One file per game on disk (`AppPaths.prices`).
@Observable
final class PriceTable {
    private var games: [String: GamePrices] = [:]

    func load(paths: AppPaths) {
        for game in Games.all {
            guard let data = try? Data(contentsOf: paths.prices(game.id)),
                  let prices = try? JSONDecoder().decode(GamePrices.self, from: data) else { continue }
            games[game.id] = prices
        }
    }

    /// Writes the game's file first, then swaps the table entry, so a failed write changes nothing.
    func replace(_ game: String, with prices: GamePrices, paths: AppPaths) throws {
        let data = try JSONEncoder().encode(prices)
        try data.write(to: paths.prices(game), options: .atomic)
        games[game] = prices
    }

    func prices(game: String, productID: Int) -> [FinishPrice] {
        guard let table = games[game], let byFinish = table.rows[productID] else { return [] }
        return byFinish.keys.sorted().compactMap { index in
            guard table.finishes.indices.contains(index) else { return nil }
            return FinishPrice(finish: table.finishes[index], price: byFinish[index]!)
        }
    }

    /// The lowest market price over the printings. A low price counts only when no printing has a market price.
    func cheapest(game: String, productIDs: [Int]) -> ShownPrice? {
        let shown = productIDs.flatMap { prices(game: game, productID: $0) }.compactMap(\.price.shown)
        let market = shown.filter { !$0.isLow }.min { $0.amount < $1.amount }
        return market ?? shown.min { $0.amount < $1.amount }
    }

    func day(game: String) -> String? { games[game]?.day }
}
