#if DEBUG
import Foundation
import SwiftData

/// `-catalogReport YES`, the decks part (phase 3A task 8): each game's cards by deck kind (`CardKinds.deckKind`, the one kind
/// rule), and the times of the deck reads on the store the report runs on: a paste from "Read" to its table
/// (`PasteDeckModel.read`) with misspelt names and how well the nearest names find them, a deck page's first join, the reads
/// of a deck's search, and the work of one render of a deck page; Wanted with two active decks of 60 cards (phase 3B task 8).
/// Printed after `CatalogReport`; the written numbers are in `docs/reports/2026-11-catalog-report.md`, "Decks, phase 3A
/// check" and "Sharing, phase 3B check".
@MainActor
enum DeckReport {
    static func text(model: AppModel) async throws -> String {
        var lines: [String] = []
        for game in Games.all {
            lines += try await kindLines(game, store: CatalogStore(modelContainer: model.reader.modelContainer),
                                         ygo: game.pictures == .ygoprodeck ? model.ygoIndex : nil)
            lines.append("")
        }
        lines += try await pasteLines(model: model)
        lines.append("")
        lines += try await joinLines(model: model)
        lines.append("")
        lines += try await searchLines(model: model)
        lines.append("")
        lines += try await wantedLines(model: model)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Kinds

    /// Card keys per group, per default section of each format, and the Other count; for Yu-Gi-Oh! which source gave the
    /// kind (YGOPRODeck type, TCGplayer type, neither) and where the two disagree about the Extra Deck.
    private static func kindLines(_ game: GameDefinition, store: CatalogStore, ygo: YGOPictureIndex?) async throws -> [String] {
        let names = try await store.cardNames(game: game.id)
        let cards = try await store.cards(game: game.id, keys: names.map(\.cardKey))
        var lines = ["== Deck kinds: \(game.name) (\(cards.count) card keys)"]
        guard !game.formats.isEmpty else { return lines + ["no deck formats"] }
        let ygoType: (String) -> String? = { ygo?.type(name: $0) }
        var kinds: [String: CardKind] = [:]
        for (key, card) in cards {
            kinds[key] = CardKinds.deckKind(game: game, cardType: card.cardType, cardName: card.name, ygoType: ygoType)
        }
        var groups: [String: Int] = [:]
        for kind in kinds.values { groups[kind.group, default: 0] += 1 }
        lines.append("groups: " + game.deckGroups.map { "\($0) \(groups[$0] ?? 0)" }.joined(separator: ", "))
        let unknownGroups = groups.keys.filter { !game.deckGroups.contains($0) }.sorted()
        if !unknownGroups.isEmpty { lines.append("groups outside the game's list: \(unknownGroups)") }
        for format in game.formats {
            var sections: [String: Int] = [:]
            for kind in kinds.values { sections[game.defaultSection(format: format, kind: kind), default: 0] += 1 }
            lines.append("default sections, \(format.name): "
                         + format.sections.map { "\($0.name) \(sections[$0.id] ?? 0)" }.joined(separator: ", "))
        }
        let typeless = cards.values.filter { $0.cardType.isEmpty }
        lines.append("Other: \(groups[CardKind.other] ?? 0) (of those, no printing with a card type: "
                     + "\(typeless.filter { kinds[$0.cardKey]?.group == CardKind.other }.count))")
        let otherTypes = Dictionary(grouping: cards.values.filter { kinds[$0.cardKey]?.group == CardKind.other && !$0.cardType.isEmpty },
                                    by: \.cardType).mapValues(\.count)
        if !otherTypes.isEmpty {
            lines.append("card types of the Other keys that have one (10 most common): "
                         + otherTypes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10)
                            .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if game.pictures == .ygoprodeck {
            lines += yugiohSourceLines(game, cards: Array(cards.values), ygo: ygo)
        }
        return lines
    }

    private static func yugiohSourceLines(_ game: GameDefinition, cards: [CatalogCard], ygo: YGOPictureIndex?) -> [String] {
        let fallback = cards.map { CardKinds.yugioh(cardType: $0.cardType, ygoType: nil) }
        let typed = cards.filter { !$0.cardType.isEmpty }.count
        var lines = ["TCGplayer type alone (the fallback of A15): Extra Deck \(fallback.count { $0.flags.contains(CardKind.extraDeck) }), "
                     + "Main Deck \(fallback.count { $0.group != CardKind.other && !$0.flags.contains(CardKind.extraDeck) }), "
                     + "Other \(fallback.count { $0.group == CardKind.other }); "
                     + "keys with a typed printing \(typed), with none \(cards.count - typed)"]
        guard let ygo else {
            return lines + ["YGOPRODeck types: no Yu-Gi-Oh! index on this store: the two sources are not compared"]
        }
        var withType = 0, fallsBack = 0, neither = 0
        var disagree: [String] = []
        for card in cards {
            let frame = ygo.type(name: card.name)
            let byIndex = frame.map { CardKinds.yugioh(cardType: "", ygoType: $0) }
            if frame != nil {
                withType += 1
            } else if card.cardType.isEmpty {
                neither += 1
            } else {
                fallsBack += 1
            }
            if let byIndex, !card.cardType.isEmpty,
               byIndex.flags.contains(CardKind.extraDeck)
                != CardKinds.yugioh(cardType: card.cardType, ygoType: nil).flags.contains(CardKind.extraDeck) {
                disagree.append("\(card.name): YGOPRODeck \(frame ?? ""), TCGplayer \(card.cardType)")
            }
        }
        lines.append("YGOPRODeck type \(withType), TCGplayer fallback \(fallsBack), neither \(neither)")
        lines.append("disagree about the Extra Deck: \(disagree.count)")
        return lines + disagree.sorted().prefix(20).map { "  \($0)" }
    }

    // MARK: The paste

    /// One text of the paste check: `lines` names of `game` from the catalog, the first `misspelt` of them misspelt.
    private struct PasteCase {
        let game: String
        let lines: Int
        let misspelt: Int
        /// Which names of the game's list: every `stride`-th from `offset`.
        let offset: Int
    }

    private static let pasteCases: [PasteCase] = [60, 100].flatMap { lines in
        [0, 10, 30].map { PasteCase(game: "magic-the-gathering", lines: lines, misspelt: $0, offset: lines == 60 ? 0 : 1) }
    } + [0, 10, 30].map { PasteCase(game: "yu-gi-oh", lines: 60, misspelt: $0, offset: 0) }
      + [PasteCase(game: "riftbound", lines: 30, misspelt: 30, offset: 0),
         PasteCase(game: "cyberpunk", lines: 30, misspelt: 30, offset: 0)]

    /// The misspelling rule: the name without its third letter (`Lightning Bolt` → `Ligtning Bolt`). Nil for a name of
    /// fewer than four letters.
    static func misspelt(_ name: String) -> String? {
        var letters = 0
        for index in name.indices where name[index].isLetter {
            letters += 1
            if letters == 3 {
                let result = String(name[..<index]) + String(name[name.index(after: index)...])
                return result.count(where: \.isLetter) >= 3 ? result : nil
            }
        }
        return nil
    }

    /// The names of a case: every `stride`-th card of the game's list (by key) from `offset`, with at least 4 letters, so
    /// the sample runs over the whole alphabet. Distinct names.
    private static func sample(_ names: [(cardKey: String, name: String)], count: Int, offset: Int) -> [(cardKey: String, name: String)] {
        let usable = names.filter { $0.name.count(where: \.isLetter) >= 4 && misspelt($0.name) != nil }
        guard !usable.isEmpty else { return [] }
        let step = max(1, usable.count / (count + 1))
        return stride(from: offset % step, to: usable.count, by: step).prefix(count).map { usable[$0] }
    }

    /// Where the right card stood among a misspelt line's suggestions.
    private enum Hit { case first, top5, absent, matched, other }

    private static func pasteLines(model: AppModel) async throws -> [String] {
        var lines = ["== Paste (PasteDeckModel.read on this store: parse, exact keys, the game's name index, the ranking, "
                     + "the suggestions' cards; one line per text: first run (the names read and indexed) / median of 3 "
                     + "(the index kept in memory, PasteNames); the misspelling drops the third letter)"]
        var names: [String: [(cardKey: String, name: String)]] = [:]
        var hits: [String: [Hit]] = [:]
        var failures: [String: [String]] = [:]
        for game in Games.all.map(\.id) {
            names[game] = try await CatalogStore.cardNames(game: game, container: model.reader.modelContainer)
        }
        for test in pasteCases {
            guard let game = Games.game(test.game), let all = names[test.game] else { continue }
            let picked = sample(all, count: test.lines, offset: test.offset)
            var expected: [Int: (cardKey: String, name: String)] = [:]
            let text = picked.enumerated().map { index, card in
                if index < test.misspelt, let wrong = misspelt(card.name) {
                    expected[index + 1] = card
                    return "1 \(wrong)"
                }
                return "1 \(card.name)"
            }.joined(separator: "\n")
            var times: [Duration] = []
            var paste: PasteDeckModel?
            // One kept index per text, as the app keeps one per game for the run: the first run reads the names.
            let kept = PasteNames(container: model.reader.modelContainer)
            for _ in 0..<3 {
                let run = PasteDeckModel(gameID: game.id, deckID: nil, text: text, library: model.library,
                                         reader: model.reader, catalogSettled: { _ in true },
                                         ygoType: { model.ygoType(cardName: $0) }, names: kept, catalogVersion: { 1 })
                guard run.canRead else {
                    lines.append("\(game.name) \(test.lines) lines: Read is off (\(run.problem ?? run.catalogBlock ?? "?"))")
                    break
                }
                let start = ContinuousClock.now
                await run.read()
                times.append(ContinuousClock.now - start)
                paste = run
            }
            guard let paste, !times.isEmpty else { continue }
            let shown = paste.lines
            let unknown = shown.filter { if case .unknown = $0.match { true } else { false } }.count
            lines.append("\(game.name) \(test.lines) lines, \(test.misspelt) misspelt: \(ms(times[0])) / \(ms(times.sorted()[times.count / 2])); "
                         + "\(unknown) unknown, \(paste.summary)")
            guard test.misspelt == 30 else { continue }
            for line in shown {
                guard let card = expected[line.number] else { continue }
                let hit: Hit
                switch line.match {
                case .unknown(let suggestions):
                    let rank = suggestions.firstIndex { $0.cardKey == card.cardKey }
                    hit = rank == 0 ? .first : rank != nil ? .top5 : .absent
                    if rank != 0 {
                        failures[game.id, default: []].append("\(line.text) (for \(card.name)): "
                            + (suggestions.isEmpty ? "no suggestion" : suggestions.map(\.name).joined(separator: "; ")))
                    }
                case .card(let key, _): hit = key == card.cardKey ? .matched : .other
                case .dropped: hit = .other
                }
                hits[game.id, default: []].append(hit)
            }
        }
        lines.append("Nearest names of the misspelt lines (texts with 30 misspelt): right card first / in the top 5 / absent "
                     + "(+ matched by its base name, + an exact name of another card):")
        for game in Games.all {
            guard let found = hits[game.id] else { continue }
            let first = found.count { $0 == .first }, top = found.count { $0 == .top5 }
            let absent = found.count { $0 == .absent }
            let checked = first + top + absent
            lines.append("  \(game.name): \(first) / \(top) / \(absent) of \(checked) "
                         + "(first \(percent(first, checked)), top 5 \(percent(first + top, checked))); "
                         + "+ \(found.count { $0 == .matched }) matched, + \(found.count { $0 == .other }) another card")
            lines += (failures[game.id] ?? []).prefix(10).map { "    \($0)" }
        }
        lines += try await rankingLines(names: names, container: model.reader.modelContainer)
        return lines
    }

    /// The two halves of an unknown name's work, timed alone: the game's names read (`cardNames` in one read on a
    /// throwaway store, and in four key ranges at once as the paste reads them), the index built, and 30 names ranked.
    private static func rankingLines(names: [String: [(cardKey: String, name: String)]],
                                     container: ModelContainer) async throws -> [String] {
        var lines = ["Alone (median of 3):"]
        for game in ["magic-the-gathering", "yu-gi-oh"] {
            guard let all = names[game] else { continue }
            let read = try await durations(3) {
                _ = try await CatalogStore(modelContainer: container).cardNames(game: game)
            }
            let ranges = try await durations(3) {
                _ = try await CatalogStore.cardNames(game: game, container: container)
            }
            let wrong = sample(all, count: 30, offset: 0).compactMap { misspelt($0.name) }
            var index: DeckPaste.NameIndex?
            let build = await durations(3) { index = await indexed(all) }
            let built = index!
            let rank = await durations(3) { await ranked(wrong, in: built) }
            lines.append("  \(game): cardNames \(all.count) names: one read \(ms(read)), four ranges at once \(ms(ranges)); "
                         + "index \(ms(build)); 30 names ranked \(ms(rank))")
        }
        return lines
    }

    @concurrent private nonisolated static func indexed(_ names: [(cardKey: String, name: String)]) async -> DeckPaste.NameIndex {
        DeckPaste.NameIndex(names)
    }

    @concurrent private nonisolated static func ranked(_ names: [String], in index: DeckPaste.NameIndex) async {
        for name in names { _ = index.nearest(name, limit: 5) }
    }

    // MARK: A deck page

    /// A deck page's first join (`reader.printings` of the deck's keys and `DeckPage.read`, as `DeckJoin.run`) and the work
    /// of one render on it (`DeckPage.content`): a Magic deck of 60 and one of 100 distinct cards, and a Riftbound deck of
    /// the first 40 owned cards (with the collection, so `missing` is worked out).
    private static func joinLines(model: AppModel) async throws -> [String] {
        var lines = ["== Deck page (the first join through a fresh store; then median of 3 on reader; one render's DeckPage.content)"]
        let magic = try await CatalogStore(modelContainer: model.reader.modelContainer).cardNames(game: "magic-the-gathering")
        let riftboundRows = model.library.rows(game: "riftbound")
        let riftboundKeys = try await ownedKeys(rows: riftboundRows, model: model, limit: 40)
        let cases: [(String, String, String, [String], [CollectionRow])] = [
            ("magic-the-gathering", "constructed", "Magic 60 distinct cards", sample(magic, count: 60, offset: 2).map(\.cardKey), []),
            ("magic-the-gathering", "commander", "Magic 100 distinct cards", sample(magic, count: 100, offset: 3).map(\.cardKey), []),
            ("riftbound", "standard", "Riftbound \(riftboundKeys.count) owned cards", riftboundKeys, riftboundRows),
        ]
        for (gameID, format, label, keys, rows) in cases {
            guard let game = Games.game(gameID) else { continue }
            let deck = Deck(id: "report", name: label, format: format, active: true,
                            cards: keys.map { DeckCard(cardKey: $0, name: $0, section: "", count: 1) })
            let fresh = CatalogStore(modelContainer: model.reader.modelContainer)
            var read: DeckRead?
            let first = try await durations(1) { read = try await join(game: game, keys: keys, rows: rows, store: fresh) }
            let again = try await durations(3) { read = try await join(game: game, keys: keys, rows: rows, store: model.reader) }
            var placed = deck
            placed.cards = deck.cards.map { card in
                var card = card
                card.section = DeckPage.addSection(game: game, format: game.format(format), kind: read?.kinds[card.cardKey])
                return card
            }
            var sections = 0
            let render = await durations(3) {
                // One deck alone: every owned copy is available to it.
                let content = DeckPage.content(placed, game: game, read: read, available: read?.ownedByCard ?? [:],
                                               joinFailed: false, catalogHasProducts: true, catalogSettled: true,
                                               price: { _ in nil })
                sections = content.sections.count
            }
            let printings = read?.printings.values.reduce(0) { $0 + $1.count } ?? 0
            lines.append("\(label): join \(ms(first.median)) first, \(ms(again.median)) again; \(printings) printings; "
                         + "render \(preciseMs(render.median)), \(sections) sections")
        }
        return lines
    }

    private static func join(game: GameDefinition, keys: [String], rows: [CollectionRow], store: CatalogStore) async throws -> DeckRead {
        let printings = try await store.printings(game: game.id, cardKeys: keys)
        return DeckPage.read(game: game, printings: printings, keys: Set(keys), rows: rows, ygoType: { _ in nil })
    }

    /// The card keys of the first `limit` distinct cards of `rows`, in the rows' order.
    private static func ownedKeys(rows: [CollectionRow], model: AppModel, limit: Int) async throws -> [String] {
        let products = try await model.reader.products(ids: rows.map(\.productID), game: "riftbound")
        var keys: [String] = []
        for row in rows {
            guard let product = products[row.productID] else { continue }
            let key = CardName.searchKey(product.cardName)
            if !keys.contains(key) { keys.append(key) }
            if keys.count == limit { break }
        }
        return keys
    }

    // MARK: A deck's search

    /// "Add cards": the search (limit 301, as the screen) and then the printings of the 300 shown cards, one
    /// `printings(game:cardKeys:)` call (`CatalogSearchView.search`), on `reader`; median of 3.
    private static func searchLines(model: AppModel) async throws -> [String] {
        var lines = ["== A deck's search (Magic; on reader; median of 3)"]
        for text in ["a", "fire"] {
            var shown: [CardSummary] = []
            let search = try await durations(3) {
                shown = Array(try await model.reader.search(game: "magic-the-gathering", text: text, filter: .init(), limit: 301)
                    .prefix(300))
            }
            var printings = 0
            let read = try await durations(3) {
                printings = try await model.reader.printings(game: "magic-the-gathering", cardKeys: shown.map(\.id))
                    .values.reduce(0) { $0 + $1.count }
            }
            lines.append("\"\(text)\": search \(ms(search.median)), \(shown.count) cards; their printings \(ms(read.median)), "
                         + "\(printings) printings")
        }
        return lines
    }

    // MARK: Wanted with two active decks

    /// Wanted's join (`WantedJoin.run`: `WantedList.joinKeys`, `reader.printings` and `sets`, `WantedList.read`) and the work
    /// of one render (`WantedList.content`, sorted, totals) with two active Riftbound decks of 60 owned cards each, 30 of
    /// them in both (one copy each: a card owned once is pending), on the collection; then one render after a `+` (a
    /// hand-added copy of the first deck's first card: the render that shows the new count, before the next join).
    private static func wantedLines(model: AppModel) async throws -> [String] {
        var lines = ["== Wanted with 2 active decks (the first join through a fresh store; then median of 3 on reader; "
                     + "median of 3 renders)"]
        guard let game = Games.game("riftbound") else { return lines }
        let rows = model.library.rows(game: game.id)
        let owned = try await ownedKeys(rows: rows, model: model, limit: 90)
        guard owned.count == 90 else {
            lines.append("not measured: \(owned.count) distinct owned Riftbound cards, 90 needed")
            return lines
        }
        let decks = [Array(owned[0..<60]), Array(owned[30..<90])].enumerated().map { index, keys in
            Deck(id: "report-\(index)", name: "Report \(index + 1)", format: "standard", active: true,
                 cards: keys.map { DeckCard(cardKey: $0, name: $0, section: "main", count: 1) })
        }
        let wanted: [WantedEntry] = []
        func join(_ store: CatalogStore) async throws -> WantedRead {
            let keys = WantedList.joinKeys(wanted: wanted, decks: decks)
            let printings = try await store.printings(game: game.id, cardKeys: Array(keys))
            let sets = try await store.sets(game: game.id)
            let names = Dictionary(sets.map { ($0.groupID, $0.name) }, uniquingKeysWith: { first, _ in first })
            return WantedList.read(game: game, printings: printings, keys: keys, rows: rows, setNames: names)
        }
        var read: WantedRead?
        let first = try await durations(1) { read = try await join(CatalogStore(modelContainer: model.reader.modelContainer)) }
        let again = try await durations(3) { read = try await join(model.reader) }
        let price = WantedList.price(model.prices, game: game.id)
        // Only times: the numbers of the list come from the owner's collection.
        func render(_ wanted: [WantedEntry]) -> Int {
            let content = WantedList.content(wanted, decks: decks, sharing: [:], read: read, joinFailed: false,
                                             catalogHasProducts: true, catalogSettled: true, price: price)
            let shown = WantedList.sorted(WantedList.filtered(content.cards, text: ""), by: .name)
            return WantedList.totals(shown).count + shown.filter(\.pending).count
        }
        var work = 0
        let plain = await durations(3) { work &+= render(wanted) }
        let added = [WantedEntry(cardKey: owned[0], name: owned[0], count: 1)]
        let plus = await durations(3) { work &+= render(added) }
        let printings = read?.printings.values.reduce(0) { $0 + $1.count } ?? 0
        lines.append("Riftbound 2 decks of 60 distinct owned cards (30 in both, \(read?.keys.count ?? 0) keys, \(printings) printings): "
                     + "join \(ms(first.median)) first, \(ms(again.median)) again")
        lines.append("render \(preciseMs(plain.median)); render after one + \(preciseMs(plus.median))\(work == 0 ? " (empty)" : "")")
        return lines
    }

    // MARK: Times

    private struct Durations {
        let sorted: [Duration]
        var median: Duration { sorted[sorted.count / 2] }
    }

    private static func durations(_ runs: Int, _ work: () async throws -> Void) async rethrows -> Durations {
        var times: [Duration] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await work()
            times.append(ContinuousClock.now - start)
        }
        return Durations(sorted: times.sorted())
    }

    private static func ms(_ times: Durations) -> String { ms(times.median) }

    private static func ms(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }

    private static func preciseMs(_ duration: Duration) -> String {
        String(format: "%.2f ms", duration / .milliseconds(1))
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "—" : "\(Int((Double(part) / Double(whole) * 100).rounded())) %"
    }
}
#endif
