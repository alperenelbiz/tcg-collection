import SwiftUI
import Testing
@testable import TCGCollection2

struct ThemeTests {
    @Test func hexColours() {
        // `242.0`, not `242`: inside `#expect` a literal division is typed on its own, as Int (242 / 255 == 0).
        let amber = Theme.rgb(hex: "#F2B33D")!, ground = Theme.rgb(hex: "0F0F10")!
        #expect(amber.red == 242.0 / 255); #expect(amber.green == 179.0 / 255); #expect(amber.blue == 61.0 / 255)
        #expect(ground.red == 15.0 / 255); #expect(ground.green == 15.0 / 255); #expect(ground.blue == 16.0 / 255)
        #expect(Theme.rgb(hex: "#12") == nil); #expect(Theme.rgb(hex: "#GGGGGG") == nil)
    }

    @Test func textOnGroundIsReadable() {                                    // 4.5:1, the house floor
        func contrast(_ a: String, _ b: String) -> Double { Theme.contrast(Theme.rgb(hex: a)!, Theme.rgb(hex: b)!) }
        #expect(contrast("#FFFFFF", "#0F0F10") > 15); #expect(contrast("#B4B4B4", "#0F0F10") > 4.5); #expect(contrast("#949494", "#0F0F10") > 4.5)
        #expect(contrast("#949494", "#1A1A1B") > 4.5); #expect(contrast("#F2B33D", "#0F0F10") > 4.5)
    }

    /// The token table of "The look, as rules", value by value: a token is never softened by accident.
    @Test func theTokensAreTheTable() {
        #expect(Theme.ground == Color(hex: "#0F0F10")); #expect(Theme.surface == Color(hex: "#1A1A1B"))
        #expect(Theme.raised == Color(hex: "#2A2A2B")); #expect(Theme.rule == Color(hex: "#232324"))
        #expect(Theme.text == Color(hex: "#FFFFFF")); #expect(Theme.muted == Color(hex: "#B4B4B4"))
        #expect(Theme.faint == Color(hex: "#949494")); #expect(Theme.accent == Color(hex: "#F2B33D"))
        #expect(Theme.risk == Color(hex: "#E5484D"))
        #expect(Theme.ground != Theme.surface)                                  // Color equality compares values
        #expect(Theme.cellMinWidth == 150); #expect(Theme.rowGap == 18)
        #expect(Theme.pictureRadius == 6); #expect(Theme.largePictureRadius == 12)
        #expect(Theme.ruleSpacing == 14); #expect(Theme.sidebarIconSize == 16)
        #expect(Theme.pageTitleFont == .system(size: 22, weight: .semibold))
        #if os(macOS)
        // The iPhone's values of these tokens: `thePhoneSizes` (phase 6A).
        #expect(Theme.columnGap == 16); #expect(Theme.margin == 18)
        #expect(Theme.bodyFont == .system(size: 13))
        #expect(Theme.lineFont == .system(size: 12)); #expect(Theme.labelFont == .system(size: 11))
        #endif
        #expect(Theme.sheetTitleFont == .system(size: 17, weight: .semibold))
        #expect(Theme.sheetTitleFont != Theme.pageTitleFont)                    // Font equality compares values
    }

    /// The price chart's tokens (phase 5A, "The look of the new part").
    @Test func theChartTokens() {
        #expect(Theme.chartLineWidth == 2); #expect(Theme.chartDot == 6)
        #if os(macOS)
        #expect(Theme.chartHeight == 132)                                       // the iPhone's: 180, `thePhoneSizes`
        #endif
    }

    #if os(macOS)
    /// Phase 6A task 6: the phone's sizes are iOS values; the Mac's stay as they were.
    @MainActor @Test func theMacSizesDoNotChange() {
        #expect(Theme.margin == 18); #expect(Theme.columnGap == 16); #expect(CountControl.height == 22)
        #expect(Theme.chartHeight == 132)
        #expect(Theme.bodyFont == .system(size: 13)); #expect(Theme.lineFont == .system(size: 12))
        #expect(Theme.labelFont == .system(size: 11)); #expect(Theme.sectionFont == .system(size: 13, weight: .semibold))
    }
    #endif

    #if os(iOS)
    /// Phase 6A task 6 ("The look on the iPhone"): 16 pt margins, a 12 pt gap, larger type, 44 pt touch targets and a
    /// 180 pt plot. The unit tests run on the Mac: this one compiles in the iPhone build (the phone UI tests check the
    /// 44 pt and 180 pt on screen).
    @MainActor @Test func thePhoneSizes() {
        #expect(Theme.margin == 16); #expect(Theme.columnGap == 12); #expect(CountControl.height == 44)
        #expect(Theme.chartHeight == 180)
        #expect(Theme.bodyFont == .system(size: 15)); #expect(Theme.lineFont == .system(size: 13))
        #expect(Theme.labelFont == .system(size: 12)); #expect(Theme.sectionFont == .system(size: 15, weight: .semibold))
    }
    #endif

    #if os(macOS)
    /// The app's `AccentColor` asset (the sidebar's selection, the system's selection colours) is the accent token.
    @Test func theAccentAssetIsTheAccentToken() throws {
        let asset = try #require(NSColor(named: "AccentColor")?.usingColorSpace(.sRGB))
        let token = try #require(Theme.rgb(hex: "#F2B33D"))
        #expect(abs(asset.redComponent - token.red) < 0.002)
        #expect(abs(asset.greenComponent - token.green) < 0.002)
        #expect(abs(asset.blueComponent - token.blue) < 0.002)
    }
    #endif
}
