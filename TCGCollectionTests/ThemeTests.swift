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
        #expect(Theme.cellMinWidth == 150); #expect(Theme.columnGap == 16); #expect(Theme.rowGap == 18)
        #expect(Theme.margin == 18); #expect(Theme.pictureRadius == 6); #expect(Theme.largePictureRadius == 12)
        #expect(Theme.ruleSpacing == 14); #expect(Theme.sidebarIconSize == 16)
        #expect(Theme.pageTitleFont == .system(size: 22, weight: .semibold)); #expect(Theme.bodyFont == .system(size: 13))
        #expect(Theme.lineFont == .system(size: 12)); #expect(Theme.labelFont == .system(size: 11))
        #expect(Theme.sheetTitleFont == .system(size: 17, weight: .semibold))
        #expect(Theme.sheetTitleFont != Theme.pageTitleFont)                    // Font equality compares values
    }

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
