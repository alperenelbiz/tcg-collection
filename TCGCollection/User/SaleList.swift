import Foundation

/// For Sale's list: the for-sale printings as `CollectionEntry`s, so the screen uses the Collection's cell, search and sort
/// (A10). Pure; the view joins the collection with the catalog once (`RowsJoin`) and maps it here on every render.
nonisolated enum SaleList {
    /// One entry per for-sale printing, in the order of `sale`. Its `row.count` is the for-sale count; product, set,
    /// price and condition are the printing's collection entry's. A printing with no collection entry gets one from its
    /// saved name: no product, no price. The library keeps every for-sale printing owned (C8, also on a read), so that
    /// happens only while `collection` is older than `sale` (a change or a reload since the last join; the next join has
    /// it). The saved name is the for-sale entry's, else the collection row's.
    static func entries(sale: [SaleEntry], collection: [CollectionEntry]) -> [CollectionEntry] {
        let owned = Dictionary(collection.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sale.map { entry in
            guard let mine = owned[entry.key] else {
                return CollectionEntry(row: CollectionRow(productID: entry.productID, finish: entry.finish, count: entry.count,
                                                          condition: "", name: entry.name),
                                       product: nil, setName: "", price: nil, copiesOfCard: entry.count)
            }
            var row = mine.row
            row.count = entry.count
            if !entry.name.isEmpty { row.name = entry.name }
            return CollectionEntry(row: row, product: mine.product, setName: mine.setName, price: mine.price,
                                   copiesOfCard: mine.copiesOfCard)
        }
    }

    /// `3 copies · 2 printings · $41.50`: the copies, the printings and the summed price of the copies (price × count; a
    /// low price counts as its amount). Printings without a price are left out of the sum and counted after it:
    /// `… · $10.24 + 1 without a price`; with no priced printing, `… · 2 without a price`. With `all` (the search text is
    /// on), the Collection's form for the shown part: `1 of 3 copies · 1 of 2 printings · $5.12`; the sum is of the shown
    /// printings. "" for an empty list.
    static func totals(_ entries: [CollectionEntry], of all: [CollectionEntry]? = nil) -> String {
        guard !(all ?? entries).isEmpty else { return "" }
        let priced = entries.filter { $0.price != nil }
        let sum = priced.isEmpty ? nil : priced.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.row.count) }
        let tail = CollectionList.priceTail(sum: sum, unpriced: entries.count - priced.count)
        return ([CollectionList.totals(entries, of: all)] + [tail].compactMap { $0 }).joined(separator: " · ")
    }

    /// C7: the Sold dialog of a printing for its live for-sale count (`SoldDialog`: "Sold 1", and "Sold all <n>" when
    /// more than one copy is for sale). Nil when none is (the dialog closes). `generation` is the dialog's
    /// (`SoldDialogState`); every choice carries it with the printing and its copies (A1).
    static func soldDialog(key: PrintingKey, name: String, forSale count: Int, generation: Int) -> SoldDialog? {
        guard count > 0 else { return nil }
        return SoldDialog(key: key, name: name, count: count, generation: generation)
    }

    /// The system's dialog does not redraw while it is open (an alert sheet on the Mac). An open Sold dialog made for the
    /// count `shown` stays while the live count is the same, opens again with the live count when it changed (a reload,
    /// another window), and closes when nothing is for sale any more.
    static func follow(shown: Int, live: Int) -> SoldDialogStep {
        if live <= 0 { return .close }
        return live == shown ? .keep : .reopen(live)
    }
}

/// What an open Sold dialog does when the live for-sale count of its printing changed (`SaleList.follow`).
nonisolated enum SoldDialogStep: Equatable, Sendable {
    case keep
    case reopen(Int)
    case close
}

/// The Sold dialog of one printing (C7): "Sold <n> of <name>?" and its choices, made for the for-sale count `count`.
nonisolated struct SoldDialog: Equatable, Sendable {
    let key: PrintingKey
    let name: String
    /// The for-sale count the dialog was made for (more than 0).
    let count: Int
    /// The generation of `SoldDialogState` it was opened with.
    let generation: Int

    var title: String { "Sold \(count) of \(name)?" }

    /// "Sold 1", and "Sold all <n>" when more than one copy is for sale.
    var choices: [SoldChoice] {
        var choices = [SoldChoice(label: "Sold 1", count: 1, key: key, generation: generation)]
        if count > 1 { choices.append(SoldChoice(label: "Sold all \(count)", count: count, key: key, generation: generation)) }
        return choices
    }
}

