import Testing
@testable import TCGCollection2

struct CardKindTests {
    private let magic = Games.game("magic-the-gathering")!, yugioh = Games.game("yu-gi-oh")!
    private let riftbound = Games.game("riftbound")!, cyberpunk = Games.game("cyberpunk")!

    /// The group and the default section of a card in the game's first format (or the named one).
    private func place(_ game: GameDefinition, _ type: String, ygo: String? = nil, format: String = "standard") -> String {
        let kind = game.kind(cardType: type, ygoType: ygo)
        return "\(kind.group)|\(game.defaultSection(format: game.format(format), kind: kind))"
    }

    // MARK: Yu-Gi-Oh!

    @Test func yugiohFrameTypesOfTheExtraDeck() {
        for frame in ["fusion", "synchro", "xyz", "link", "fusion_pendulum", "synchro_pendulum", "xyz_pendulum"] {
            #expect(place(yugioh, "Effect Monster", ygo: frame) == "Monsters|extra", "\(frame)")
            #expect(yugioh.kind(cardType: "", ygoType: frame).flags == [CardKind.extraDeck])
        }
    }

    @Test func yugiohFrameTypesOfTheMainDeck() {
        #expect(place(yugioh, "", ygo: "effect") == "Monsters|main")
        #expect(place(yugioh, "", ygo: "normal") == "Monsters|main")
        #expect(place(yugioh, "", ygo: "ritual") == "Monsters|main")
        #expect(place(yugioh, "", ygo: "effect_pendulum") == "Monsters|main")
        #expect(place(yugioh, "", ygo: "normal_pendulum") == "Monsters|main")
        #expect(place(yugioh, "", ygo: "spell") == "Spells|main")
        #expect(place(yugioh, "", ygo: "trap") == "Traps|main")
        #expect(place(yugioh, "", ygo: "token") == "Other|main")
        #expect(place(yugioh, "", ygo: "skill") == "Other|main")
        #expect(yugioh.kind(cardType: "", ygoType: "effect").flags.isEmpty)
    }

    /// A15: the YGOPRODeck type wins over the TCGplayer type.
    @Test func theYGOPRODeckTypeComesFirst() {
        #expect(place(yugioh, "Effect Monster", ygo: "xyz") == "Monsters|extra")
        #expect(place(yugioh, "Xyz/Effect Monster", ygo: "effect") == "Monsters|main")
        #expect(place(yugioh, "Normal Spell", ygo: "SPELL") == "Spells|main")
    }

    @Test func withoutAYGOPRODeckTypeTheTCGplayerTypeDecides() {
        #expect(place(yugioh, "Xyz/Effect Monster") == "Monsters|extra")
        #expect(place(yugioh, "Xyz/Effect Monster", ygo: "") == "Monsters|extra")
        #expect(place(yugioh, "Xyz/Effect Monster", ygo: "something_new") == "Monsters|extra")
        #expect(place(yugioh, "Fusion Monster") == "Monsters|extra")
        #expect(place(yugioh, "Synchro/Tuner/Effect Monster") == "Monsters|extra")
        #expect(place(yugioh, "Effect Link Monster") == "Monsters|extra")
        #expect(place(yugioh, "Effect Tuner Synchro Monster") == "Monsters|extra")
        #expect(place(yugioh, "Fusion/Pendulum/Effect Monster") == "Monsters|extra")
        #expect(place(yugioh, "Effect Monster") == "Monsters|main")
        #expect(place(yugioh, "Ritual/Effect Monster") == "Monsters|main")
        #expect(place(yugioh, "Pendulum/Normal Monster") == "Monsters|main")
        #expect(place(yugioh, "Spell Card") == "Spells|main")
        #expect(place(yugioh, "Quick-Play Spell") == "Spells|main")
        #expect(place(yugioh, "Ritual Spell") == "Spells|main")
        #expect(place(yugioh, "Trap Card") == "Traps|main")
        #expect(place(yugioh, "Counter Trap") == "Traps|main")
        #expect(place(yugioh, "Token") == "Other|main")
        #expect(place(yugioh, "Token Monster") == "Other|main")
        #expect(place(yugioh, "Skill") == "Other|main")
        #expect(place(yugioh, "Yami Yugi/Skill") == "Other|main")
    }

    // MARK: Riftbound

