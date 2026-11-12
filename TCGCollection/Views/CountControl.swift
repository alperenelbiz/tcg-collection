import SwiftUI

/// `−`, the count, `+` on one `raised` field: how many copies of one printing in one finish the user owns. Tabular
/// digits, no accent. `−` is disabled at 0. `set` gets the new count (the shown count ± 1); a parent's `.disabled` turns
/// both buttons off. Identifiers: `count-minus-<label>`, `count-value-<label>`, `count-plus-<label>` (a label with spaces,
/// such as `1st Edition`, keeps them).
struct CountControl: View {
    let count: Int
    let label: String
    let set: (Int) -> Void

    /// The width of the number, so the field keeps its size from 0 to 99.
    private static let numberWidth: CGFloat = 28

    init(count: Int, label: String, set: @escaping (Int) -> Void) {
        self.count = count
        self.label = label
        self.set = set
    }

    var body: some View {
        HStack(spacing: 0) {
            step("−", name: "Remove one \(label)", identifier: "count-minus-\(label)", to: count - 1)
                .disabled(count == 0)
            Text("\(count)")
                .foregroundStyle(Theme.text)
                .frame(minWidth: Self.numberWidth)
                .accessibilityIdentifier("count-value-\(label)")
            step("+", name: "Add one \(label)", identifier: "count-plus-\(label)", to: count + 1)
        }
        .font(Theme.bodyFont)
        .monospacedDigit()
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.pictureRadius))
        .fixedSize()
    }

    private func step(_ symbol: String, name: String, identifier: String, to value: Int) -> some View {
        Button { set(value) } label: { Text(symbol) }
            .buttonStyle(StepStyle())
            .accessibilityLabel(name)
            .accessibilityIdentifier(identifier)
    }
}

/// A `−` or `+` of `CountControl`: the symbol in `text` on the field, `faint` when disabled, dimmed while pressed. No fill
/// of its own and no accent: the field is the control.
private struct StepStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.text : Theme.faint)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }
}
