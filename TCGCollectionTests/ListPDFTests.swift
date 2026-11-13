import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import TCGCollection2

/// C10 and Review Focus 5: the PDF of a list, read back with PDFKit (pages, text) and drawn on a bitmap (its look).
/// With `TCG_PDF_LOOK_DIR` set (`TEST_RUNNER_TCG_PDF_LOOK_DIR` for xcodebuild), the look test also writes its page
/// pictures there as PNG files, to be looked at.
struct ListPDFTests {
    private static let title = "Riftbound — For Sale — 13 November 2026"
    private static let longName = "Kami of the Old Way and the New Day, Who Sits by the Red Gate and Waits for the Rain to Go"

    /// Two priced items (one with a low price only) and one without a price and without a picture.
    private func smallList() throws -> [PDFItem] {
        let picture = try fixture("picture.jpg")
        return [PDFItem(name: "Dockside Lock-Up", count: 2, price: ShownPrice(amount: 1.5, isLow: false), picture: picture),
                PDFItem(name: "Mind Rune", count: 1, price: nil, picture: nil),
                PDFItem(name: "Calm Rune (R02a)", count: 1, price: ShownPrice(amount: 3, isLow: true), picture: picture)]
    }

    private func document(_ data: Data) throws -> PDFDocument { try #require(PDFDocument(data: data)) }

    private func text(_ data: Data, page: Int = 0) throws -> String { try #require(document(data).page(at: page)?.string) }

    // MARK: The grid

    /// A4, 36 pt margins, 4 columns of card pictures (63 : 88) with the name, `×n` and the price under each: 3 rows on
    /// every page; the title and the total line fit above the first page's rows, the page number under every page's.
    @Test func theGridHoldsTwelveCardsAPage() {
        #expect(ListPDF.columns == 4)
        #expect(ListPDF.itemsPerPage(first: true) == 12)
        #expect(ListPDF.itemsPerPage(first: false) == 12)
        #expect(ListPDF.pageSize == CGSize(width: 595, height: 842))
        let picture = ListPDF.pictureRect(slot: 0, firstPage: false)
        #expect(abs(picture.height / picture.width - 88.0 / 63.0) < 0.0001)
        #expect(picture.minX == 36 && picture.minY == 36)
        // The fourth column ends at the right margin; the last row's text ends above the page number.
        #expect(abs(ListPDF.pictureRect(slot: 3, firstPage: false).maxX - (595 - 36)) < 0.0001)
    }

    @Test func thePageCountFollowsTheGrid() {
        let capacity = ListPDF.itemsPerPage(first: true)
        #expect(ListPDF.pageCount(items: 0) == 1)                // the title and "Nothing on this list."
        #expect(ListPDF.pageCount(items: 1) == 1)
        #expect(ListPDF.pageCount(items: capacity) == 1)
        #expect(ListPDF.pageCount(items: capacity + 1) == 2)
        #expect(ListPDF.pageCount(items: 24) == 2)
        #expect(ListPDF.pageCount(items: 25) == 3)
        #expect(ListPDF.pageCount(items: 500) == 42)
    }

    @Test func thePageIsA4() throws {
        let page = try #require(document(ListPDF.data(title: Self.title, items: smallList())).page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
    }

    // MARK: The text

    @Test func aSmallListHasItsTitleNamesCountsPricesAndTotal() throws {
        let data = ListPDF.data(title: Self.title, items: try smallList())
        #expect(try document(data).pageCount == 1)
        let page = try text(data)
        for shown in [Self.title, "Dockside Lock-Up", "Mind Rune", "Calm Rune (R02a)", "×2", "×1", "$1.50", "~$3.00",
                      "4 copies · $6.00 + 1 without a price", "1 / 1"] {
            #expect(page.contains(shown), "\(shown) is not on the page: \(page)")
        }
    }

    @Test func theMostExpensiveComeFirstAndNoPriceLast() throws {
        #expect(ListPDF.ordered(try smallList()).map(\.name) == ["Calm Rune (R02a)", "Dockside Lock-Up", "Mind Rune"])
        // Equal prices go by name, ignoring case; two without a price too.
        let same = [PDFItem(name: "beta", count: 1, price: ShownPrice(amount: 2, isLow: false), picture: nil),
                    PDFItem(name: "Zeta", count: 1, price: nil, picture: nil),
                    PDFItem(name: "Alpha", count: 1, price: ShownPrice(amount: 2, isLow: true), picture: nil),
                    PDFItem(name: "eta", count: 1, price: nil, picture: nil)]
        #expect(ListPDF.ordered(same).map(\.name) == ["Alpha", "beta", "eta", "Zeta"])
        // The page draws them in that order, whatever order it was given.
        let page = try text(ListPDF.data(title: Self.title, items: try smallList()))
        let places = try ["Calm Rune (R02a)", "Dockside Lock-Up", "Mind Rune"].map { try #require(page.range(of: $0)).lowerBound }
        #expect(places == places.sorted())
    }

    @Test func anItemWithoutAPictureStillShowsItsName() throws {
        let page = try text(ListPDF.data(title: Self.title, items: [PDFItem(name: "Mind Rune", count: 3, price: nil, picture: nil)]))
        #expect(page.contains("Mind Rune"))
        #expect(page.contains("×3"))
        #expect(page.contains("3 copies · 1 without a price"))
    }

    /// Review Focus 5: a name of 90 characters takes two lines at most, the second one ending with "…"; the cell beside it
    /// keeps its own text.
    @Test func aLongNameIsCutAtTwoLinesAndTheNextCellIsIntact() throws {
        #expect(Self.longName.count == 90)
        let lines = ListPDF.nameLines(Self.longName)
        #expect(lines.count == 2)
        #expect(lines.last?.hasSuffix("…") == true)
        #expect(lines.first.map { Self.longName.hasPrefix($0) } == true)
        #expect(ListPDF.nameLines("Mind Rune") == ["Mind Rune"])
        let next = "Sunlit Valley Guardian"
        let price = ShownPrice(amount: 1, isLow: false)
        let page = try text(ListPDF.data(title: Self.title, items: [PDFItem(name: next, count: 1, price: price, picture: nil),
                                                                    PDFItem(name: Self.longName, count: 1, price: price, picture: nil)]))
        #expect(page.contains(String(Self.longName.prefix(20))), "\(page)")
        #expect(page.contains(String(next.prefix(20))), "\(page)")
        #expect(!page.contains(String(Self.longName.suffix(12))), "the end of the long name is on the page: \(page)")
        #expect(page.contains("…"))
    }

    @Test func anEmptyListIsOnePageWithTheTitle() throws {
        let data = ListPDF.data(title: Self.title, items: [])
        #expect(try document(data).pageCount == 1)
        let page = try text(data)
        #expect(page.contains(Self.title))
        #expect(page.contains("Nothing on this list."))
        #expect(ListPDF.totalLine([]) == "")
    }

    /// The title and the total line are on page 1 only; every page has its number at the foot.
    @Test func everyPageHasItsNumberAndOnlyTheFirstHasTheTitle() throws {
        let items = (1...13).map { PDFItem(name: "Card \($0)", count: 1, price: nil, picture: nil) }
        let data = ListPDF.data(title: Self.title, items: items)
        #expect(try document(data).pageCount == 2)
        let first = try text(data, page: 0), second = try text(data, page: 1)
        #expect(first.contains(Self.title) && first.contains("1 / 2") && first.contains("13 copies · 13 without a price"))
        #expect(!second.contains(Self.title) && second.contains("2 / 2") && !second.contains("without a price"))
        #expect(second.contains("Card 9"))                      // the 13th by name ("Card 1", "Card 10", …, "Card 9")
    }

    /// Review Focus 5: 500 items, every picture missing (offline): the right page count, quickly.
    @Test func fiveHundredItemsWithoutPicturesMakeTheirPagesQuickly() throws {
        let items = (1...500).map { PDFItem(name: "Card \($0) of a long list", count: $0 % 4 + 1,
                                            price: $0 % 3 == 0 ? nil : ShownPrice(amount: Double($0) / 7, isLow: $0 % 5 == 0),
                                            picture: nil) }
        let clock = ContinuousClock()
        var data = Data()
        let time = clock.measure { data = ListPDF.data(title: Self.title, items: items) }
        #expect(time < .seconds(5), "\(time)")
        #expect(try document(data).pageCount == ListPDF.pageCount(items: 500))
        #expect(try document(data).pageCount == 42)
    }

    @Test func theTotalLineSumsPriceTimesCopies() {
        func item(_ count: Int, _ amount: Double?, low: Bool = false) -> PDFItem {
            PDFItem(name: "x", count: count, price: amount.map { ShownPrice(amount: $0, isLow: low) }, picture: nil)
        }
        #expect(ListPDF.totalLine([item(2, 1.5), item(1, 3, low: true)]) == "3 copies · $6.00")
        #expect(ListPDF.totalLine([item(1, 1.5)]) == "1 copy · $1.50")
        #expect(ListPDF.totalLine([item(2, 1.5), item(3, nil)]) == "5 copies · $3.00 + 1 without a price")
        #expect(ListPDF.totalLine([item(2, nil), item(1, nil)]) == "3 copies · 2 without a price")    // no $0.00
        #expect(ListPDF.totalLine([item(1, 1234.5)]) == "1 copy · $1,234.50")
        #expect(ListPDF.totalLine([]) == "")
    }

    // MARK: The title and the file name

    @Test func theTitleAndTheFileNameTakeTheGivenDay() throws {
        let noon = Date(timeIntervalSince1970: 1_794_571_200)              // 2026-11-13 12:00 UTC
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ListPDF.title(game: "Riftbound", list: .forSale, date: noon, timeZone: utc) == Self.title)
        #expect(ListPDF.title(game: "Yu-Gi-Oh!", list: .wanted, date: noon, timeZone: utc) == "Yu-Gi-Oh! — Wanted — 13 November 2026")
        #expect(ListPDF.fileName(gameID: "riftbound", list: .forSale, date: noon, timeZone: utc) == "riftbound-for-sale-2026-11-13.pdf")
        #expect(ListPDF.fileName(gameID: "yu-gi-oh", list: .wanted, date: noon, timeZone: utc) == "yu-gi-oh-wanted-2026-11-13.pdf")
        // The day is the one of the given time zone: 23:30 UTC is already the next day in Istanbul.
        let late = noon.addingTimeInterval(11.5 * 3600)
        let istanbul = try #require(TimeZone(identifier: "Europe/Istanbul"))
        #expect(ListPDF.title(game: "Riftbound", list: .wanted, date: late, timeZone: istanbul) == "Riftbound — Wanted — 14 November 2026")
        #expect(ListPDF.fileName(gameID: "riftbound", list: .wanted, date: late, timeZone: istanbul) == "riftbound-wanted-2026-11-14.pdf")
        let january = Date(timeIntervalSince1970: 1_798_761_600)           // 2027-01-01 00:00 UTC
        #expect(ListPDF.title(game: "Riftbound", list: .wanted, date: january, timeZone: utc) == "Riftbound — Wanted — 1 January 2027")
        #expect(ListPDF.fileName(gameID: "riftbound", list: .wanted, date: january, timeZone: utc) == "riftbound-wanted-2027-01-01.pdf")
    }

    // MARK: Pictures

    /// A picture of at most the cell's size is put into the PDF as it is: 40 different small pictures make a PDF of about
    /// their own bytes, not of their decoded pixels.
    @Test func smallPicturesGoInAsTheyAre() throws {
        let pictures = (0..<40).map { Self.noisyJPEG(width: 200, height: 279, seed: UInt64($0) + 1) }
        let items = pictures.enumerated().map { PDFItem(name: "Card \($0.offset)", count: 1, price: nil, picture: $0.element) }
        let size = ListPDF.data(title: Self.title, items: items).count
        let bytes = pictures.reduce(0) { $0 + $1.count }
        #expect(size < bytes + 150_000, "\(size) bytes for \(bytes) bytes of pictures")
    }

    /// A picture larger than the cell needs is drawn at the cell's size: it is not put into the PDF at full size.
    @Test func aLargePictureIsDrawnAtTheCellsSize() throws {
        let large = Self.noisyJPEG(width: 1000, height: 1400, seed: 7)
        let size = ListPDF.data(title: Self.title, items: [PDFItem(name: "Big", count: 1, price: nil, picture: large)]).count
        #expect(size < large.count / 3, "\(size) bytes for a picture of \(large.count) bytes")
    }

    /// Bytes that are not a picture give the grey block, as no picture does.
    @Test func bytesThatAreNoPictureGiveTheGreyBlock() throws {
        let data = ListPDF.data(title: Self.title, items: [PDFItem(name: "Odd", count: 1, price: nil, picture: Data("no".utf8))])
        let page = try PagePicture(data)
        #expect(page.color(at: ListPDF.pictureRect(slot: 0, firstPage: true).center) == Self.grey)
        #expect(try text(data).contains("Odd"))
    }

    // MARK: The look

    private static let white = RGB(r: 255, g: 255, b: 255)
    private static let grey = RGB(r: 0xE6, g: 0xE6, b: 0xE6)

    /// A white page; a picture where the item has one, the grey block (#E6E6E6) where it has none; black text. Page 1 of
    /// a list with pictures and of one without them.
    @Test func thePageIsWhiteWithPicturesAndGreyBlocks() throws {
        let data = ListPDF.data(title: Self.title, items: try smallList())   // drawn: Calm Rune, Dockside, Mind Rune
        let page = try PagePicture(data)
        #expect(page.color(at: CGPoint(x: 10, y: 10)) == Self.white)
        #expect(page.color(at: CGPoint(x: 585, y: 832)) == Self.white)
        for slot in 0..<2 {
            let shown = page.color(at: ListPDF.pictureRect(slot: slot, firstPage: true).center)
            #expect(shown != Self.white && shown != Self.grey, "slot \(slot): \(shown)")
        }
        #expect(page.color(at: ListPDF.pictureRect(slot: 2, firstPage: true).center) == Self.grey)
        #expect(page.color(at: ListPDF.pictureRect(slot: 3, firstPage: true).center) == Self.white)   // no fourth item
        #expect(page.hasBlack(in: ListPDF.textRect(slot: 2, firstPage: true)), "no black text under the third cell")

        // For the look: page 1 of a full page with pictures (one missing, one long name) and of one without pictures.
        let picture = try fixture("picture.jpg")
        let full = (0..<14).map { (index: Int) -> PDFItem in
            let name = index == 1 ? Self.longName : "Card \(index + 1)"
            let price: ShownPrice? = index == 5 ? nil : ShownPrice(amount: Double(20 - index) * 1.25, isLow: index == 2)
            return PDFItem(name: name, count: index % 3 + 1, price: price, picture: index == 4 ? nil : picture)
        }
        let without = full.map { PDFItem(name: $0.name, count: $0.count, price: $0.price, picture: nil) }
        let pictures = try PagePicture(ListPDF.data(title: Self.title, items: full))
        let blocks = try PagePicture(ListPDF.data(title: Self.title, items: without))
        #expect(blocks.color(at: ListPDF.pictureRect(slot: 0, firstPage: true).center) == Self.grey)
        if let folder = ProcessInfo.processInfo.environment["TCG_PDF_LOOK_DIR"] {
            let dir = URL(fileURLWithPath: folder, isDirectory: true)
            try pictures.writePNG(to: dir.appending(path: "pdf-page-with-pictures.png"))
            try blocks.writePNG(to: dir.appending(path: "pdf-page-without-pictures.png"))
        }
    }

    // MARK: Helpers

    /// A JPEG of `width` × `height` pixels of noise: it does not compress, so its size shows how a PDF keeps it.
    static func noisyJPEG(width: Int, height: Int, seed: UInt64) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt64.self)
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        for index in 0..<(width * height / 2) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17      // xorshift
            bytes[index] = state
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}

struct RGB: Equatable, CustomStringConvertible {
    let r: Int, g: Int, b: Int
    var description: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Page 1 of a PDF drawn on white, 2 pixels per point. Points are counted from the top left, as on paper.
struct PagePicture {
    static let scale: CGFloat = 2
    let image: CGImage
    private let bytes: [UInt8]
    private let bytesPerRow: Int

    init(_ data: Data) throws {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width * Self.scale), height = Int(box.height * Self.scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: Self.scale, y: Self.scale)
        context.drawPDFPage(page)
        image = try #require(context.makeImage())
        bytesPerRow = context.bytesPerRow
        let raw = try #require(context.data)
        bytes = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
    }

    /// The colour at `point` (points from the top left). A bitmap context keeps its top row first.
    func color(at point: CGPoint) -> RGB {
        let offset = Int(point.y * Self.scale) * bytesPerRow + Int(point.x * Self.scale) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }

    /// True when a pixel in `rect` (points from the top left) is near black: text.
    func hasBlack(in rect: CGRect) -> Bool {
        for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
                let c = color(at: CGPoint(x: x, y: y))
                if c.r < 60 && c.g < 60 && c.b < 60 { return true }
            }
        }
        return false
    }

    func writePNG(to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