    @Test func riftboundTypes() {
        #expect(place(riftbound, "Legend") == "Legends|legend")
        #expect(place(riftbound, "Rune") == "Runes|runes")
        #expect(place(riftbound, "Battlefield") == "Battlefields|battlefields")
        #expect(place(riftbound, "Champion Unit") == "Units|main")
        #expect(place(riftbound, "Unit") == "Units|main")
        #expect(place(riftbound, "Signature Unit") == "Units|main")
        #expect(place(riftbound, "Spell") == "Spells|main")
        #expect(place(riftbound, "Signature Spell") == "Spells|main")
        #expect(place(riftbound, "Gear") == "Gear|main")
        #expect(place(riftbound, "Signature Gear") == "Gear|main")
        #expect(place(riftbound, "Unit;Gear") == "Units|main")
        #expect(riftbound.kind(cardType: "Champion Unit", ygoType: nil).flags == [CardKind.champion])
        #expect(riftbound.kind(cardType: "Legend", ygoType: nil).flags == [CardKind.legend])
        #expect(riftbound.kind(cardType: "Rune", ygoType: nil).flags == [CardKind.rune])
        #expect(riftbound.kind(cardType: "Battlefield", ygoType: nil).flags == [CardKind.battlefield])
    }

    @Test func riftboundTokensAreOther() {
        #expect(place(riftbound, "Unit;Token") == "Other|main")
        #expect(place(riftbound, "Unit;Battlefield;Token") == "Other|main")
        #expect(riftbound.kind(cardType: "Gear;Battlefield;Token", ygoType: nil).flags.isEmpty)
    }

    // MARK: Magic

    @Test func magicGroupsComeFromTheCardTypes() {
        for format in ["commander", "constructed"] {
            #expect(place(magic, "Legendary Creature — Human Wizard", format: format) == "Creatures|deck")
            #expect(place(magic, "Basic Land — Forest", format: format) == "Lands|deck")
            #expect(place(magic, "Instant", format: format) == "Instants|deck")
        }
        #expect(place(magic, "Sorcery") == "Sorceries|deck")
        #expect(place(magic, "Artifact — Equipment") == "Artifacts|deck")
        #expect(place(magic, "Enchantment — Aura") == "Enchantments|deck")
        #expect(place(magic, "Legendary Planeswalker — Chandra") == "Planeswalkers|deck")
        #expect(place(magic, "Kindred Instant — Goblin") == "Instants|deck")
        #expect(place(magic, "Summon Wall") == "Creatures|deck")
        #expect(place(magic, "Battle — Siege") == "Other|deck")
        #expect(magic.kind(cardType: "Land", ygoType: nil).flags == [CardKind.land])
        #expect(magic.kind(cardType: "Creature — Elf", ygoType: nil).flags.isEmpty)
    }

    /// A card of two types takes the first of: Land, Creature, Planeswalker, Instant, Sorcery, Artifact, Enchantment.
    @Test func magicPriorityForACardOfTwoTypes() {
        #expect(magic.kind(cardType: "Artifact Creature — Golem", ygoType: nil).group == "Creatures")
        #expect(magic.kind(cardType: "Enchantment Creature — God", ygoType: nil).group == "Creatures")
        #expect(magic.kind(cardType: "Land Creature — Forest Dryad", ygoType: nil).group == "Lands")
        #expect(magic.kind(cardType: "Artifact Land", ygoType: nil).group == "Lands")
        #expect(magic.kind(cardType: "Legendary Artifact Creature — Construct", ygoType: nil).group == "Creatures")
        #expect(magic.kind(cardType: "Legendary Enchantment Creature — Planeswalker", ygoType: nil).group == "Creatures")
        #expect(magic.kind(cardType: "Kindred Artifact — Elf", ygoType: nil).group == "Artifacts")
        #expect(magic.kind(cardType: "Enchantment Artifact", ygoType: nil).group == "Artifacts")
    }

    /// A card of two faces is grouped by its front face; a split card's halves agree.
    @Test func magicFrontFaceDecides() {
        #expect(magic.kind(cardType: "Creature — Giant // Sorcery — Adventure", ygoType: nil).group == "Creatures")
        #expect(magic.kind(cardType: "Creature — Human // Land", ygoType: nil).group == "Creatures")
        #expect(magic.kind(cardType: "Sorcery // Land", ygoType: nil).group == "Sorceries")
        #expect(magic.kind(cardType: "Instant // Instant", ygoType: nil).group == "Instants")
    }

    // MARK: Cyberpunk

    @Test func cyberpunkTypes() {
        #expect(place(cyberpunk, "Legend") == "Legends|legends")
        #expect(place(cyberpunk, "Unit") == "Units|main")
        #expect(place(cyberpunk, "Program") == "Programs|main")
        #expect(place(cyberpunk, "Gear") == "Gear|main")
        #expect(cyberpunk.kind(cardType: "Legend", ygoType: nil).flags == [CardKind.legend])
    }

