import Foundation

/// Maps a Yu-Gi-Oh! set code or card name to a YGOPRODeck picture id. Small enough to keep on disk.
nonisolated struct YGOPictureIndex: Codable, Sendable, Equatable {
    var codes: [String: Int]
    var names: [String: Int]

    private struct Body: Decodable {
        let data: [Card]
    }
    private struct Card: Decodable {
        struct CardSet: Decodable { let set_code: String }
        struct CardImage: Decodable { let id: Int }
        let name: String
        let card_sets: [CardSet]?
        let card_images: [CardImage]?
    }

    /// Reads the body of `cardinfo.php`. Unknown keys are ignored; `card_sets` may be missing.
    init(cardinfo: Data) throws {
        codes = [:]
        names = [:]
        for card in try JSONDecoder().decode(Body.self, from: cardinfo).data {
            guard let id = card.card_images?.first?.id else { continue }
            for set in card.card_sets ?? [] where codes[set.set_code] == nil {
                codes[set.set_code] = id
            }
            let key = CardName.searchKey(card.name)
            if names[key] == nil { names[key] = id }
        }
    }

    /// The set code first, then the card name.
    func pictureID(number: String, name: String) -> Int? {
        codes[number] ?? names[CardName.searchKey(name)]
    }
}