/// One button of the Sold dialog: its label, the copies it sells, the printing, and its dialog's generation. One value
/// says what a click sells (A1).
nonisolated struct SoldChoice: Equatable, Hashable, Sendable {
    let label: String
    let count: Int
    let key: PrintingKey
    let generation: Int
}

/// For Sale's Sold dialog as a value (C7, A1): the dialog on show and a generation that every opening, closing, choice
/// and cancel moves on. Pure; `ForSaleView` keeps it and runs these decisions.
/// - A choice carries its dialog's generation (`SoldChoice`): a second activation of a dialog already chosen from (a
///   double click) sells nothing. A choice clicked on a dialog that is closing sells exactly what it shows; the library
///   refuses copies that are no longer there, and the status line says so (`AppModel.sell`): never nothing.
/// - The system's dialog does not redraw while it is open, so a changed live count closes it, and after a pause it opens
///   again with the count of that moment (`follow`, `reopen`). The reopen needs the generation of its close: a cancel, a
///   choice or another dialog since then means none, so a dialog the user cancelled never comes back.
/// - A reopen that finds a sheet open does not happen: the window would not show the dialog, and "Sold" (off while a
///   dialog is open, `isOpen`) would stay off.
nonisolated struct SoldDialogState: Equatable, Sendable {
    /// The dialog on show; nil while none is (also during the pause before it opens again).
    private(set) var dialog: SoldDialog?
    private(set) var generation = 0
    /// The dialog closed by `follow`, to open again after the pause.
    private var closedToReopen: SoldDialog?
    /// The generation of the last dialog a choice was made on.
    private var taken: Int?

    var isOpen: Bool { dialog != nil }

    /// "Sold" on a cell: the dialog of `key` for its for-sale count (none at 0).
    mutating func ask(key: PrintingKey, name: String, forSale count: Int) {
        close()
        dialog = SaleList.soldDialog(key: key, name: name, forSale: count, generation: generation)
    }

    /// The live for-sale count of the open dialog's printing is now `live` (a reload, another window): the dialog stays
    /// (the same count), closes (0), or closes to open again (`SaleList.follow`). Returns the generation `reopen` needs
    /// after the pause, or nil when no reopen is to come.
    mutating func follow(live: Int) -> Int? {
        guard let dialog else { return nil }
        switch SaleList.follow(shown: dialog.count, live: live) {
        case .keep:
            return nil
        case .close:
            close()
            return nil
        case .reopen:
            close()
            closedToReopen = dialog
            return generation
        }
    }

    /// After the pause: the dialog closed by `follow` opens again with its printing's live count, when the generation is
    /// still `token` (no cancel, choice or other dialog since), something is for sale, and no sheet is open. True when it
    /// opened; either way no other reopen is to come for `token`.
    mutating func reopen(_ token: Int, sheetOpen: Bool, live: (PrintingKey) -> Int) -> Bool {
        guard generation == token, let closed = closedToReopen else { return false }
        guard !sheetOpen else {
            close()
            return false
        }
        ask(key: closed.key, name: closed.name, forSale: live(closed.key))
        return dialog != nil
    }

    /// The user's Cancel (also Escape): the dialog closes, and no reopen on its way comes.
    mutating func cancel() {
        close()
    }

    /// The system set the dialog's binding to false: the user closed a dialog on show, as Cancel. Nothing when the app
    /// had closed it itself (`follow`, a choice): a reopen on its way still comes.
    mutating func dismissed() {
        if dialog != nil { close() }
    }

    /// A click on `choice`: what to sell (its own printing and copies), or nil for a second activation of a dialog
    /// already chosen from. Any choice ends the dialog: it closes, and no reopen on its way comes.
    mutating func choose(_ choice: SoldChoice) -> SoldChoice? {
        guard taken != choice.generation else { return nil }
        taken = choice.generation
        close()
        return choice
    }

    private mutating func close() {
        dialog = nil
        closedToReopen = nil
        generation += 1
    }
}
