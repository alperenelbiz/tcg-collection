import Foundation

/// Maps a Yu-Gi-Oh! set code or card name to a YGOPRODeck picture id, and a card name to its type. Small enough to keep on disk.
nonisolated struct YGOPictureIndex: Codable, Sendable, Equatable {
    /// 1 = pictures only (files of phases 1 to 2C have no `version`: they read as 0); 2 = adds `types` (phase 3A, D14).
    /// A file under this version is fetched once more, under the once-a-day rule (`AppModel.needsYGOIndex`).
    static let currentVersion = 2

    var version: Int
    var codes: [String: Int]
    var names: [String: Int]
    /// The card's name key (`CardName.searchKey`, the key of `names`) -> YGOPRODeck's `frameType`, as written
    /// (`effect`, `fusion`, `xyz_pendulum`, `spell`, `trap`, `link`, `token`, `skill`, ...). Not mapped here.
    var types: [String: String]

    var isCurrent: Bool { version >= Self.currentVersion }

    private struct Body: Decodable {
        let data: [Card]
    }
    private struct Card: Decodable {
        struct CardSet: Decodable { let set_code: String }
        struct CardImage: Decodable { let id: Int }
        let name: String
        let card_sets: [CardSet]?
        let card_images: [CardImage]?
        let frameType: String?
    }

    /// On disk the types are grouped by `frameType` (`{"effect": [key, ...]}`): the word is written once, not per card.
    private enum CodingKeys: String, CodingKey { case version, codes, names, typeGroups }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        codes = try c.decode([String: Int].self, forKey: .codes)
        names = try c.decode([String: Int].self, forKey: .names)
        types = [:]
        for (type, keys) in try c.decodeIfPresent([String: [String]].self, forKey: .typeGroups) ?? [:] {
            for key in keys { types[key] = type }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(codes, forKey: .codes)
        try c.encode(names, forKey: .names)
        var groups: [String: [String]] = [:]
        for (key, type) in types { groups[type, default: []].append(key) }
        try c.encode(groups.mapValues { $0.sorted() }, forKey: .typeGroups)
    }

    /// Reads the body of `cardinfo.php`. Unknown keys are ignored; `card_sets` may be missing.
    init(cardinfo: Data) throws {
        version = Self.currentVersion
        codes = [:]
        names = [:]
        types = [:]
        for card in try JSONDecoder().decode(Body.self, from: cardinfo).data {
            guard let id = card.card_images?.first?.id else { continue }
            for set in card.card_sets ?? [] where codes[set.set_code] == nil {
                codes[set.set_code] = id
            }
            let key = CardName.searchKey(card.name)
            if names[key] == nil { names[key] = id }
            if let frameType = card.frameType, types[key] == nil { types[key] = frameType }
        }
    }

    /// The card's YGOPRODeck type by its name, nil when the index has none (an old index file, a name it lacks).
    /// A name with a kept bracket such as `Foo (Skill Card)` has another key than the card's own name: nil, and the
    /// caller falls back to the TCGplayer type (A15).
    func type(name: String) -> String? {
        types[CardName.searchKey(name)]
    }

    /// The set code first, then the card name.
    func pictureID(number: String, name: String) -> Int? {
        codes[number] ?? names[CardName.searchKey(name)]
    }
}
