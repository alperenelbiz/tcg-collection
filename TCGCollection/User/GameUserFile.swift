import Foundation

nonisolated enum GameUserFileError: Error, Equatable {
    case newerVersion(Int)
    case notAnObject
    case malformedVersion
    case malformedCollection
    /// `wanted`, `forSale`, `sold`, `decks` or `sharing` (the name) is neither an array nor null.
    case malformedList(String)
}

/// The raw JSON of one list: each parsed entry's own object, by the entry's key, and the elements that could not be
/// parsed, in their order.
nonisolated private struct RawList<Key: Hashable> {
    var objects: [Key: [String: Any]] = [:]
    var unparseable: [Any] = []
}

/// A deck card's raw object by its deck and the key (card, section) it was read under: where a printing set or cleared
/// is noted (A18; fix round 2: per line, not per card). A card moved to another section keeps the object it was read
/// with, so the note goes with it.
nonisolated private struct DeckCardRef: Hashable {
    let deckID: String
    let key: DeckCardKey
}

/// The raw JSON of one deck's cards: each parsed card's own object, in the order of the deck's cards as read, and the
/// elements that could not be parsed, in their order.
nonisolated private struct RawCards {
    var objects: [(key: DeckCardKey, object: [String: Any])] = []
    var unparseable: [Any] = []
}

/// The decoded top-level JSON object, kept so that keys this app does not know survive a rewrite.
/// It also keeps each parsed entry's raw object and the array elements that could not be parsed, for every list.
/// Never mutated after creation, so sharing it between threads is safe.
nonisolated private final class JSONObjectBox: @unchecked Sendable {
    let object: [String: Any]
    let collection: RawList<PrintingKey>
    let wanted: RawList<String>
    /// The wanted cards whose object has a pin this build cannot read (one of the two keys, or one of the wrong type):
    /// the entry reads as unpinned, and those keys are written back until the pin is set or cleared.
    let unreadablePins: Set<String>
    let forSale: RawList<PrintingKey>
    /// The sold log is never merged, so two records can be equal: each parsed record keeps its object, in file order.
    let sold: [(record: SoldRecord, object: [String: Any])]
    let soldUnparseable: [Any]
    /// Each parsed deck's object by its id (its `cards` are in `deckCards`), and the decks that could not be parsed.
    let decks: RawList<String>
    let deckCards: [String: RawCards]
    /// Whether a parsed deck card's object has a `productID` this build cannot read (A18): only then are deck changes
    /// watched for printings set or cleared.
    let hasUnreadablePrintings: Bool
    /// Each parsed sharing answer's object by its card key, and the entries that could not be parsed (a second entry of
    /// one card key among them, E1).
    let sharing: RawList<String>
    /// The file's `profile` is there and this build cannot read all of it (not an object, or a member that is not a JSON
    /// boolean, G1): it is written back as it was until the profile is set (`setProfile`).
    let profileIsUnreadable: Bool

    init(_ object: [String: Any], collection: RawList<PrintingKey> = .init(), wanted: RawList<String> = .init(),
         unreadablePins: Set<String> = [], forSale: RawList<PrintingKey> = .init(),
         sold: [(record: SoldRecord, object: [String: Any])] = [], soldUnparseable: [Any] = [],
         decks: RawList<String> = .init(), deckCards: [String: RawCards] = [:], hasUnreadablePrintings: Bool = false,
         sharing: RawList<String> = .init(), profileIsUnreadable: Bool = false) {
        self.object = object
        self.collection = collection
        self.wanted = wanted
        self.unreadablePins = unreadablePins
        self.forSale = forSale
        self.sold = sold
        self.soldUnparseable = soldUnparseable
        self.decks = decks
        self.deckCards = deckCards
        self.hasUnreadablePrintings = hasUnreadablePrintings
        self.sharing = sharing
        self.profileIsUnreadable = profileIsUnreadable
    }
}

