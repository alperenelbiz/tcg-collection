import SwiftUI

/// What one gallery cell shows. The catalog passes a card ("3 printings", or "" for one printing, and the cheapest
/// price of its printings); the Collection passes a printing (`×3` and that printing's price).
nonisolated struct CellContent: Sendable {
    /// The printing whose picture is shown; nil shows the neutral placeholder.
    let product: ProductRecord?
    let name: String
    /// The text left of the price, in `muted`; "" for none.
    let left: String
    let price: ShownPrice?
}

/// One cell of a gallery (the cell rule of "The look, as rules"): the picture (59:86, radius 6), 7 pt below it the name
/// on one line, then one line with `left` in `muted` and the price right-aligned. No badge, no box, no border. Hover puts
/// `surface` behind the cell with 6 pt padding. No cell is ever selected (a click opens its page), so it has no
/// selection mark. The caller makes it a button or a link and gives it its identifier.
struct CardCell: View {
    let content: CellContent

    @State private var hovering = false

    /// The hover background reaches this far past the cell; with the 16 pt column gap two of them never touch.
    private static let hoverPadding: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardImage(product: content.product, size: .small)
            Text(content.name)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 7)
            HStack(spacing: 4) {
                if !content.left.isEmpty { Text(content.left).lineLimit(1) }
                Spacer(minLength: 0)
                Text(CardFacts.priceText(content.price))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(Theme.lineFont)
            .foregroundStyle(Theme.muted)
            .monospacedDigit()
            .padding(.top, 1)
        }
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: Theme.pictureRadius + Self.hoverPadding)
                    .fill(Theme.surface)
                    .padding(-Self.hoverPadding)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
