import CoreGraphics
import Testing
@testable import TCGCollection2

@MainActor
struct CardImageTests {
    /// The widest a gallery cell gets: an adaptive grid adds a column as soon as two minimum cells and a gap fit, so one
    /// column is at most 2 × 150 + 16 = 316 pt wide. Its picture (59:86, filled) is then 460.6 pt tall: 922 px on a 2×
    /// display. A cell decodes its picture's long side to 960 px, so the widest cell is sharp and a cell's memory stays
    /// bounded whatever the source's size. (The iPhone at 3×: two columns of at most 194 pt on a 440 pt screen, 849 px.)
    @Test func aCellDecodesEnoughPixelsForTheWidestCell() {
        let widest = 2 * Theme.cellMinWidth + Theme.columnGap
        let tallest = widest * 86 / 59
        #expect(Int((tallest * 2).rounded(.up)) == 922)
        #expect(PictureSize.cell.maxPixels == 960)
        #expect(PictureSize.cell.maxPixels >= Int((tallest * 2).rounded(.up)))
    }

    /// A card page shows its picture at most 280 pt wide: 408 pt tall, 817 px at 2×.
    @Test func aPageDecodesEnoughPixelsForItsPicture() {
        #expect(PictureSize.page.maxPixels == 1200)
        #expect(PictureSize.page.maxPixels >= Int((280.0 * 86 / 59 * 2).rounded(.up)))
    }

    /// A deck list row (A57) shows its picture at most 40 pt tall (the iPhone): 120 px at 3×; card proportion 63 : 88,
    /// corner radius 3.
    @Test func aRowDecodesEnoughPixelsForItsPicture() {
        #expect(PictureSize.row.maxPixels == 128)
        #expect(PictureSize.row.maxPixels >= 40 * 3)
        #expect(abs(PictureSize.row.aspectRatio - 63.0 / 88.0) < 0.0001)
        #expect(abs(PictureSize.cell.aspectRatio - 59.0 / 86.0) < 0.0001)
        #expect(PictureSize.row.cornerRadius == 3)
        #expect(PictureSize.cell.cornerRadius == Theme.pictureRadius)
        #expect(PictureSize.page.cornerRadius == Theme.largePictureRadius)
    }

    /// Decoded pictures are kept in memory up to a limit: a cell's picture is about 2.6 MB (688 × 960 px, 4 bytes each),
    /// so a gallery scrolled end to end would else hold gigabytes. The cost of an entry is its decoded size.
    @Test func decodedPicturesAreKeptUpToAMemoryLimit() throws {
        #expect(CardImage.memoryLimit == 300 * 1024 * 1024)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 688, height: 960, bitsPerComponent: 8, bytesPerRow: 688 * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        #expect(CardImage.cost(of: image) == 688 * 4 * 960)
        #expect(CardImage.memoryLimit / CardImage.cost(of: image) >= 100)   // room for a few screens of cells
    }
}
