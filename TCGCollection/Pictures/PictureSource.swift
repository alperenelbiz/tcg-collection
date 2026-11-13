import Foundation

/// Decides the picture address of one printing: one address, the full size, for a gallery cell, a card page and the PDF
/// alike (feedback 1). Each address is downloaded once (`PictureStore`); the cell and the page decode it to their own size.
nonisolated enum PictureSource {
    static func url(for product: ProductRecord, game: GameDefinition, ygo: YGOPictureIndex?) -> URL? {
        switch game.pictures {
        case .tcgplayer:
            return URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\(product.productID)_in_1000x1000.jpg")
        case .ygoprodeck:
            guard let id = ygo?.pictureID(number: product.number, name: product.cardName) else { return nil }
            return URL(string: "https://images.ygoprodeck.com/images/cards/\(id).jpg")
        }
    }
}
