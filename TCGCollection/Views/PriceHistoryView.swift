import Charts
import SwiftUI

/// The card page's "Price history" block (phase 5A: A38–A41, A44): the heading with the finish control, the summary line,
/// and the plot of one finish over the last 90 days, or, in the plot's frame, the sentence of its state. A thin view: the
/// model says the state (`AppModel.historyState`) and gives the points (`AppModel.dayPoints`: the day files on this device
/// merged with the iCloud history file, phase 5B task 4); `PriceChart` makes every value drawn. The block's task asks the
/// model to read the printing's day files (off the main actor) whenever a day file is added or the window moves.
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

    @Environment(AppModel.self) private var model
    /// The finish the user picked; nil until a click (then the first choice of A38 applies).
    @State private var picked: String?
    /// The nearest day with a price to the pointer, while it is over the plot (iOS: the selected day).
    @State private var pointer: Date?

    init(gameID: String, productID: Int, finishes: [String], owned: [String: Int]) {
        self.gameID = gameID
        self.productID = productID
        self.finishes = finishes
        self.owned = owned
    }

    /// The finish shown: the one picked while the page offers it, else the first choice (A38).
    private var finish: String? {
        if let picked, finishes.contains(picked) { return picked }
        return PriceChart.firstFinish(offered: finishes, owned: owned)
    }

    var body: some View {
        let state = model.historyState(game: gameID, productID: productID)
        // Read so the block follows every change of the history in memory.
        let _ = model.historyVersions[gameID]
        let chart = chart(state: state)
        let note = chart == nil ? PriceChart.note(for: state) : chart?.note
        VStack(alignment: .leading, spacing: Theme.lineGap) {
            // The control only while the finish decides what the block shows: a chart or its per-finish sentence.
            heading(control: chart != nil, spoken: chart?.summary == nil)
            if let chart, let summary = chart.summary {
                summaryLine(chart: chart, summary: summary)
                    .padding(.bottom, 8)
                    .accessibilitySortPriority(1)
                plot(chart)
                    .accessibilitySortPriority(2)
            } else {
                frame(note: note)
                    .padding(.top, 4)
            }
            // Phase 5B task 5 (A33): while days of the window are missing, under the plot or the frame.
            if state != .unknown, let line = model.backfillLine {
                downloadLine(line.text, button: line.button)
                    .padding(.top, 8 - Theme.lineGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("price-history")
        // A38: the first choice is taken once, when the page's counts are known, and kept for this printing (the page
        // gives each printing its own block): a `+` on another finish does not switch the chart by itself.
        .onChange(of: state != .unknown, initial: true) { _, known in
            if known, picked == nil { picked = PriceChart.firstFinish(offered: finishes, owned: owned) }
        }
        // The read of the day files (off the main actor; nothing when they are read for this key already).
        .task(id: readKey) { await model.readDayPrices(game: gameID, productID: productID) }
    }

    /// What the printing's day-file prices are read under: a day file added, or the window moved, reads them again.
    private var readKey: String {
        "\(gameID)|\(productID)|\(model.priceDaysVersion)|\(PriceDay.wanted(now: model.now()))"
    }

    // MARK: Parts

    /// "Price history" and, with `control`, the finish control: beside the heading when the row fits the column, else
    /// under it, else as a menu. A form that does not fit is never drawn, so the column (and the window) keeps its width.
    /// With a chart the heading is not read by VoiceOver: the plot's label begins with it.
    @ViewBuilder private func heading(control: Bool, spoken: Bool) -> some View {
        let title = Text("Price history")
            .font(Theme.labelFont)
            .foregroundStyle(Theme.muted)
            .accessibilityHidden(!spoken)
        Group {
            if control, finishes.count > 1, let finish {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title
                        Spacer(minLength: 8)
                        finishPicker(finish, style: .segmented)
                    }
                    VStack(alignment: .leading, spacing: Theme.lineGap) {
                        title
                        finishPicker(finish, style: .segmented)
                    }
                    HStack(spacing: 8) {
                        title
                        Spacer(minLength: 8)
                        finishPicker(finish, style: .menu)
                    }
                }
            } else {
                title.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The control keeps the row's height whether it is there or not, so the block does not move between printings.
        .frame(minHeight: 22)
    }

    private enum PickerForm { case segmented, menu }

    @ViewBuilder private func finishPicker(_ finish: String, style: PickerForm) -> some View {
        let picker = Picker("Finish", selection: Binding(get: { finish }, set: { picked = $0 })) {
            ForEach(finishes, id: \.self) { Text($0).tag($0) }
        }
        Group {
            switch style {
            case .segmented: picker.pickerStyle(.segmented)
            case .menu: picker.pickerStyle(.menu)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        // Not the accent (the selection mark of the sidebar and a sheet's default button only).
        .tint(Theme.faint)
        .fixedSize()
        .accessibilityIdentifier("price-history-finish")
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

    /// The line of the 90-day download: its sentence in 12 pt `muted` and, before the yes, the button that opens the
    /// dialog (beside the sentence when the row fits the column, else under it). The model says what it says.
    @ViewBuilder private func downloadLine(_ text: String, button: Bool) -> some View {
        let sentence = Text(text)
            .font(Theme.lineFont)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("price-history-download-note")
        if button {
            let download = Button(MissingDays.buttonTitle) { model.askBackfill() }
                .buttonStyle(FieldButtonStyle())
                .fixedSize()
                .accessibilityIdentifier("price-history-download")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sentence.fixedSize()
                    Spacer(minLength: 8)
                    download
                }
                VStack(alignment: .leading, spacing: Theme.lineGap) {
                    sentence
                    download
                }
            }
        } else {
            sentence
        }
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
            .accessibilityLabel(note ?? "")
            .accessibilityHidden(note == nil)
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
                            guard let anchor = proxy.plotFrame,
                                  let date = proxy.value(atX: location.x - geometry[anchor].origin.x, as: Date.self)
                            else { return }
                            // The nearest day with a price: written only when it changes, so the block is not drawn
                            // again for every point the pointer crosses.
                            let day = chart.nearest(to: date)?.date
                            if day != pointer { pointer = day }
                        case .ended:
                            if pointer != nil { pointer = nil }
                        }
                    }
            }
        }
        #if os(iOS)
        .chartXSelection(value: $pointer)
        #endif
        .frame(height: Theme.chartHeight)
        // A plot replaced by a state's frame under the pointer gets no `.ended`: its readout must not come back with it.
        .onDisappear { pointer = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("price-history-chart")
    }

    private func axisText(_ label: String) -> some View {
        Text(label)
            .font(Theme.labelFont)
            .foregroundStyle(Theme.faint)
            .monospacedDigit()
    }

    /// The plot's label for VoiceOver, read before the summary line (sort priority): "Price history, Normal", then the
    /// summary reads "$12.40  +$1.20 in 90 days" (or the day under the pointer). The heading is not read beside a chart.
    private var spoken: String {
        ["Price history", finish].compactMap { $0 }.joined(separator: ", ")
    }

    /// The chart of the shown finish, for ready points; nil in every other state.
    private func chart(state: HistoryState) -> PriceChart? {
        guard state == .ready, let finish,
              let points = model.dayPoints(game: gameID, productID: productID, finish: finish) else { return nil }
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: model.now()))
        return PriceChart(points: points, window: window)
    }
}
