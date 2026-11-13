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
}
