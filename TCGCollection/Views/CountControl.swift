import SwiftUI

/// `−`, the count, `+` on one `raised` field: how many copies of one printing in one finish the user owns, or has for sale.
/// Tabular digits, no accent. `−` is disabled at 0, `+` at `maximum` (For Sale: the owned count). A nil count (not known:
/// the game's file is refused or not read yet) shows `—` and turns both buttons off. `set` gets the new count (the shown
/// count ± 1); a parent's `.disabled` turns both off too.
/// Identifiers: `<prefix>-minus-<key>`, `<prefix>-value-<key>`, `<prefix>-plus-<key>`; by default `count-…-<label>` (a
/// label with spaces, such as `1st Edition`, keeps them); an empty key gives `<prefix>-minus` (the card page's Wanted
/// control: `wanted-minus`). VoiceOver reads "Remove one <label>" and "Add one <label>", or `spoken` when given (Wanted:
/// "Want one fewer", "Want one more").
struct CountControl: View {
    let count: Int?
    let label: String
    let maximum: Int?
    let prefix: String
    let key: String
    /// What VoiceOver reads for `−` and `+`; nil: "Remove one <label>", "Add one <label>".
    let spoken: (remove: String, add: String)?
    let set: (Int) -> Void

    /// The field's height; a text button beside it (`FieldButtonStyle`) has the same. The iPhone: 44 pt, a touch target
    /// (its `−` and `+` are 44 × 44 pt there).
    #if os(iOS)
    static let height: CGFloat = 44
    #else
    static let height: CGFloat = 22
    #endif
    /// The width of a `−` or `+`: 44 pt on the iPhone, a square touch target.
    #if os(iOS)
    static let stepWidth: CGFloat = 44
    #else
    static let stepWidth: CGFloat = 24
    #endif
    /// The width of the number, so the field keeps its size from 0 to 99.
    private static let numberWidth: CGFloat = 28

    init(count: Int?, label: String, maximum: Int? = nil, prefix: String = "count", key: String? = nil,
         spoken: (remove: String, add: String)? = nil, set: @escaping (Int) -> Void) {
        self.count = count
        self.label = label
        self.maximum = maximum
        self.prefix = prefix
        self.key = key ?? label
        self.spoken = spoken
        self.set = set
    }

    var body: some View {
        let suffix = key.isEmpty ? "" : "-\(key)"
        HStack(spacing: 0) {
            step("−", name: spoken?.remove ?? "Remove one \(label)", identifier: "\(prefix)-minus\(suffix)", to: (count ?? 0) - 1)
                .disabled((count ?? 0) == 0)
            Text(count.map(String.init) ?? "—")
                .foregroundStyle(Theme.text)
                .frame(minWidth: Self.numberWidth)
                .accessibilityIdentifier("\(prefix)-value\(suffix)")
            step("+", name: spoken?.add ?? "Add one \(label)", identifier: "\(prefix)-plus\(suffix)", to: (count ?? 0) + 1)
                .disabled(count == nil || maximum.map { (count ?? 0) >= $0 } == true)
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
            .frame(width: CountControl.stepWidth, height: CountControl.height)
            .contentShape(Rectangle())
    }
}

/// A text button beside a `CountControl` (For Sale's "Sold"): its label in `text` on a `raised` field as high as the
/// control, `faint` when disabled, dimmed while pressed. No border, no badge, no accent.
struct FieldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyFont)
            .foregroundStyle(isEnabled ? Theme.text : Theme.faint)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.horizontal, 10)
            #if os(iOS)
            // At least a touch target; a label that wraps makes it taller.
            .frame(minHeight: CountControl.height)
            #else
            .frame(height: CountControl.height)
            #endif
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.pictureRadius))
            .contentShape(RoundedRectangle(cornerRadius: Theme.pictureRadius))
    }
}