    // MARK: Unknown types

    @Test func anUnknownOrEmptyTypeIsOtherInTheFirstCountedSection() {
        #expect(place(yugioh, "") == "Other|main"); #expect(place(yugioh, "Field Center") == "Other|main")
        #expect(place(riftbound, "") == "Other|main"); #expect(place(riftbound, "None") == "Other|main")
        #expect(place(magic, "", format: "commander") == "Other|deck")
        #expect(place(magic, "Scheme", format: "constructed") == "Other|deck")
        #expect(place(cyberpunk, "  ") == "Other|main"); #expect(place(cyberpunk, "Hacker") == "Other|main")
        #expect(yugioh.kind(cardType: "", ygoType: nil) == CardKind(group: CardKind.other, flags: []))
    }

    /// A flag whose section the format lacks falls back to the first counted section; the user moves the card.
    @Test func aFlagOnlyPicksASectionTheFormatHas() {
        let legendFormat = DeckFormat(id: "x", name: "X",
                                      sections: [DeckSection(id: "main", name: "Main Deck", min: nil, max: nil, byHandOnly: false)],
                                      copyLimit: nil, countedSections: ["main"])
        #expect(riftbound.defaultSection(format: legendFormat, kind: CardKind(group: "Legends", flags: [CardKind.legend])) == "main")
    }

    @Test func flagNamesAreConstants() {
        #expect([CardKind.extraDeck, CardKind.legend, CardKind.rune, CardKind.battlefield, CardKind.champion, CardKind.land]
                == ["extraDeck", "legend", "rune", "battlefield", "champion", "land"])
        #expect(CardKind.other == "Other")
    }

    // MARK: One kind per card for every deck place (phase 3A task 6, fix round 1)

    /// `CardKinds.deckKind`: the first printing in the catalog's order with a card type decides; all untyped → the first
    /// printing's (empty) type, so Other for a game without YGOPRODeck types; Yu-Gi-Oh! takes its YGOPRODeck type first,
    /// another game never asks for one.
    @Test func oneKindPerCardFromItsFirstTypedPrinting() {
        let none: (String) -> String? = { _ in nil }
        // The cover (newest) has no card type; an older printing has one.
        let promo = product(id: 1, game: "yu-gi-oh", name: "Stardust Dragon")
        let old = product(id: 2, game: "yu-gi-oh", name: "Stardust Dragon", cardType: "Synchro Monster")
        #expect(CardKinds.deckKind(game: yugioh, printings: [promo, old], ygoType: none)?.flags == [CardKind.extraDeck])
        let rune = product(id: 3, name: "Calm Rune (R02a)", cardType: "Rune")
        #expect(CardKinds.deckKind(game: riftbound, printings: [product(id: 4, name: "Calm Rune (R02b)"), rune], ygoType: none)
                == riftbound.kind(cardType: "Rune", ygoType: nil))
        // Every printing untyped: Other, which goes to the format's first counted section that is not by hand only.
        let untyped = CardKinds.deckKind(game: riftbound, printings: [product(id: 5, name: "X"), product(id: 6, name: "X")],
                                         ygoType: none)
        #expect(untyped == CardKind(group: CardKind.other, flags: []))
        #expect(riftbound.defaultSection(format: riftbound.format("standard"), kind: untyped!) == "main")
        #expect(CardKinds.deckKind(game: riftbound, printings: [], ygoType: none) == nil)
        // Yu-Gi-Oh!: the YGOPRODeck type of the card name first, with or without a typed printing.
        var asked: [String] = []
        let synchro: (String) -> String? = { asked.append($0); return "synchro" }
        let effect = product(id: 7, game: "yu-gi-oh", name: "Y", cardType: "Effect Monster")
        #expect(CardKinds.deckKind(game: yugioh, printings: [effect], ygoType: synchro)?.flags == [CardKind.extraDeck])
        #expect(CardKinds.deckKind(game: yugioh, printings: [promo], ygoType: synchro)?.flags == [CardKind.extraDeck])
        #expect(CardKinds.deckKind(game: yugioh, printings: [effect], ygoType: none)?.flags == [])
        #expect(asked == ["Y", "Stardust Dragon"])
        // Another game never asks for a YGOPRODeck type, whatever the lookup would say.
        asked = []
        #expect(CardKinds.deckKind(game: riftbound, printings: [rune], ygoType: synchro) == riftbound.kind(cardType: "Rune", ygoType: nil))
        #expect(CardKinds.deckKind(game: magic, cardType: "Instant", cardName: "Bolt", ygoType: synchro).group == "Instants")
        #expect(asked.isEmpty)
    }
}
