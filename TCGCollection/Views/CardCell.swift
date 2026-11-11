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

    /// `$4.12`; `~$9.50` when only a low price exists; `—` with no price.
    private var priceText: String {
        guard let shown = model.prices.cheapest(game: summary.cover.gameID, productIDs: summary.productIDs) else { return "—" }
        let amount = shown.amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        return shown.isLow ? "~" + amount : amount
    }
}
