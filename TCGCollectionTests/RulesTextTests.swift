import Testing
@testable import TCGCollection2

struct RulesTextTests {
    @Test func plainTextFromMarkup() {
        #expect(RulesText.plain("[DEPLOY] <em>(Play this only to a battlefield.)</em><br>Draw 1.") == "[DEPLOY] (Play this only to a battlefield.)\nDraw 1.")
        #expect(RulesText.plain("Fire &amp; Ice &quot;x&quot; &lt;3") == "Fire & Ice \"x\" <3")
        #expect(RulesText.plain("a\r\n\r\n\r\nb") == "a\n\nb"); #expect(RulesText.plain("") == "")
    }
}
