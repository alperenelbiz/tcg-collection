import ImageIO
import SwiftUI

/// How large a picture is decoded: the source is always the full size (`PictureSource`), and the decode caps its long
/// side, so a cell's memory does not grow with the source.
nonisolated enum PictureSize: Sendable {
    case cell, page
    /// A list row's small picture (the deck page's list, A57): 32 pt tall on the Mac, 40 pt on the iPhone.
    case row

    /// The long side of the decoded picture. A cell: 960 px, enough for the widest gallery cell (316 pt, a picture 461 pt
    /// tall, 922 px at 2×; `CardImageTests`). A page: 1200 px (280 pt wide, 817 px at 2×).
    var maxPixels: Int {
        switch self {
        case .cell: 960
        case .page: 1200
        // 40 pt at 3×.
        case .row: 128
        }
    }

    /// The picture's proportion: the gallery's and the page's 59 : 86; a row's the card's 63 : 88 (the look of A57).
    var aspectRatio: CGFloat {
        self == .row ? 63.0 / 88.0 : 59.0 / 86.0
    }

    var cornerRadius: CGFloat {
        switch self {
        case .cell: Theme.pictureRadius
        case .page: Theme.largePictureRadius
        case .row: Theme.deckRowPictureRadius
        }
    }
}

/// The picture of one printing. Downloaded once by `PictureStore`, decoded off the main actor, kept in memory.
/// While it loads: a flat `surface` block of the final size, no shimmer. With no picture: that block with the card name.
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
    /// Decoded pictures kept in memory, by picture address and size. An NSCache without a cost limit only gives way under
    /// memory pressure, which macOS signals late: a gallery scrolled end to end held gigabytes (a cell's picture is about
    /// 2.6 MB decoded). Over the limit the cache drops entries; a dropped picture is decoded again from its file on disk.
    static let memoryLimit = 300 * 1024 * 1024
    nonisolated static func cost(of image: CGImage) -> Int { image.bytesPerRow * image.height }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = memoryLimit
        return cache
    }()

    var body: some View {
        Theme.surface
            .aspectRatio(size.aspectRatio, contentMode: .fit)
            .overlay {
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().scaledToFill()
                } else if missing, size != .row, let product {
                    Text(product.cardName)
                        .font(size == .cell ? Theme.lineFont : .system(size: 15))
                        .foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius))
            .task(id: url) { await load() }
    }

    private var url: URL? {
        guard let product, let game = Games.game(product.gameID) else { return nil }
        return PictureSource.url(for: product, game: game, ygo: model.ygoIndex)
    }

    private func load() async {
        picture = nil
        missing = false
        guard let url else {
            missing = true
            return
        }
        let pixels = size.maxPixels
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
        Self.cache.setObject(Entry(decoded.image), forKey: key, cost: Self.cost(of: decoded.image))
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
