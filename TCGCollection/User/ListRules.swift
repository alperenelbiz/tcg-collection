import Foundation

/// Pure rules over the Wanted and For Sale lists and the sold log. No clock: the caller gives the day.
nonisolated enum ListRules {
    /// Sets the wanted count of one card. Count <= 0 removes the entry; a new entry is appended with no pin. An existing
    /// entry keeps its name and pin.
    static func settingWanted(_ list: [WantedEntry], count: Int, cardKey: String, name: String) -> [WantedEntry] {
        var list = list
        if let i = list.firstIndex(where: { $0.cardKey == cardKey }) {
            if count <= 0 { list.remove(at: i) } else { list[i].count = count }
        } else if count > 0 {
            list.append(WantedEntry(cardKey: cardKey, name: name, count: count, pinProductID: nil, pinFinish: nil))
        }
        return list
    }

    /// Pins a wanted card to one printing, or takes the pin away (`nil`). A card not on the list changes nothing.
    static func pinning(_ list: [WantedEntry], cardKey: String, to pin: PrintingKey?) -> [WantedEntry] {
        var list = list
        guard let i = list.firstIndex(where: { $0.cardKey == cardKey }) else { return list }
        list[i].pinProductID = pin?.productID
        list[i].pinFinish = pin?.finish
        return list
    }

    /// Sets the for-sale count of one printing, clamped to `0...owned`. 0 removes the entry; a new entry is appended. An
    /// existing entry keeps its name.
    static func settingForSale(_ list: [SaleEntry], count: Int, key: PrintingKey, name: String, owned: Int) -> [SaleEntry] {
        let count = min(max(count, 0), max(owned, 0))
        var list = list
        if let i = list.firstIndex(where: { $0.key == key }) {
            if count == 0 { list.remove(at: i) } else { list[i].count = count }
        } else if count > 0 {
            list.append(SaleEntry(productID: key.productID, finish: key.finish, count: count, name: name))
        }
        return list
    }

    /// C8: every for-sale count over its printing's owned count is lowered to it (removed at 0). `lost` is the number of
    /// copies taken off the list.
    static func clamped(_ list: [SaleEntry], to collection: [CollectionRow]) -> (list: [SaleEntry], lost: Int) {
        var lost = 0
        var result: [SaleEntry] = []
        for var entry in list {
            let owned = CollectionRules.count(collection, for: entry.key)
            if entry.count > owned {
                lost += entry.count - owned
                entry.count = owned
            }
            if entry.count > 0 { result.append(entry) }
        }
        return (result, lost)
    }

    /// C7: `count` copies of one printing are sold: the owned and the for-sale counts go down by `count` (a row at 0 is
    /// removed), and one record is appended. Nil when `count < 1`, or more than are for sale or owned: nothing is sold.
    /// It takes nothing more: a for-sale count that was over the owned one stays over by as much, for the one clamp
    /// (`clamped`, in `UserLibrary`'s change) to take and to say.
    static func selling(_ file: GameUserFile, key: PrintingKey, count: Int, day: String, price: ShownPrice?) -> GameUserFile? {
        let owned = CollectionRules.count(file.collection, for: key)
        guard let i = file.forSale.firstIndex(where: { $0.key == key }), count >= 1, count <= file.forSale[i].count,
              count <= owned else {
            return nil
        }
        let sale = file.forSale[i]
        let name = sale.name.isEmpty ? file.collection.first(where: { $0.key == key })?.name ?? "" : sale.name
        var file = file
        file.collection = CollectionRules.setting(file.collection, count: owned - count, for: key, name: name)
        if sale.count == count { file.forSale.remove(at: i) } else { file.forSale[i].count -= count }
        file.sold.append(SoldRecord(productID: key.productID, finish: key.finish, count: count, name: name, day: day,
                                    price: price?.amount, priceIsLow: price?.isLow ?? false))
        return file
    }
}
