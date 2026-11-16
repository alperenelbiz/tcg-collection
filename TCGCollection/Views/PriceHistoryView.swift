import Charts
import SwiftUI

/// The card page's "Price history" block (phase 5A: A38–A41, A44): the heading with the finish control, the summary line,
/// and the plot of one finish over the last 90 days, or, in the plot's frame, the sentence of its state. A thin view: the
/// model says the state (`AppModel.historyState`) and holds the history; `PriceChart` makes every value drawn.
///
/// Identifiers: `price-history` (the block), `price-history-finish` (the control; its segments are radio buttons named by
/// the finish), `price-history-summary`, `price-history-chart`, `price-history-note` (a state's sentence).
struct PriceHistoryView: View {
    let gameID: String
    let productID: Int
    /// The page's finish lines, in their order (`CollectionRules.finishes`).
    let finishes: [String]
    /// The copies owned of this product per finish.
    let owned: [String: Int]
    /// The page's card: a card just put on Wanted or in a deck reads "Reading price history…" at once.
    var cardKey: String? = nil

    @Environment(AppModel.self) private var model
    /// The finish the user picked; nil until a click (then the first choice of A38 applies).
    @State private var picked: String?
    /// The day under the pointer, while it is over the plot.
    @State private var pointer: Date?

    init(gameID: String, productID: Int, finishes: [String], owned: [String: Int], cardKey: String? = nil) {
        self.gameID = gameID
        self.productID = productID
        self.finishes = finishes
        self.owned = owned
        self.cardKey = cardKey
    }

    /// The finish shown: the one picked while the page offers it, else the first choice (A38).
    private var finish: String? {
        if let picked, finishes.contains(picked) { return picked }
        return PriceChart.firstFinish(offered: finishes, owned: owned)
    }

    var body: some View {
        let state = model.historyState(game: gameID, productID: productID, cardKey: cardKey)
        // Read so the block follows every change of the history in memory.
        let _ = model.historyVersions[gameID]
        let chart = chart(state: state)
        let note = chart == nil ? PriceChart.note(for: state) : chart?.note
        VStack(alignment: .leading, spacing: Theme.lineGap) {
            heading
            if let chart, let summary = chart.summary {
                summaryLine(chart: chart, summary: summary)
                    .padding(.bottom, 8)
                plot(chart)
            } else {
                frame(note: note)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(chart: chart, note: note))
        .accessibilityIdentifier("price-history")
    }

    // MARK: Parts

    private var heading: some View {
        HStack(spacing: 8) {
            Text("Price history")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            if finishes.count > 1, let finish {
                Picker("Finish", selection: Binding(get: { finish }, set: { picked = $0 })) {
                    ForEach(finishes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                // Not the accent (the selection mark of the sidebar and a sheet's default button only).
                .tint(Theme.faint)
                .fixedSize()
                .accessibilityIdentifier("price-history-finish")
            }
        }
        // The control keeps its height whether it is there or not, so the block does not move between printings.
        .frame(minHeight: 22)
    }

    /// The last price, then the change in `muted`; while the pointer is over the plot, that day instead.
    private func summaryLine(chart: PriceChart, summary: ChartSummary) -> some View {
        let text: AttributedString
        if let pointer, let readout = chart.nearest(to: pointer) {
            text = AttributedString(readout.text)
        } else {
            var price = AttributedString(summary.price)
            price.foregroundColor = Theme.text
            var change = AttributedString("  " + summary.change)
            change.foregroundColor = Theme.muted
            text = price + change
        }
        return Text(text)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.text)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityIdentifier("price-history-summary")
    }

    /// A state's frame: a flat `surface` block of the plot's size with its sentence, or none.
    private func frame(note: String?) -> some View {
        RoundedRectangle(cornerRadius: Theme.pictureRadius)
            .fill(Theme.surface)
            .frame(height: Theme.chartHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                if let note {
                    Text(note)
                        .font(Theme.lineFont)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note ?? "Price history")
            .accessibilityIdentifier(note == nil ? "" : "price-history-note", isEnabled: note != nil)
    }

    private func plot(_ chart: PriceChart) -> some View {
        let readout = pointer.flatMap { chart.nearest(to: $0) }
        let points = chart.runs.flatMap(\.points) + chart.dots
        let hovered = readout.flatMap { readout in points.first { $0.date == readout.date } }
        let low = chart.yTicks.first?.value ?? 0, high = chart.yTicks.last?.value ?? 1
        let lastTick = chart.xTicks.count - 1
        return Chart {
            ForEach(Array(chart.runs.enumerated()), id: \.offset) { index, run in
                ForEach(run.points, id: \.date) { point in
                    LineMark(x: .value("Day", point.date), y: .value("Price", point.amount), series: .value("Run", index))
                        .interpolationMethod(.linear)
                        .foregroundStyle(Theme.text)
                        .lineStyle(StrokeStyle(lineWidth: Theme.chartLineWidth, lineJoin: .round,
                                               dash: run.isLow ? [2, 3] : []))
                }
            }
            ForEach(chart.dots, id: \.date) { point in
                PointMark(x: .value("Day", point.date), y: .value("Price", point.amount))
                    .foregroundStyle(Theme.text)
                    .symbolSize(CGSize(width: Theme.chartLineWidth, height: Theme.chartLineWidth))
            }
            if let hovered {
                RuleMark(x: .value("Day", hovered.date))
                    .foregroundStyle(Theme.raised)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Day", hovered.date), y: .value("Price", hovered.amount))
                    .foregroundStyle(Theme.text)
                    .symbolSize(CGSize(width: Theme.chartDot, height: Theme.chartDot))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: chart.xDomain)
        .chartYScale(domain: low...max(high, low))
        .chartXAxis {
            AxisMarks(values: chart.xTicks.map(\.date)) { value in
                // The first and the last label are pulled inside the plot.
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == lastTick ? .topTrailing : .top,
                               collisionResolution: .disabled) {
                    axisText(chart.xTicks.indices.contains(value.index) ? chart.xTicks[value.index].label : "")
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: chart.yTicks.map(\.value)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.rule)
                AxisValueLabel(collisionResolution: .disabled) {
                    axisText(chart.yTicks.indices.contains(value.index) ? chart.yTicks[value.index].label : "")
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame else { return }
                            let x = location.x - geometry[anchor].origin.x
                            pointer = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            pointer = nil
                        }
                    }
            }
        }
        #if os(iOS)
        .chartXSelection(value: $pointer)
        #endif
        .frame(height: Theme.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(chart: chart, note: nil))
        .accessibilityIdentifier("price-history-chart")
    }

    private func axisText(_ label: String) -> some View {
        Text(label)
            .font(Theme.labelFont)
            .foregroundStyle(Theme.faint)
            .monospacedDigit()
    }

    /// What VoiceOver reads for the block: "Price history, Normal, $12.40, +$1.20 in 90 days", or the state's sentence.
    private func spoken(chart: PriceChart?, note: String?) -> String {
        if let summary = chart?.summary {
            return ["Price history", finish, summary.price, summary.change].compactMap { $0 }.joined(separator: ", ")
        }
        return ["Price history", note].compactMap { $0 }.joined(separator: ", ")
    }

    /// The chart of the shown finish, for a ready history; nil in every other state.
    private func chart(state: HistoryState) -> PriceChart? {
        guard state == .ready, let finish, let history = model.history(game: gameID) else { return nil }
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: model.now()))
        return PriceChart(points: history.points(productID: productID, finish: finish), window: window)
    }
}
