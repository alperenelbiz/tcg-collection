import Foundation

/// One day of a printing's price history: the shown price of one finish (A37), marked when it is the low price.
nonisolated struct HistoryPoint: Sendable, Equatable {
    let day: String
    let amount: Double
    let isLow: Bool
}

nonisolated enum PriceHistoryError: Error, Equatable {
    /// Written by a newer version of the app: never rewritten (H3).
    case newerVersion
    /// Not a history file: the next write replaces it (H3).
    case malformed
}

/// One game's price history file, `<game id>.prices.json` (A34, H2), as a value. Derived data: unknown keys are not kept,
/// and an entry that does not fit is dropped on read (H3).
///
/// `{"days": ["2026-11-11", …], "products": {"<productID>": {"<finish>": {"low": [1], "prices": [12.4, null]}}},
/// "version": 1}`: `days` ascending (UTC archive days); each `prices` array has one element per day; `low` lists the day
/// indexes whose price is the low price (left out when empty). A finish with no price on any day is not written; a
/// product read with no price keeps its entry (`{}`), so it counts as read.
nonisolated struct PriceHistory: Sendable, Equatable {
    static let version = 1
    /// The largest amount a history holds (final fix M2): a larger one, or one that is not finite or not over 0, is no
    /// price for that day, so the chart's cents always fit an `Int`.
    static let maxAmount: Double = 1_000_000_000

    var days: [String]
    /// Product id → finish → one shown price per day of `days` (nil: no price that day).
    var products: [Int: [String: [ShownPrice?]]]

    init(days: [String] = [], products: [Int: [String: [ShownPrice?]]] = [:]) {
        self.days = days
        self.products = products
    }

    // MARK: Reading

    init(data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let versionValue = object["version"] as? NSNumber,
              CFGetTypeID(versionValue) != CFBooleanGetTypeID(),
              let version = GameUserFile.number(versionValue), version == version.rounded(), version >= 1
        else { throw PriceHistoryError.malformed }
        // Compared as a Double: a huge version (1e30) does not fit an Int.
        guard version <= Double(Self.version) else { throw PriceHistoryError.newerVersion }
        guard let days = object["days"] as? [String], zip(days, days.dropFirst()).allSatisfy({ $0 < $1 }),
              let rawProducts = object["products"] as? [String: Any]
        else { throw PriceHistoryError.malformed }

        var products: [Int: [String: [ShownPrice?]]] = [:]
        for (key, value) in rawProducts {
            guard let productID = Int(key), productID >= 0, String(productID) == key,
                  let rawFinishes = value as? [String: Any] else { continue }
            var finishes: [String: [ShownPrice?]] = [:]
            for (finish, rawFinish) in rawFinishes {
                guard let prices = Self.prices(rawFinish, dayCount: days.count) else { continue }
                if prices.contains(where: { $0 != nil }) { finishes[finish] = prices }
            }
            products[productID] = finishes
        }
        self.days = days
        self.products = products
    }

    /// Whether an amount counts as a price: finite, over 0 and at most `maxAmount`.
    static func isPrice(_ amount: Double) -> Bool { amount.isFinite && amount > 0 && amount <= maxAmount }

    /// One finish's prices, or nil when it does not fit: `prices` of another length than `days`, an element that is not a
    /// number or null, a `low` that is not a list of day indexes in range.
    private static func prices(_ value: Any, dayCount: Int) -> [ShownPrice?]? {
        guard let object = value as? [String: Any], let rawPrices = object["prices"] as? [Any],
              rawPrices.count == dayCount else { return nil }
        var low = Set<Int>()
        if let rawLow = object["low"], !(rawLow is NSNull) {
            guard let list = rawLow as? [Any] else { return nil }
            for element in list {
                guard let number = element as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let d = GameUserFile.number(number), d == d.rounded(), d >= 0, d < Double(dayCount)
                else { return nil }
                low.insert(Int(d))
            }
        }
        var prices: [ShownPrice?] = []
        for (index, element) in rawPrices.enumerated() {
            if element is NSNull {
                prices.append(nil)
            } else if let amount = GameUserFile.number(element) {
                prices.append(isPrice(amount) ? ShownPrice(amount: amount, isLow: low.contains(index)) : nil)
            } else {
                return nil
            }
        }
        return prices
    }

    // MARK: Writing

    /// The file's bytes: keys sorted, numbers as Swift prints them (the game file's number writer).
    func data() -> Data {
        var rawProducts: [String: Any] = [:]
        for (productID, finishes) in products {
            var rawFinishes: [String: Any] = [:]
            for (finish, prices) in finishes where prices.contains(where: { $0 != nil }) {
                var rawFinish: [String: Any] = [
                    "prices": prices.map { price -> Any in
                        price.map { GameUserFile.shortest(NSNumber(value: $0.amount)) } ?? NSNull()
                    },
                ]
                let low = prices.indices.filter { prices[$0]?.isLow == true }
                if !low.isEmpty { rawFinish["low"] = low }
                rawFinishes[finish] = rawFinish
            }
            rawProducts[String(productID)] = rawFinishes
        }
        let object: [String: Any] = ["days": days, "products": rawProducts, "version": Self.version]
        // Every value is a JSON type, so this cannot throw.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    // MARK: Questions

    /// The days with a price of this printing's finish, ascending.
    func points(productID: Int, finish: String) -> [HistoryPoint] {
        guard let prices = products[productID]?[finish] else { return [] }
        return zip(days, prices).compactMap { day, price in
            price.map { HistoryPoint(day: day, amount: $0.amount, isLow: $0.isLow) }
        }
    }

    /// Whether the product was read (it has an entry, also one with no price).
    func has(productID: Int) -> Bool { products[productID] != nil }

    // MARK: Changes

    /// Sets `day` for `products` from that day's rows: the day is added in order when new (every other array gets nil
    /// there); each named product gets its entry, also with no row, so it counts as read; its finishes take the rows'
    /// prices for that day (nil where a finish has none, or its amount is not a price: `isPrice`). Products not named keep
    /// what they had.
    mutating func setDay(_ day: String, rows: [Int: [String: ShownPrice]], for named: Set<Int>) {
        let index: Int
        if let known = days.firstIndex(of: day) {
            index = known
        } else {
            index = days.firstIndex(where: { $0 > day }) ?? days.count
            days.insert(day, at: index)
            for productID in Array(products.keys) {
                products[productID] = products[productID]!.mapValues { prices in
                    var padded = prices
                    padded.insert(nil, at: index)
                    return padded
                }
            }
        }
        for productID in named {
            var finishes = products[productID] ?? [:]
            let dayRows = (rows[productID] ?? [:]).filter { Self.isPrice($0.value.amount) }
            for finish in Array(finishes.keys) { finishes[finish]![index] = dayRows[finish] }
            for (finish, price) in dayRows where finishes[finish] == nil {
                var prices = [ShownPrice?](repeating: nil, count: days.count)
                prices[index] = price
                finishes[finish] = prices
            }
            products[productID] = finishes.filter { $0.value.contains(where: { $0 != nil }) }
        }
    }

    /// The history with only the days in `window` and only the products in `tracked`; a finish left with no price goes.
    func trimmed(window: ClosedRange<String>, keeping tracked: Set<Int>) -> PriceHistory {
        let kept = days.indices.filter { window.contains(days[$0]) }
        var result = PriceHistory(days: kept.map { days[$0] })
        for (productID, finishes) in products where tracked.contains(productID) {
            var trimmedFinishes: [String: [ShownPrice?]] = [:]
            for (finish, prices) in finishes {
                let trimmedPrices = kept.map { prices[$0] }
                if trimmedPrices.contains(where: { $0 != nil }) { trimmedFinishes[finish] = trimmedPrices }
            }
            result.products[productID] = trimmedFinishes
        }
        return result
    }
}
