import SwiftUI

/// One card in the gallery: picture, name, printing count and the cheapest price of its printings.
struct CardCell: View {
    let summary: CardSummary

    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink(value: summary) {
            VStack(alignment: .leading, spacing: 6) {
                CardImage(product: summary.cover, size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .lineLimit(1)
                    HStack {
                        if summary.printings > 1 { Text("\(summary.printings) printings") }
                        Spacer(minLength: 4)
                        Text(priceText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var priceText: String {
        CardFacts.priceText(model.prices.cheapest(game: summary.cover.gameID, productIDs: summary.productIDs))
    }
}