/// One game's user file (`<game id>.json`): `version`, `collection`, `wanted`, `forSale`, `sold`, `decks`, `sharing`,
/// `profile`, and whatever else a newer app wrote. The version stays 1 (C1, D1, E1, G1): a phase 2B build keeps the three
/// lists, a phase 2B or 2C build keeps `decks`, a phase 2B–3A build keeps `sharing`, and a phase 2B–4A build keeps
/// `profile`, as unknown keys.
/// - A list key the file has (even `[]` or null) is written back; one it does not have is written only once its list
///   has an entry, so a phase 2B file keeps its bytes through a read and a rewrite.
/// - Each entry keeps the keys this app does not know; entries that cannot be parsed are kept, in their order, after
///   the parsed ones. Wanted and for-sale entries of one key are merged on read, as collection rows are; sold records
///   never are, and a sold record with any key of its own this build cannot read is kept whole, unparsed (never edited).
/// - A wanted entry's pin this build cannot read reads as no pin and is written back until the pin is set or cleared
///   (`setPin`, also with `nil` on that entry). A `null` pin key is no pin key.
/// - A for-sale count over the owned count is read as it is (Review Focus 2); `UserLibrary` clamps it at the next change.
/// - A deck is a nested entry: the deck keeps its own unknown keys, and each of its cards keeps its own. A deck that cannot
///   be parsed (no `id`, a second deck of one id, `cards` or another key of its own of the wrong type) is kept whole, as
///   written, after the parsed decks. A deck card that cannot be parsed is kept inside its deck, after the parsed cards.
///   Cards of one (card, section) are merged on read; a card under count 1 is dropped. A card moved to another section
///   keeps the unknown keys of the card it was.
/// - A sharing answer (E1) needs a string `cardKey` and a boolean `shared`. The first entry of a card key wins; a later
///   one is kept as written, with the entries that cannot be parsed, and goes when the card's parsed answer is removed
///   (the rule of a second deck of one id), so a removed answer cannot come back at the next read; it stays gone when the
///   card is answered again in the same run. Only a second entry with a boolean `shared` goes (final fix A4).
/// - The profile (G1) is an object: a missing key or member is `true`. The key is written back as the file had it until
///   the profile changes; then it is written over the object read (its unknown keys kept), also when it is all on again.
///   A `profile` that is not an object, or a member that is not a JSON boolean, reads as `true` and is written back as it
///   was until the profile is set (`setProfile`, also to the same value: the half pin's rule).
nonisolated struct GameUserFile: Sendable, Equatable {
    static let currentVersion = 1

    var collection: [CollectionRow]
    var wanted: [WantedEntry] {
        didSet { notePinChanges(from: oldValue) }
    }
    var forSale: [SaleEntry]
    var sold: [SoldRecord]
    /// In the user's deck order.
    var decks: [Deck] {
        didSet { notePrintingChanges(from: oldValue) }
    }
    /// The user's sharing answers (E1), one per card key, in file order.
    var sharing: [SharingEntry] {
        didSet { noteSharingRemovals() }
    }
    /// Whether the user follows the game and his roles in it (G1).
    var profile: GameProfile {
        didSet { if profile != oldValue { profileChanged = true } }
    }
    private let raw: JSONObjectBox
    /// The cards of `raw.unreadablePins` whose pin was set or cleared since the read: their old pin keys are not written.
    private var pinsChanged: Set<String> = []
    /// The deck cards (deck id, card key) whose printing was set or cleared since the read: a `productID` this build
    /// could not read is not written back for them (A18).
    private var printingsChanged: Set<DeckCardRef> = []
    /// The cards whose answer read from the file was removed since the read (final fix A4): their raw duplicates are not
    /// written back, also when the card is answered again later in the run.
    private var sharingRemoved: Set<String> = []
    /// The profile was changed (or set over an unreadable one) since the read: it is written from `profile`, not as read.
    private var profileChanged = false

    init() {
        collection = []
        wanted = []
        forSale = []
        sold = []
        decks = []
        sharing = []
        profile = .all
        raw = JSONObjectBox([:])
    }

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameUserFileError.notAnObject
        }
        if let value = object["version"] {
            guard let version = Self.integer(value), version >= 1 else { throw GameUserFileError.malformedVersion }
            if version > Self.currentVersion { throw GameUserFileError.newerVersion(version) }
        }
        let rows = Self.split(try Self.array(object, "collection", else: .malformedCollection), Self.row)
        let wanted = Self.split(try Self.array(object, "wanted", else: .malformedList("wanted")), Self.wantedEntry)
        let forSale = Self.split(try Self.array(object, "forSale", else: .malformedList("forSale")), Self.saleEntry)
        let sold = Self.split(try Self.array(object, "sold", else: .malformedList("sold")), Self.soldRecord)
        let deckElements = try Self.array(object, "decks", else: .malformedList("decks"))
        let sharingElements = try Self.array(object, "sharing", else: .malformedList("sharing"))

        let (cleanRows, rowObjects) = Self.merged(rows.parsed, key: \.key, count: \.count) { first, later in
            first.count += later.count
            if first.condition.isEmpty { first.condition = later.condition }
            if first.name.isEmpty { first.name = later.name }
        }
        // The first entry's pin stays.
        let (cleanWanted, wantedObjects) = Self.merged(wanted.parsed, key: \.cardKey, count: \.count) { first, later in
            first.count += later.count
            if first.name.isEmpty { first.name = later.name }
        }
        let (cleanForSale, saleObjects) = Self.merged(forSale.parsed, key: \.key, count: \.count) { first, later in
            first.count += later.count
            if first.name.isEmpty { first.name = later.name }
        }
        collection = cleanRows
        self.wanted = cleanWanted
        self.forSale = cleanForSale
        self.sold = sold.parsed.map { $0.0 }
        // A second deck of one id is not parsed, so an id addresses exactly one deck.
        var decks: [Deck] = [], deckObjects: [String: [String: Any]] = [:], deckCards: [String: RawCards] = [:]
        var unparseableDecks: [Any] = []
        for element in deckElements {
            guard let deckObject = element as? [String: Any], let parsed = Self.deck(deckObject),
                  deckObjects[parsed.deck.id] == nil else {
                unparseableDecks.append(element)
                continue
            }
            decks.append(parsed.deck)
            deckObjects[parsed.deck.id] = deckObject
            deckCards[parsed.deck.id] = parsed.cards
        }
        self.decks = decks
        // A second entry of one card key is not parsed, as a second deck of one id is not.
        var sharing: [SharingEntry] = [], sharingObjects: [String: [String: Any]] = [:], unparseableSharing: [Any] = []
        for element in sharingElements {
            guard let entryObject = element as? [String: Any], let entry = Self.sharingEntry(entryObject),
                  sharingObjects[entry.cardKey] == nil else {
                unparseableSharing.append(element)
                continue
            }
            sharing.append(entry)
            sharingObjects[entry.cardKey] = entryObject
        }
        self.sharing = sharing
        let (profile, profileIsUnreadable) = Self.profile(object["profile"])
        self.profile = profile
        let unreadablePins = Set(cleanWanted.compactMap { entry -> String? in
            let object = wantedObjects[entry.cardKey] ?? [:]
            // A `null` pin key is no pin key (B3): such an entry has no pin, and its next write leaves no pin key.
            let hasPinKey = ["pinProductID", "pinFinish"].contains { key in object[key].map { !($0 is NSNull) } ?? false }
            return hasPinKey && entry.pin == nil ? entry.cardKey : nil
        })
        raw = JSONObjectBox(object,
                            collection: RawList(objects: rowObjects, unparseable: rows.unparseable),
                            wanted: RawList(objects: wantedObjects, unparseable: wanted.unparseable),
                            unreadablePins: unreadablePins,
                            forSale: RawList(objects: saleObjects, unparseable: forSale.unparseable),
                            sold: sold.parsed.map { (record: $0.0, object: $0.1) },
                            soldUnparseable: sold.unparseable,
                            decks: RawList(objects: deckObjects, unparseable: unparseableDecks),
                            deckCards: deckCards,
                            hasUnreadablePrintings: deckCards.values.contains { $0.objects.contains { Self.hasUnreadablePrinting($0.object) } },
                            sharing: RawList(objects: sharingObjects, unparseable: unparseableSharing),
                            profileIsUnreadable: profileIsUnreadable)
    }

    /// UTF-8, pretty-printed, sorted keys, ending with a newline.
    func data() throws -> Data {
        let encoder = JSONEncoder()
        var object = raw.object
        object["version"] = Self.currentVersion
        // Every key of a collection row is always written.
        object["collection"] = try Self.objects(collection.map { ($0, raw.collection.objects[$0.key]) }, owned: [], encoder: encoder)
            + raw.collection.unparseable
        // Each sold record takes the first unused object read for an equal record, so equal records keep their own keys.
        var unusedSold = raw.sold
        let soldPairs = sold.map { record -> (SoldRecord, [String: Any]?) in
            guard let i = unusedSold.firstIndex(where: { $0.record == record }) else { return (record, nil) }
            return (record, unusedSold.remove(at: i).object)
        }
        let lists: [(String, [Any])] = [
            ("wanted", try wanted.map { entry in
                // An unreadable pin nobody set or cleared is not this entry's to drop.
                let keepsPin = raw.unreadablePins.contains(entry.cardKey) && !pinsChanged.contains(entry.cardKey)
                let owned = keepsPin ? WantedEntry.storedKeys.subtracting(["pinProductID", "pinFinish"]) : WantedEntry.storedKeys
                return try Self.objects([(entry, raw.wanted.objects[entry.cardKey])], owned: owned, encoder: encoder)[0]
            } + raw.wanted.unparseable),
            ("forSale", try Self.objects(forSale.map { ($0, raw.forSale.objects[$0.key]) }, owned: SaleEntry.storedKeys,
                                         encoder: encoder) + raw.forSale.unparseable),
            ("sold", try Self.objects(soldPairs, owned: SoldRecord.storedKeys, encoder: encoder) + raw.soldUnparseable),
            ("decks", try decks.map { try deckObject($0, encoder: encoder) } + unparseableDecksKept),
            ("sharing", try Self.objects(sharing.map { ($0, raw.sharing.objects[$0.cardKey]) }, owned: SharingEntry.storedKeys,
                                         encoder: encoder) + unparseableSharingKept),
        ]
        // A key the file did not have stays out while its list is empty.
        for (key, elements) in lists where !elements.isEmpty || raw.object[key] != nil {
            object[key] = elements
        }
        // G1: an unchanged profile stays as the file has it (no key, or the value as read, also one this build cannot
        // read); a changed one is written over the object read, so its unknown keys stay.
        if profileChanged {
            var written = (raw.object["profile"] as? [String: Any] ?? [:]).filter { !GameProfile.storedKeys.contains($0.key) }
            written["followed"] = profile.followed
            written["player"] = profile.player
            written["collector"] = profile.collector
            object["profile"] = written
        }
        var out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        return out
    }

    /// The decks read that could not be parsed, minus each second deck of an id whose parsed deck was deleted since the
    /// read: the duplicate goes with its deck, so a deleted deck cannot come back at the next read (final fix B9).
    private var unparseableDecksKept: [Any] {
        let deleted = Set(raw.decks.objects.keys).subtracting(decks.map(\.id))
        guard !deleted.isEmpty else { return raw.decks.unparseable }
        return raw.decks.unparseable.filter { element in
            guard let id = (element as? [String: Any])?["id"] as? String else { return true }
            return !deleted.contains(id)
        }
    }

    /// The sharing entries read that could not be parsed, minus each second answer of a card whose parsed answer was
    /// removed since the read (`sharingRemoved`, also when the card was answered again since): it goes with that answer, so
    /// the removed answer cannot come back at the next read (the rule of `unparseableDecksKept`). Only a true second answer
    /// goes (its `shared` a JSON boolean, final fix A4); an entry of that card with an unreadable answer or without one is
    /// kept.
    private var unparseableSharingKept: [Any] {
        guard !sharingRemoved.isEmpty else { return raw.sharing.unparseable }
        return raw.sharing.unparseable.filter { element in
            guard let object = element as? [String: Any], let key = object["cardKey"] as? String,
                  object["shared"].flatMap(Self.boolean) != nil else { return true }
            return !sharingRemoved.contains(key)
        }
    }

    /// Notes the cards whose answer read from the file is no longer in `sharing` (final fix A4).
    private mutating func noteSharingRemovals() {
        guard !raw.sharing.objects.isEmpty else { return }
        let current = Set(sharing.map(\.cardKey))
        sharingRemoved.formUnion(raw.sharing.objects.keys.filter { !current.contains($0) })
    }

    /// How many cards of the deck `id` this build could not read (kept raw inside the deck, written back as read); 0 for a
    /// deck without any, a deck added since the read, or no such deck. For the deck page's line (final fix B8).
    func unreadableCards(deck id: String) -> Int {
        decks.contains { $0.id == id } ? raw.deckCards[id]?.unparseable.count ?? 0 : 0
    }

    /// Pins a wanted card to one printing, or takes its pin away (`nil`; `ListRules.pinning`). A pin this build cannot
    /// read counts as set or cleared too: its keys are not written any more, so "Any printing" leaves no pin key (B3). A
    /// card not on the list changes nothing.
    mutating func setPin(_ pin: PrintingKey?, cardKey: String) {
        wanted = ListRules.pinning(wanted, cardKey: cardKey, to: pin)
        if raw.unreadablePins.contains(cardKey), wanted.contains(where: { $0.cardKey == cardKey }) {
            pinsChanged.insert(cardKey)
        }
    }

    /// Sets or clears one deck card's printing (A18, `DeckRules.settingPrinting`). A `productID` this build could not read
    /// counts as set or cleared too: it is not written any more, so "Any printing" leaves no key (fix round 1, the rule of
    /// `setPin`). A deck or a card that is gone changes nothing.
    mutating func setPrinting(_ productID: Int?, deck id: String, key: DeckCardKey) {
        guard let i = decks.firstIndex(where: { $0.id == id }), decks[i].cards.contains(where: { $0.key == key }) else { return }
        decks[i] = DeckRules.settingPrinting(decks[i], key: key, productID: productID)
        let deck = decks[i]
        guard let j = deck.cards.firstIndex(where: { $0.key == key }), let source = rawCardObjects(deck)[j],
              Self.hasUnreadablePrinting(source.object) else { return }
        printingsChanged.insert(DeckCardRef(deckID: id, key: source.key))
    }

    /// Sets the profile (G1). A `profile` this build could not read counts as changed too, also when `profile` is the same
    /// value: it is written from `profile` from now on (the rule of `setPin`).
    mutating func setProfile(_ profile: GameProfile) {
        self.profile = profile
        if raw.profileIsUnreadable { profileChanged = true }
    }

    /// The lists, the decks, the sharing answers and the profile are equal (what the app reads and changes); keys it does
    /// not know are not compared.
    func hasSameLists(as other: GameUserFile) -> Bool {
        collection == other.collection && wanted == other.wanted && forSale == other.forSale && sold == other.sold
            && decks == other.decks && sharing == other.sharing && profile == other.profile
    }

    /// Equal lists, and equal keys this app does not know. A copy of one read file differs only by its lists (and by the
    /// unreadable pins set or cleared since).
    static func == (lhs: GameUserFile, rhs: GameUserFile) -> Bool {
        lhs.hasSameLists(as: rhs)
            && ((lhs.raw === rhs.raw && lhs.pinsChanged == rhs.pinsChanged && lhs.printingsChanged == rhs.printingsChanged
                 && lhs.sharingRemoved == rhs.sharingRemoved && lhs.profileChanged == rhs.profileChanged)
                || (try? lhs.data()) == (try? rhs.data()))
    }

    /// Notes the cards with an unreadable pin whose pin fields changed (set or cleared) in this change of `wanted`.
    private mutating func notePinChanges(from old: [WantedEntry]) {
        guard !raw.unreadablePins.isEmpty else { return }
        for entry in wanted where raw.unreadablePins.contains(entry.cardKey) && !pinsChanged.contains(entry.cardKey) {
            guard let before = old.first(where: { $0.cardKey == entry.cardKey }) else { continue }
            if before.pinProductID != entry.pinProductID || before.pinFinish != entry.pinFinish {
                pinsChanged.insert(entry.cardKey)
            }
        }
    }

    /// Notes the deck cards whose printing changed (set or cleared) in this change of `decks`, when the file read had a
    /// printing this build cannot read (A18). A card is matched with its old self by its deck and key (card, section); the
    /// note names the raw object the card is written over (`rawCardObjects`).
    private mutating func notePrintingChanges(from old: [Deck]) {
        guard raw.hasUnreadablePrintings else { return }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for deck in decks {
            guard let was = before[deck.id] else { continue }
            let sources = rawCardObjects(deck)
            for (card, source) in zip(deck.cards, sources) {
                guard let source, let previous = was.cards.first(where: { $0.key == card.key }),
                      previous.productID != card.productID else { continue }
                printingsChanged.insert(DeckCardRef(deckID: deck.id, key: source.key))
            }
        }
    }

    /// For each card of `deck`, in order, the raw object it is written over and the key it was read under: its own key's
    /// object, else the object of a card of the same card key that is no longer in the deck (a move, a format change),
    /// else none.
    private func rawCardObjects(_ deck: Deck) -> [(key: DeckCardKey, object: [String: Any])?] {
        let rawCards = raw.deckCards[deck.id] ?? RawCards()
        var byKey: [DeckCardKey: [String: Any]] = [:]
        for card in rawCards.objects { byKey[card.key] = card.object }
        let current = Set(deck.cards.map(\.key))
        var spare = rawCards.objects.filter { !current.contains($0.key) }
        return deck.cards.map { card in
            if let own = byKey[card.key] { return (key: card.key, object: own) }
            guard let i = spare.firstIndex(where: { $0.key.cardKey == card.cardKey }) else { return nil }
            let found = spare.remove(at: i)
            return (key: found.key, object: found.object)
        }
    }

    // MARK: Writing

    /// A deck as a JSON object: the object it was read from with the deck's own keys written over it, and its cards, each
    /// over the object it was read from, then the cards that could not be parsed. A card with no object of its own key (it
    /// was moved to another section, or a format change moved it) takes the object of a card of the same card key that
    /// is no longer in the deck, so its unknown keys go with it.
    private func deckObject(_ deck: Deck, encoder: JSONEncoder) throws -> Any {
        guard var object = try Self.objects([(deck, raw.decks.objects[deck.id])], owned: Deck.storedKeys,
                                            encoder: encoder)[0] as? [String: Any] else { return [:] }
        let rawCards = raw.deckCards[deck.id] ?? RawCards()
        // A18: a `productID` this build could not read stays while the card has no printing and nobody set or cleared the
        // printing of the line its object was read under.
        object["cards"] = try zip(deck.cards, rawCardObjects(deck)).map { card, source in
            let keeps = card.productID == nil && Self.hasUnreadablePrinting(source?.object)
                && !(source.map { printingsChanged.contains(DeckCardRef(deckID: deck.id, key: $0.key)) } ?? true)
            let owned = keeps ? DeckCard.storedKeys.subtracting(["productID"]) : DeckCard.storedKeys
            return try Self.objects([(card, source?.object)], owned: owned, encoder: encoder)[0]
        } + rawCards.unparseable
        return object
    }

    /// Each entry as a JSON object: the object it was read from (the keys this app does not know) with the entry's own
    /// keys written over it. The keys the entry owns are taken out first, so a nil pin or price leaves no key behind.
    private static func objects<Entry: Encodable>(_ entries: [(Entry, [String: Any]?)], owned: Set<String>,
                                                   encoder: JSONEncoder) throws -> [Any] {
        try entries.map { entry, object in
            var merged = (object ?? [:]).filter { !owned.contains($0.key) }
            let known = try JSONSerialization.jsonObject(with: encoder.encode(entry)) as? [String: Any] ?? [:]
            merged.merge(known.mapValues(shortest)) { _, new in new }
            return merged
        }
    }

    /// A fraction as Swift prints it (`0.07`). JSONSerialization would write 17 digits (`0.070000000000000007`), which
    /// does not read back as the same Double.
    private static func shortest(_ value: Any) -> Any {
        guard let number = value as? NSNumber, CFNumberIsFloatType(number) else { return value }
        let decimal = NSDecimalNumber(string: "\(number.doubleValue)", locale: Locale(identifier: "en_US_POSIX"))
        return decimal == .notANumber ? value : decimal
    }

    // MARK: Reading

    /// The array under `key`: none or null is empty; anything else that is not an array refuses the file.
    private static func array(_ object: [String: Any], _ key: String, else error: GameUserFileError) throws -> [Any] {
        guard let value = object[key], !(value is NSNull) else { return [] }
        guard let array = value as? [Any] else { throw error }
        return array
    }

    /// The elements `parse` reads, each with its object, and the others, in their order.
    private static func split<Entry>(_ elements: [Any], _ parse: ([String: Any]) -> Entry?)
        -> (parsed: [(Entry, [String: Any])], unparseable: [Any]) {
        var parsed: [(Entry, [String: Any])] = []
        var unparseable: [Any] = []
        for element in elements {
            if let object = element as? [String: Any], let entry = parse(object) {
                parsed.append((entry, object))
            } else {
                unparseable.append(element)
            }
        }
        return (parsed, unparseable)
    }

    /// Drops entries with count < 1; merges entries of one key into the first (its position and raw object win).
    private static func merged<Entry, Key: Hashable>(_ entries: [(Entry, [String: Any])], key: (Entry) -> Key,
                                                     count: (Entry) -> Int, into merge: (inout Entry, Entry) -> Void)
        -> ([Entry], [Key: [String: Any]]) {
        var result: [Entry] = []
        var objects: [Key: [String: Any]] = [:]
        var index: [Key: Int] = [:]
        for (entry, object) in entries where count(entry) >= 1 {
            let k = key(entry)
            if let i = index[k] {
                merge(&result[i], entry)
            } else {
                index[k] = result.count
                objects[k] = object
                result.append(entry)
            }
        }
        return (result, objects)
    }

    /// A whole JSON number; not a boolean, not a fraction.
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d == d.rounded(), abs(d) < 9e15 else { return nil }
        return number.intValue
    }

    /// A JSON `true` or `false`; not a number.
    private static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A JSON number; not a boolean. JSONSerialization reads a number of many digits (`0.070000000000000007`, as a phase 2B
    /// build rewrites `0.07`) as an NSDecimalNumber, whose `doubleValue` is off (`0.07000000000000003`): its text is read
    /// as a Double instead, which gives the number that was written.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if let decimal = number as? NSDecimalNumber, let exact = Double(decimal.stringValue) { return exact }
        return number.doubleValue
    }

    /// Trimmed; empty is `Normal`.
    private static func finish(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Normal" : trimmed
    }

    private static func row(_ o: [String: Any]) -> CollectionRow? {
        guard let productID = o["productID"].flatMap(integer),
              let rawFinish = o["finish"] as? String,
              let count = o["count"].flatMap(integer) else { return nil }
        return CollectionRow(productID: productID, finish: finish(rawFinish), count: count,
                             condition: o["condition"] as? String ?? "", name: o["name"] as? String ?? "")
    }

    /// Needs `cardKey` and `count`; a pin needs both its fields.
    private static func wantedEntry(_ o: [String: Any]) -> WantedEntry? {
        guard let cardKey = o["cardKey"] as? String, let count = o["count"].flatMap(integer) else { return nil }
        let pinProductID = o["pinProductID"].flatMap(integer), pinFinish = o["pinFinish"] as? String
        let pinned = pinProductID != nil && pinFinish != nil
        return WantedEntry(cardKey: cardKey, name: o["name"] as? String ?? "", count: count,
                           pinProductID: pinned ? pinProductID : nil, pinFinish: pinned ? pinFinish.map(finish) : nil)
    }

    private static func saleEntry(_ o: [String: Any]) -> SaleEntry? {
        guard let productID = o["productID"].flatMap(integer),
              let rawFinish = o["finish"] as? String,
              let count = o["count"].flatMap(integer) else { return nil }
        return SaleEntry(productID: productID, finish: finish(rawFinish), count: count, name: o["name"] as? String ?? "")
    }

    /// A deck needs a string `id`. A missing, null or blank `name` reads as "Deck", a missing `format` as "" (the views
    /// take the game's first format), a missing `active` as false, missing `cards` as none; any of them of another type
    /// makes the deck unparseable. Its cards that cannot be parsed are kept apart; cards of one (card, section) are summed
    /// into the first (an empty name is filled; a missing printing is taken from the first later card that has one), cards
    /// under count 1 are dropped.
    private static func deck(_ o: [String: Any]) -> (deck: Deck, cards: RawCards)? {
        guard let id = o["id"] as? String,
              let name = optional(o["name"], else: "", as: String.self),
              let format = optional(o["format"], else: "", as: String.self),
              let active = optional(o["active"], else: false, as: Bool.self, read: boolean),
              let elements = optional(o["cards"], else: [], as: [Any].self) else { return nil }
        let cards = split(elements, deckCard)
        // A18: the first card's printing; when it has none, the first later one's.
        let (clean, objects) = merged(cards.parsed, key: \.key, count: \.count) { first, later in
            first.count += later.count
            if first.name.isEmpty { first.name = later.name }
            if first.productID == nil { first.productID = later.productID }
        }
        let blank = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let deck = Deck(id: id, name: blank ? "Deck" : name, format: format, active: active, cards: clean)
        let raw = RawCards(objects: clean.map { (key: $0.key, object: objects[$0.key] ?? [:]) },
                           unparseable: cards.unparseable)
        return (deck, raw)
    }

    /// Needs a string `cardKey` and `section` and a whole `count`; a `name` that is there must be a string; a `productID`
    /// (A18, the chosen printing) is read when it is a whole number.
    private static func deckCard(_ o: [String: Any]) -> DeckCard? {
        guard let cardKey = o["cardKey"] as? String,
              let section = o["section"] as? String,
              let count = o["count"].flatMap(integer),
              let name = optional(o["name"], else: "", as: String.self) else { return nil }
        // A18: a `productID` that is not a whole number reads as none (`deckObject` writes it back until it is set or
        // cleared); a `null` is no key.
        return DeckCard(cardKey: cardKey, name: name, section: section, count: count,
                        productID: o["productID"].flatMap(integer))
    }

    /// E1: needs a string `cardKey` and a JSON boolean `shared` (a number or a string is no answer).
    private static func sharingEntry(_ o: [String: Any]) -> SharingEntry? {
        guard let cardKey = o["cardKey"] as? String, let shared = o["shared"].flatMap(boolean) else { return nil }
        return SharingEntry(cardKey: cardKey, shared: shared)
    }

    /// G1: the profile read from the file's `profile` value, and whether the value is there and not all readable. None or
    /// null is all on; a value that is not an object is all on and unreadable; a member that is missing or null is on, one
    /// that is not a JSON boolean is on and makes the value unreadable.
    private static func profile(_ value: Any?) -> (GameProfile, unreadable: Bool) {
        guard let value, !(value is NSNull) else { return (.all, false) }
        guard let object = value as? [String: Any] else { return (.all, true) }
        var unreadable = false
        func member(_ key: String) -> Bool {
            guard let raw = object[key], !(raw is NSNull) else { return true }
            guard let read = boolean(raw) else {
                unreadable = true
                return true
            }
            return read
        }
        let profile = GameProfile(followed: member("followed"), player: member("player"), collector: member("collector"))
        return (profile, unreadable)
    }

    /// A deck card's `productID` this build cannot read: there, not `null`, not a whole number (A18).
    private static func hasUnreadablePrinting(_ object: [String: Any]?) -> Bool {
        guard let value = object?["productID"], !(value is NSNull) else { return false }
        return integer(value) == nil
    }

    /// `fallback` for a missing or null value, the value read as `T`, or nil (unreadable).
    private static func optional<T>(_ value: Any?, else fallback: T, as type: T.Type,
                                    read: (Any) -> T? = { $0 as? T }) -> T? {
        guard let value, !(value is NSNull) else { return fallback }
        return read(value)
    }

    /// Read as written: a record is never edited, not even its finish. Every key of its own must be there and readable
    /// (`price` may be absent); otherwise the record is not parsed and is kept whole, as written.
    private static func soldRecord(_ o: [String: Any]) -> SoldRecord? {
        guard let productID = o["productID"].flatMap(integer),
              let finish = o["finish"] as? String,
              let count = o["count"].flatMap(integer),
              let name = o["name"] as? String,
              let day = o["day"] as? String,
              let priceIsLow = o["priceIsLow"].flatMap(boolean) else { return nil }
        var price: Double?
        if let value = o["price"] {
            guard let number = number(value) else { return nil }
            price = number
        }
        return SoldRecord(productID: productID, finish: finish, count: count, name: name, day: day, price: price,
                          priceIsLow: priceIsLow)
    }
}
