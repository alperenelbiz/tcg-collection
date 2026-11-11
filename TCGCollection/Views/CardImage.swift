import ImageIO
import SwiftUI

/// The picture of one printing. Downloaded once by `PictureStore`, decoded off the main actor, kept in memory.
/// With no picture: a flat card with the card name.
struct CardImage: View {
    let product: ProductRecord?
    let size: PictureSize

    @Environment(AppModel.self) private var model
    @State private var picture: CGImage?
    @State private var missing = false

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let cache = NSCache<NSString, Entry>()

    var body: some View {
        Color(white: 0.16)
            .aspectRatio(59.0 / 86.0, contentMode: .fit)
            .overlay {
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().scaledToFill()
                } else if missing, let product {
                    Text(product.cardName)
                        .font(size == .small ? .caption : .title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size == .small ? 6 : 12))
            .task(id: url) { await load() }
    }

    private var url: URL? {
        guard let product, let game = Games.game(product.gameID) else { return nil }
        return PictureSource.url(for: product, game: game, size: size, ygo: model.ygoIndex)
    }

    private func load() async {
        picture = nil
        missing = false
        guard let url else {
            missing = true
            return
        }
        let pixels = size == .small ? 480 : 1200
        let key = "\(url.absoluteString)@\(pixels)" as NSString
        if let hit = Self.cache.object(forKey: key) {
            picture = hit.image
            return
        }
        guard let data = await model.pictures.data(for: url),
              let decoded = await Self.decode(data, maxPixels: pixels) else {
            if !Task.isCancelled { missing = true }
            return
        }
        Self.cache.setObject(Entry(decoded.image), forKey: key)
        if !Task.isCancelled { picture = decoded.image }
    }

    /// Off the main actor and off the `PictureStore` actor.
    @concurrent private nonisolated static func decode(_ data: Data, maxPixels: Int) async -> DecodedPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(DecodedPicture.init)
    }
}

/// A `CGImage` does not change once made; the box carries it from the decoding task to the view.
private nonisolated struct DecodedPicture: @unchecked Sendable {
    let image: CGImage
}
