import Foundation

nonisolated enum PictureSize: Sendable { case small, large }

/// Decides the picture address of one printing.
nonisolated enum PictureSource {
    static func url(for product: ProductRecord, game: GameDefinition, size: PictureSize, ygo: YGOPictureIndex?) -> URL? {
        switch game.pictures {
        case .tcgplayer:
            let file = size == .small ? "\(product.productID)_200w.jpg" : "\(product.productID)_in_1000x1000.jpg"
            return URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\(file)")
        case .ygoprodeck:
            guard let id = ygo?.pictureID(number: product.number, name: product.cardName) else { return nil }
            let folder = size == .small ? "cards_small" : "cards"
            return URL(string: "https://images.ygoprodeck.com/images/\(folder)/\(id).jpg")
        }
    }
}
