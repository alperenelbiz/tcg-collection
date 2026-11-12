import SwiftUI

/// The look ("The look, as rules", phase 2B plan): flat colours on a dark ground, card pictures as the lead, one warm
/// accent, red only for risk. No gradient, no shadow at rest, no custom glass: the glass is the system's (toolbar,
/// sidebar). Every view takes its colours, sizes and type from here; a view has no literal colour of its own.
nonisolated enum Theme {
    // MARK: Colours

    /// Every content background: gallery, card page, sheets' content.
    static let ground = Color(hex: "#0F0F10")
    /// A hovered cell, a picture placeholder, a sheet row on hover.
    static let surface = Color(hex: "#1A1A1B")
    /// A pressed state, the count control's field.
    static let raised = Color(hex: "#2A2A2B")
    /// 1 px rules between groups; never a box around a card.
    static let rule = Color(hex: "#232324")
    /// Names, values.
    static let text = Color(hex: "#FFFFFF")
    /// Counts, set · rarity · number lines, labels.
    static let muted = Color(hex: "#B4B4B4")
    /// Meta, placeholders, the status line.
    static let faint = Color(hex: "#949494")
    /// The selected sidebar row, the selection ring of a cell, the default button of a sheet. Nowhere else.
    static let accent = Color(hex: "#F2B33D")
    /// Only on a fact at risk (a row the import would remove). Never on a normal row.
    static let risk = Color(hex: "#E5484D")

    // MARK: Sizes (points)

    /// The gallery: adaptive columns of at least this width.
    static let cellMinWidth: CGFloat = 150
    static let columnGap: CGFloat = 16
    static let rowGap: CGFloat = 18
    /// The gallery's outer margin.
    static let margin: CGFloat = 18
    /// A picture in the gallery (59:86).
    static let pictureRadius: CGFloat = 6
    /// The large picture of the card page.
    static let largePictureRadius: CGFloat = 12
    /// Above and below a 1 px rule between groups.
    static let ruleSpacing: CGFloat = 14
    /// The square a sidebar row's outline icon is fitted into.
    static let sidebarIconSize: CGFloat = 16

    // MARK: Type (the system face only; the window title is the system's)

    /// The card page's title.
    static let pageTitleFont = Font.system(size: 22, weight: .semibold)
    /// A sheet's title.
    static let sheetTitleFont = Font.system(size: 17, weight: .semibold)
    /// A card name in the gallery, values, sentences.
    static let bodyFont = Font.system(size: 13)
    /// The line under a card name; a screen's totals line.
    static let lineFont = Font.system(size: 12)
    /// Labels over values, the status line. Nothing is smaller.
    static let labelFont = Font.system(size: 11)

    // MARK: Colour arithmetic

    /// `#RRGGBB` or `RRGGBB` as sRGB components from 0 to 1; nil for any other text.
    static func rgb(hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// The WCAG 2 contrast ratio of two sRGB colours, from 1 to 21.
    static func contrast(_ a: (red: Double, green: Double, blue: Double),
                         _ b: (red: Double, green: Double, blue: Double)) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (red: Double, green: Double, blue: Double)) -> Double {
            0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

nonisolated extension Color {
    /// A flat sRGB colour from `#RRGGBB`. Only for the literal tokens of `Theme`: a wrong literal stops the app at once.
    init(hex: String) {
        guard let c = Theme.rgb(hex: hex) else { preconditionFailure("not a #RRGGBB colour: \(hex)") }
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}

extension View {
    /// The default button of a sheet (Return): a flat `accent` button with a `ground` label. The system's default button
    /// draws a white label on the accent, which reads at under 2:1 on amber, and on macOS 27 it ignores a label colour.
    func sheetDefaultButton() -> some View {
        keyboardShortcut(.defaultAction)
            .buttonStyle(AccentButtonStyle())
    }
}

/// The system push button's size (24 pt high, 13 pt label, 12 pt sides, 6 pt corners), flat: `accent` fill, `ground`
/// label. Only for the default button of a sheet (`sheetDefaultButton`).
private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentButton(label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// The states of `AccentButtonStyle`: hovered 0.9 and pressed 0.8 opacity of the fill; in an inactive window `raised` with
/// a `muted` label, as a system default button loses its colour there; disabled at 0.4.
private struct AccentButton: View {
    let label: ButtonStyleConfiguration.Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    #endif
    @State private var hovering = false

    private static let shape = RoundedRectangle(cornerRadius: 6)

    private var windowIsActive: Bool {
        #if os(macOS)
        activeState != .inactive
        #else
        true
        #endif
    }

    var body: some View {
        label
            .font(Theme.bodyFont)
            .foregroundStyle(windowIsActive ? Theme.ground : Theme.muted)
            .padding(.horizontal, 12)
            .frame(minHeight: 24)
            .background((windowIsActive ? Theme.accent : Theme.raised).opacity(isPressed ? 0.8 : hovering ? 0.9 : 1),
                        in: Self.shape)
            .opacity(isEnabled ? 1 : 0.4)
            // Clicks, hover and the keyboard focus ring follow the rounded fill, not a rectangle around it.
            .contentShape(Self.shape)
            .onHover { hovering = $0 }
    }
}

/// A 1 px `rule` between two groups, with `ruleSpacing` above and below. Rules instead of boxes.
struct RuleLine: View {
    var body: some View {
        Theme.rule
            .frame(height: 1)
            .padding(.vertical, Theme.ruleSpacing)
            .accessibilityHidden(true)
    }
}

/// An empty or failed screen: the title and toolbar stay; in the middle one sentence in `muted` and at most two
/// buttons (`actions`). No picture, no icon in a circle.
struct EmptyMessage<Actions: View>: View {
    let sentence: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Text(sentence)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.muted)
            actions
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(Theme.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyMessage where Actions == EmptyView {
    init(sentence: String) {
        self.init(sentence: sentence) { EmptyView() }
    }
}
