import Testing
@testable import TCGCollection2

/// The numbers here are the ones of `docs/deck-rules-sources.md` (read 2026-11-15); nil is a number
/// without an official source, or none in the rules.
struct DeckFormatTests {
    private let magic = Games.game("magic-the-gathering")!, yugioh = Games.game("yu-gi-oh")!
    private let riftbound = Games.game("riftbound")!, cyberpunk = Games.game("cyberpunk")!

    private func shape(_ format: DeckFormat) -> [String] {
        format.sections.map { "\($0.id)|\($0.name)|\($0.min.map(String.init) ?? "-")|\($0.max.map(String.init) ?? "-")|\($0.byHandOnly)" }
    }

    @Test func eachGameHasItsFormatsInOrder() {
        #expect(magic.formats.map(\.id) == ["commander", "constructed"])
        #expect(magic.formats.map(\.name) == ["Commander", "Constructed"])
        for game in [yugioh, riftbound, cyberpunk] {
            #expect(game.formats.map(\.id) == ["standard"]); #expect(game.formats.map(\.name) == ["Standard"])
        }
    }

    @Test func theSectionsAreTheSpecsTableInOrder() {
        #expect(yugioh.formats[0].sections.map(\.name) == ["Main Deck", "Extra Deck", "Side Deck"])
        #expect(riftbound.formats[0].sections.map(\.name)
                == ["Legend", "Champion", "Main Deck", "Runes", "Battlefields", "Sideboard"])
        #expect(magic.format("commander").sections.map(\.name) == ["Commander", "Deck"])
        #expect(magic.format("constructed").sections.map(\.name) == ["Deck", "Sideboard"])
        #expect(cyberpunk.formats[0].sections.map(\.name) == ["Legends", "Main Deck", "Side Deck"])
    }

    @Test func yugiohNumbers() {
        let format = yugioh.format("standard")
        #expect(shape(format) == ["main|Main Deck|40|60|false", "extra|Extra Deck|-|15|false", "side|Side Deck|-|15|true"])
        #expect(format.copyLimit == 3); #expect(format.countedSections == ["main", "extra", "side"])
    }

    @Test func magicNumbers() {
        let commander = magic.format("commander"), constructed = magic.format("constructed")
        // Commander: one commander, or two with a partner ability (CR 903.3, 702.124a/g); 100 cards with it (903.5a).
        #expect(shape(commander) == ["commander|Commander|1|2|true", "deck|Deck|-|-|false"])
        #expect(commander.totals == [DeckTotal(sections: ["commander", "deck"], min: 100, max: 100, name: "Commander deck")])
        #expect(commander.copyLimit == 1); #expect(commander.countedSections == ["commander", "deck"])
        #expect(shape(constructed) == ["deck|Deck|60|-|false", "sideboard|Sideboard|-|15|true"])
        #expect(constructed.copyLimit == 4); #expect(constructed.countedSections == ["deck", "sideboard"])
    }

    @Test func riftboundNumbers() {
        let format = riftbound.format("standard")
        // The Main Deck's 40 include the Chosen Champion (CR 103.3): a total over both sections, no bound on Main alone.
        #expect(shape(format) == ["legend|Legend|1|1|false", "champion|Champion|1|1|true", "main|Main Deck|-|-|false",
                                  "runes|Runes|12|12|false", "battlefields|Battlefields|3|3|false",
                                  "sideboard|Sideboard|-|10|true"])
        #expect(format.totals == [DeckTotal(sections: ["champion", "main"], min: 40, max: nil,
                                            name: "Main Deck with its Champion")])
        #expect(format.copyLimit == 3); #expect(format.countedSections == ["champion", "main", "sideboard"])
    }

    @Test func cyberpunkNumbers() {
        let format = cyberpunk.format("standard")
        #expect(shape(format) == ["legends|Legends|3|3|false", "main|Main Deck|40|50|false", "side|Side Deck|-|-|true"])
        #expect(format.copyLimit == 3); #expect(format.countedSections == ["main"])
    }

    @Test func onlyCommanderAndRiftboundHaveTotals() {
        #expect(yugioh.format("standard").totals.isEmpty); #expect(cyberpunk.format("standard").totals.isEmpty)
        #expect(magic.format("constructed").totals.isEmpty)
        for game in Games.all {
            for format in game.formats {
                for total in format.totals {
                    #expect(Set(total.sections).isSubset(of: Set(format.sections.map(\.id))), "\(game.id) \(format.id)")
                    #expect(total.min != nil || total.max != nil); #expect(!total.name.isEmpty)
                }
            }
        }
    }

    /// No section bound is an inference from a total any more: 98, 99 and 39 are nowhere.
    @Test func noDerivedBoundIsLeft() {
        let bounds = Games.all.flatMap(\.formats).flatMap(\.sections).flatMap { [$0.min, $0.max] }.compactMap { $0 }
        #expect(!bounds.contains(98)); #expect(!bounds.contains(99)); #expect(!bounds.contains(39))
    }

    @Test func aFormatWithoutTotalsDefaultsToNone() {
        #expect(DeckFormat(id: "x", name: "X", sections: [], copyLimit: nil, countedSections: []).totals.isEmpty)
    }

    @Test func everySideDeckAndSideboardAndTheChampionAreByHandOnly() {
        for game in Games.all {
            for format in game.formats {
                for section in format.sections where ["side", "sideboard", "champion"].contains(section.id) {
                    #expect(section.byHandOnly, "\(game.id) \(format.id) \(section.id)")
                }
            }
        }
    }

    @Test func idsAreStableLowercaseWordsAndCountedSectionsExist() {
        let allowed: Set<String> = ["main", "extra", "side", "legend", "champion", "runes", "battlefields", "sideboard",
                                    "commander", "deck", "legends"]
        for game in Games.all {
            for format in game.formats {
                let ids = format.sections.map(\.id)
                #expect(Set(ids).isSubset(of: allowed)); #expect(Set(ids).count == ids.count)
                #expect(Set(format.countedSections).isSubset(of: Set(ids)))
                for section in format.sections {
                    if let min = section.min, let max = section.max { #expect(min <= max) }
                }
            }
        }
    }

    @Test func anUnknownFormatIdGivesTheFirstFormat() {
        #expect(magic.format("vintage").id == "commander"); #expect(magic.format("").id == "commander")
        #expect(yugioh.format("commander").id == "standard")
        #expect(magic.format("constructed").section("sideboard")?.name == "Sideboard")
        #expect(magic.format("commander").section("sideboard") == nil)
    }

    @Test func theGroupOrderOfEachGame() {
        #expect(yugioh.deckGroups == ["Monsters", "Spells", "Traps", "Other"])
        #expect(riftbound.deckGroups == ["Units", "Spells", "Gear", "Legends", "Runes", "Battlefields", "Other"])
        #expect(magic.deckGroups == ["Creatures", "Instants", "Sorceries", "Artifacts", "Enchantments", "Planeswalkers",
                                     "Lands", "Other"])
        #expect(cyberpunk.deckGroups == ["Units", "Programs", "Gear", "Legends", "Other"])
    }

    @Test func everyKindsGroupIsADeckGroup() {
        let samples: [(GameDefinition, String, String?)] = [
            (yugioh, "", "xyz_pendulum"), (yugioh, "Normal Trap", nil), (yugioh, "Skill", nil), (riftbound, "Unit;Token", nil),
            (riftbound, "Battlefield", nil), (magic, "Battle — Siege", nil), (magic, "Land", nil), (cyberpunk, "Program", nil),
        ]
        for (game, type, ygo) in samples {
            #expect(game.deckGroups.contains(game.kind(cardType: type, ygoType: ygo).group), "\(game.id) \(type)")
        }
    }
}
