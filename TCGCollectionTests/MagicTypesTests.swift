import Testing
@testable import TCGCollection2

struct MagicTypesTests {
    @Test func modernLines() {
        #expect(MagicTypes.facets("Legendary Creature — Human Officer") == ["Creature"])
        #expect(MagicTypes.facets("Artifact Creature — Golem") == ["Artifact", "Creature"])
        #expect(MagicTypes.facets("Basic Snow Land — Forest") == ["Land"])
        #expect(MagicTypes.facets("Kindred Instant — Goblin") == ["Instant", "Kindred"])
        #expect(MagicTypes.facets("Legendary Planeswalker — Chandra") == ["Planeswalker"])
    }
    @Test func oldWordsMap() {
        #expect(MagicTypes.facets("Summon Wall") == ["Creature"]); #expect(MagicTypes.facets("Enchant Creature") == ["Enchantment"])
        #expect(MagicTypes.facets("Summon Artifact Creature") == ["Creature"])
        #expect(MagicTypes.facets("Interrupt") == ["Instant"]); #expect(MagicTypes.facets("Mana Source") == ["Instant"])
        #expect(MagicTypes.facets("Mono Artifact") == ["Artifact"]); #expect(MagicTypes.facets("Tribal Sorcery — Elf") == ["Kindred", "Sorcery"])
    }
    @Test func splitCardsAndJunk() {
        #expect(MagicTypes.facets("Instant // Sorcery") == ["Instant", "Sorcery"])
        #expect(MagicTypes.facets("Creature — Human // Land") == ["Creature", "Land"])
        #expect(MagicTypes.facets("Creature - Goblin") == ["Creature"]); #expect(MagicTypes.facets("Creature – Goblin") == ["Creature"])
        #expect(MagicTypes.facets("Eaturecray — Igpay") == []); #expect(MagicTypes.facets("//") == []); #expect(MagicTypes.facets("") == [])
        #expect(MagicTypes.all.count == 15)
    }
    @Test func slashAndCaseAndRepeats() {
        #expect(MagicTypes.facets("artifact/creature — golem") == ["Artifact", "Creature"])
        #expect(MagicTypes.facets("Creature Creature") == ["Creature"])
        #expect(MagicTypes.facets("Enchant Artifact") == ["Enchantment"])
    }
}
