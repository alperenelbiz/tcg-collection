import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One cell of a list's PDF: the name, the copies, the price and the picture's bytes (nil, or bytes that are no picture:
/// the grey block).
nonisolated struct PDFItem: Sendable, Equatable {
    let name: String
    let count: Int
    let price: ShownPrice?
    let picture: Data?
}

/// The list a PDF is of.
nonisolated enum PDFList: Sendable {
    case wanted, forSale

    /// Its name in the title line.
    var title: String { self == .wanted ? "Wanted" : "For Sale" }
    /// Its name in the file name.
    var fileTag: String { self == .wanted ? "wanted" : "for-sale" }
}

/// The PDF of a list (C10): A4 portrait, 4 columns of card pictures (63 : 88), under each the name (two lines at most),
/// `×n` and the price; on page 1 the title line and the total line; the page number at the foot of every page; the most
/// expensive first. A white page and black text: it is made for printing and sending, so its colours are print colours
/// of its own, not the screen's `Theme`. Drawn with Core Graphics and Core Text, the same on the Mac and the iPhone.
/// Pure: it reads no clock, no network and no file. Places are in points from the page's top left, as on paper.
nonisolated enum ListPDF {
    // MARK: The page

    /// A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 36
    static let columns = 4
    static let columnGap: CGFloat = 12
    static let rowGap: CGFloat = 14
    /// A card's height over its width (63 × 88 mm).
    static let cardRatio: CGFloat = 88.0 / 63.0
    static let pictureRadius: CGFloat = 4
    /// Page 1 only, above the first row: the title line, the total line and a gap.
    static let titleLineHeight: CGFloat = 18
    static let totalLineHeight: CGFloat = 14
    static let headerGap: CGFloat = 14
    /// Every page, under the last row: the page number.
    static let footerHeight: CGFloat = 20
    /// Under a picture: a gap, the name on `nameLineLimit` lines at most, a gap, then `×n` left and the price right.
    static let pictureTextGap: CGFloat = 5
    static let cellLineHeight: CGFloat = 11
    static let nameLineLimit = 2
    static let countLineGap: CGFloat = 2

    // MARK: Type and colours

    static let titleSize: CGFloat = 14
    static let totalSize: CGFloat = 10
    static let cellTextSize: CGFloat = 9
    static let pageNumberSize: CGFloat = 8
    /// The page: white.
    static let paper: CGFloat = 1
    /// Every text: black.
    static let ink: CGFloat = 0
    /// The block of a missing picture: #E6E6E6.
    static let missingPicture: CGFloat = 0xE6 / 255.0
    /// A picture larger than its cell needs at this resolution is drawn at this size (a JPEG again); a smaller one goes in
    /// as its own bytes. The pictures of the lists are the small ones (200 pixels wide), so they go in as they are.
    static let pictureDPI: CGFloat = 300
    static let jpegQuality: CGFloat = 0.8

    // MARK: The grid

    /// The width of a column, and of the picture in it.
    static var cellWidth: CGFloat { (pageSize.width - 2 * margin - CGFloat(columns - 1) * columnGap) / CGFloat(columns) }
    static var pictureHeight: CGFloat { cellWidth * cardRatio }
    /// The text under a picture: the gap, the name's lines (kept for two, also for a one-line name), the gap, `×n`.
    static var textHeight: CGFloat {
        pictureTextGap + CGFloat(nameLineLimit) * cellLineHeight + countLineGap + cellLineHeight
    }
    static var cellHeight: CGFloat { pictureHeight + textHeight }

    private static func gridTop(firstPage: Bool) -> CGFloat {
        margin + (firstPage ? titleLineHeight + totalLineHeight + headerGap : 0)
    }

    private static var gridBottom: CGFloat { pageSize.height - margin - footerHeight }

    /// The rows that fit between the grid's top and the page number.
    static func rows(firstPage: Bool) -> Int {
        Int((gridBottom - gridTop(firstPage: firstPage) + rowGap) / (cellHeight + rowGap))
    }

    static func itemsPerPage(first: Bool) -> Int { columns * rows(firstPage: first) }

    /// The pages of a list of `items`; an empty list is one page with the title and "Nothing on this list.".
    static func pageCount(items: Int) -> Int {
        let first = itemsPerPage(first: true)
        guard items > first else { return 1 }
        let rest = itemsPerPage(first: false)
        return 1 + (items - first + rest - 1) / rest
    }

    /// The picture of the `slot`-th cell of a page (row by row, left to right), in points from the page's top left.
    static func pictureRect(slot: Int, firstPage: Bool) -> CGRect {
        let row = slot / columns, column = slot % columns
        return CGRect(x: margin + CGFloat(column) * (cellWidth + columnGap),
                      y: gridTop(firstPage: firstPage) + CGFloat(row) * (cellHeight + rowGap),
                      width: cellWidth, height: pictureHeight)
    }

    /// The text under the `slot`-th cell's picture.
    static func textRect(slot: Int, firstPage: Bool) -> CGRect {
        let picture = pictureRect(slot: slot, firstPage: firstPage)
        return CGRect(x: picture.minX, y: picture.maxY, width: cellWidth, height: textHeight)
    }

    // MARK: The texts

    /// Price high to low (a low price counts as its amount), items without a price last; then by name, ignoring case;
    /// then as given.
    static func ordered(_ items: [PDFItem]) -> [PDFItem] {
        items.enumerated().sorted { a, b in
            switch (a.element.price?.amount, b.element.price?.amount) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let byName = a.element.name.caseInsensitiveCompare(b.element.name)
                return byName == .orderedSame ? a.offset < b.offset : byName == .orderedAscending
            }
        }.map(\.element)
    }

    /// `4 copies · $6.00`: the copies and the summed price of the copies (price × count; a low price counts as its
    /// amount). Items without a price are left out of the sum and counted after it, as on the screens
    /// (`CollectionList.priceTail`): `… · $3.00 + 1 without a price`; with no priced item `… · 2 without a price`, never
    /// `$0.00`. "" for an empty list.
    static func totalLine(_ items: [PDFItem]) -> String {
        guard !items.isEmpty else { return "" }
        let copies = items.reduce(0) { $0 + $1.count }
        let priced = items.filter { $0.price != nil }
        let sum = priced.isEmpty ? nil : priced.reduce(0.0) { $0 + ($1.price?.amount ?? 0) * Double($1.count) }
        let tail = CollectionList.priceTail(sum: sum, unpriced: items.count - priced.count)
        return (["\(copies) \(copies == 1 ? "copy" : "copies")"] + [tail].compactMap { $0 }).joined(separator: " · ")
    }

    /// "Riftbound — For Sale — 13 November 2026": the day of `date` in `timeZone`, the month in English.
    static func title(game: String, list: PDFList, date: Date, timeZone: TimeZone) -> String {
        let day = calendarDay(date, timeZone: timeZone)
        return "\(game) — \(list.title) — \(day.day) \(months[day.month - 1]) \(day.year)"
    }

    /// `riftbound-for-sale-2026-11-13.pdf`: the day of `date` in `timeZone`.
    static func fileName(gameID: String, list: PDFList, date: Date, timeZone: TimeZone) -> String {
        let day = calendarDay(date, timeZone: timeZone)
        return "\(gameID)-\(list.fileTag)-" + String(format: "%04d-%02d-%02d", day.year, day.month, day.day) + ".pdf"
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    private static func calendarDay(_ date: Date, timeZone: TimeZone) -> (year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    /// The lines a name takes under its picture: the first as wide as the cell, then the rest on a second line, cut with
    /// "…" when it does not fit.
    static func nameLines(_ name: String) -> [String] {
        nameLines(name, font: font(size: cellTextSize))
    }

    /// The width of `text` in a cell's type, in points: a name line fits when it is at most `cellWidth`.
    static func cellTextWidth(_ text: String) -> CGFloat {
        lineWidth(text, font: font(size: cellTextSize))
    }

    private static func nameLines(_ name: String, font: CTFont) -> [String] {
        let text = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let width = cellWidth
        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text, font: font))
        let whole = text as NSString
        let firstLength = max(1, CTTypesetterSuggestLineBreak(typesetter, 0, Double(width)))
        let first = whole.substring(to: firstLength).trimmingCharacters(in: .whitespaces)
        guard firstLength < whole.length else { return [first] }
        let rest = whole.substring(from: firstLength).trimmingCharacters(in: .whitespaces)
        if lineWidth(rest, font: font) <= width { return [first, rest] }
        // The longest start of the rest that fits with "…" after it.
        let characters = Array(rest)
        func cut(_ count: Int) -> String {
            String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
        }
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineWidth(cut(middle), font: font) <= width { low = middle } else { high = middle - 1 }
        }
        return [first, cut(low)]
    }

    // MARK: Drawing

    /// The PDF of `items` (in the order of `ordered`, whatever order they come in) under `title`. Nil when no PDF context
    /// can be made: nothing is offered then, never an empty file.
    static func data(title: String, items: [PDFItem]) -> Data? {
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "TCG Collection 2"] as CFDictionary
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        let fonts = Fonts()
        let items = ordered(items)
        let pages = pageCount(items: items.count)
        var next = 0
        for page in 1...pages {
            let first = page == 1
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.setFillColor(color(paper))
            context.fill(CGRect(origin: .zero, size: pageSize))
            if first {
                draw(title, font: fonts.title, x: margin, top: margin, in: context)
                draw(items.isEmpty ? "Nothing on this list." : totalLine(items), font: fonts.total, x: margin,
                     top: margin + titleLineHeight, in: context)
            }
            let count = min(itemsPerPage(first: first), items.count - next)
            for slot in 0..<count {
                drawCell(items[next + slot], slot: slot, firstPage: first, fonts: fonts, in: context)
            }
            next += count
            let number = line("\(page) / \(pages)", font: fonts.pageNumber)
            draw(number, font: fonts.pageNumber, x: (pageSize.width - width(of: number)) / 2,
                 top: pageSize.height - margin - cellLineHeight, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return out as Data
    }

    /// The picture (or the grey block), the name, `×n` and the price.
    private static func drawCell(_ item: PDFItem, slot: Int, firstPage: Bool, fonts: Fonts, in context: CGContext) {
        let picture = pictureRect(slot: slot, firstPage: firstPage)
        drawPicture(item.picture.flatMap(image(from:)), in: picture, context: context)
        var top = picture.maxY + pictureTextGap
        for text in nameLines(item.name, font: fonts.cell) {
            draw(text, font: fonts.cell, x: picture.minX, top: top, in: context)
            top += cellLineHeight
        }
        let countTop = picture.maxY + pictureTextGap + CGFloat(nameLineLimit) * cellLineHeight + countLineGap
        draw("×\(item.count)", font: fonts.cell, x: picture.minX, top: countTop, in: context)
        let price = line(CardFacts.priceText(item.price), font: fonts.cell)
        draw(price, font: fonts.cell, x: picture.maxX - width(of: price), top: countTop, in: context)
    }

    /// The picture filling its card-shaped box (cut at the box's edges, rounded corners), or the grey block.
    private static func drawPicture(_ image: CGImage?, in rect: CGRect, context: CGContext) {
        let box = onPage(rect)
        context.saveGState()
        context.addPath(CGPath(roundedRect: box, cornerWidth: pictureRadius, cornerHeight: pictureRadius, transform: nil))
        context.clip()
        if let image, image.width > 0, image.height > 0 {
            let scale = max(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                           width: size.width, height: size.height))
        } else {
            context.setFillColor(color(missingPicture))
            context.fill(box)
        }
        context.restoreGState()
    }

    /// The picture as it is drawn. Bytes of a picture no larger than its cell needs (`pictureDPI`) are used as they are,
    /// so the PDF keeps a JPEG's own bytes; a larger picture is made smaller and a JPEG again (a decoded picture would go in
    /// pixel by pixel). Nil for bytes that are no picture.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let limit = Int((pictureHeight * pictureDPI / 72).rounded(.up))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if width > 0, height > 0, max(width, height) <= limit {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: limit] as CFDictionary
        guard let smaller = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return smaller }
        CGImageDestinationAddImage(destination, smaller, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let again = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
            return smaller
        }
        return CGImageSourceCreateImageAtIndex(again, 0, nil) ?? smaller
    }

    // MARK: Text drawing

    /// The fonts of one PDF: the system's, as on screen.
    private nonisolated struct Fonts {
        let title = ListPDF.font(size: ListPDF.titleSize, bold: true)
        let total = ListPDF.font(size: ListPDF.totalSize)
        let cell = ListPDF.font(size: ListPDF.cellTextSize)
        let pageNumber = ListPDF.font(size: ListPDF.pageNumberSize)
    }

    private static func font(size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    private static func attributed(_ text: String, font: CTFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(ink),
        ])
    }

    private static func line(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(attributed(text, font: font))
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        width(of: line(text, font: font))
    }

    private static func draw(_ text: String, font: CTFont, x: CGFloat, top: CGFloat, in context: CGContext) {
        draw(line(text, font: font), font: font, x: x, top: top, in: context)
    }

    /// Draws `line` with its first baseline one ascent under `top`.
    private static func draw(_ line: CTLine, font: CTFont, x: CGFloat, top: CGFloat, in context: CGContext) {
        context.textPosition = CGPoint(x: x, y: pageSize.height - top - CTFontGetAscent(font))
        CTLineDraw(line, context)
    }

    /// A rectangle from the top left, in the PDF's own coordinates (from the bottom left).
    private static func onPage(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: pageSize.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A grey of the print colours, in sRGB, so #E6E6E6 stays #E6E6E6.
    private static func color(_ gray: CGFloat) -> CGColor {
        CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }
}
