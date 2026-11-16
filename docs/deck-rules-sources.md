# Deck rule numbers and their sources (phase 3A task 1)

Read on 2026-11-15. Only the publishers' own pages and documents count as a source. A number without one is under
"Not confirmed" and is built as `nil` (no warning). The sections and their order are spec 5.3 (approved); this report
does not change them. The numbers are in `TCGCollection/Games/DeckFormat.swift` (`GameDecks`) and pinned by
`TCGCollectionTests/DeckFormatTests.swift`.

A section's bound is a per-section number: a rule warns when one section is under its minimum or over its maximum. A
minimum of 0 is built as `nil` (no rule). Two official sizes count cards that the approved table puts in two sections
(Magic Commander: 100 with the commander; Riftbound: exactly 40 with the Chosen Champion, A20). They are built as a total
over the two sections (`DeckFormat.totals`, `DeckTotal`), and neither section carries a bound of its own; see "Where the
rules and the approved sections differ". No number in the app is an inference.

## Yu-Gi-Oh! — format `standard`

Source: Konami, Official Rulebook (Structure Deck rulebook, version 10),
<https://img.yugioh-card.com/en/downloads/rulebook/SD_RuleBook_EN_10.pdf>, page "Getting Started".

| Section | Min | Max | By hand | Sentence |
|---|---|---|---|---|
| Main Deck (`main`) | 40 | 60 | no | "The Deck must be 40 to 60 cards." (header: "Deck ….(40 to 60 cards)") |
| Extra Deck (`extra`) | — (0) | 15 | no | "You can have up to 15 cards in the Extra Deck." (header: "Extra Deck ….(0 to 15 cards)") |
| Side Deck (`side`) | — (0) | 15 | yes | "The number of cards in your Side Decks must not exceed 15." (header: "Side Deck ….(0 to 15 cards)") |

- Copy limit 3, over Main + Extra + Side: "You can only have up to 3 copies of the same card in your Deck, Extra Deck and
  Side Deck combined." (`countedSections` = main, extra, side). The Forbidden / Limited list lowers it for some cards;
  not built.
- Extra Deck monsters: the rulebook names "Xyz Monsters, Synchro Monsters and Fusion Monsters" on that page, and Link
  Monsters are summoned "from your Extra Deck" (page "Link Monsters"). So `fusion`, `synchro`, `xyz`, `link` (and their
  pendulum forms) → Extra Deck.

## Magic: The Gathering

Source: Wizards of the Coast, Magic: The Gathering Comprehensive Rules, effective 2026-11-06,
<https://media.wizards.com/2026/downloads/MagicCompRules%2020261106.txt> (linked from <https://magic.wizards.com/en/rules>).

### Format `constructed`

| Section | Min | Max | By hand | Sentence |
|---|---|---|---|---|
| Deck (`deck`) | 60 | — | no | 100.2a: "each deck has a minimum deck size of 60 cards." |
| Sideboard (`sideboard`) | — | 15 | yes | 100.4a: "In constructed play, a sideboard may contain no more than fifteen cards." |

- Copy limit 4, over Deck + Sideboard, basic lands exempt. 100.2a: "A constructed deck may contain any number of basic
  land cards and no more than four of any card with a particular English name other than basic land cards." 100.4a:
  "The four-card limit (see rule 100.2a) applies to the combined deck and sideboard."

### Format `commander`

| Section | Min | Max | By hand | Sentence |
|---|---|---|---|---|
| Commander (`commander`) | 1 | 2 | yes | 903.3: "Each deck has a legendary card designated as its commander." 702.124a: "Each partner ability allows you to designate two legendary cards as your commander rather than one." 702.124g: "no partner ability or combination of partner abilities can ever let a player have more than two commanders." |
| Deck (`deck`) | — | — | no | No number of its own: the 100 below include the commander. |
| Total "Commander deck" (`commander` + `deck`) | 100 | 100 | — | 903.5a: "Each deck must contain exactly 100 cards, including its commander. In other words, the minimum deck size and the maximum deck size are both 100." 702.124b: "Your deck must contain exactly 100 cards, including its two commanders." |

- Copy limit 1, over Commander + Deck, basic lands exempt. 903.5b: "Other than basic lands, each card in a Commander
  deck must have a different English name."
- The basic-land exemption is not a format field: the deck maths (task 4) skips basic cards (`isBasicCard`, A8).
- The Commander section is `byHandOnly`: no card goes there by default (a legendary creature goes to Deck, as the brief
  says), and the user designates the commander by moving it.

## Riftbound — format `standard`

Sources (both linked from the official rules hub <https://playriftbound.com/en-us/rules-hub/>, to which
riftbound.leagueoflegends.com redirects):
- Riftbound Core Rules, "Last Updated: 2026-10-09",
  <https://cmsassets.rgpub.io/sanity/files/dsfx7636/news_live/5c7946f7c3b8c6e0faff85ab6dadc6d2e721ea94.pdf> (CR).
- Riftbound Tournament Rules, "Last Updated October 9, 2026",
  <https://cmsassets.rgpub.io/sanity/files/dsfx7636/news_live/861752822d217edf37d9febaeaf77a7d924c1bb6.pdf> (TR).

| Section | Min | Max | By hand | Sentence |
|---|---|---|---|---|
| Legend (`legend`) | 1 | 1 | no | CR 103.2: "1 Champion Legend". TR 402.1: "… 1 Legend …" |
| Champion (`champion`) | 1 | 1 | yes | Alperen, 2026-11-16 (A19): exactly 1. CR 103.3: "A Main Deck of at least 40 cards: A Chosen Champion Unit, as well as Units, Gear, and Spells". CR 103.3.a.1: "This will be placed in the Champion Zone at the start of the game." TR 402.1: "(including a chosen champion)". One Chosen Champion. |
| Main Deck (`main`) | — | — | no | No number of its own: the 40 below include the Chosen Champion. |
| Total "Main Deck with its Champion" (`champion` + `main`) | 40 | 40 | — | Alperen, 2026-11-16 (A20): exactly 40. CR 103.3 says "at least 40"; TR 601.1.b says "exactly 40" in competitions. |
| Runes (`runes`) | 12 | 12 | no | CR 103.4.a: "12 Rune Cards". TR 402.1: "12 runes". |
| Battlefields (`battlefields`) | 3 | 3 | no | CR 487.4.a (and 488–491, every sanctioned mode): "Each player provides three (3) Battlefields, included in their deck during deck building." TR 402.1: "exactly 3 battlefields each with a unique name." |
| Sideboard (`sideboard`) | — | 10 | yes | TR 601.1.c.1: "A player's sideboard can include 10 or fewer cards." (in competitions where a sideboard is allowed) |

- Copy limit 3, over Champion + Main Deck + Sideboard. CR 103.3.b: "Your Main Deck can include up to 3 copies of the same
  named card." CR 103.3.b.1: "This includes your Chosen Champion." TR 601.1.c.3: "Limits on copies of named cards apply
  to the combination of main deck and sideboard." Runes, the Legend and Battlefields are not Main Deck cards and are not
  counted (`countedSections` = champion, main, sideboard).
- Main Deck size, a note: CR 103.3 says "at least 40"; TR 601.1.b says "In competitions, a player's Main Deck must be
  exactly 40 cards." (also TR 402.1). Built: exactly 40 for the Main Deck with its Champion (total of `champion` +
  `main`, 40...40), Alperen, 2026-11-16 (A20). A deck of 39 says "needs 40 cards", one of 41 "at most 40 cards".
- Not built (other rules, not numbers of a section): CR 103.3.d, at most 3 Signature cards in total; CR 103.5.c, no two
  Battlefields of one name; domain identity.
- Card types (for `CardKind`): CR 103.3 names "Units, Gear, and Spells"; the catalog's `Card Type` values (copy of the
  real catalog, 2026-11-15) are `Unit`, `Champion Unit`, `Legend`, `Spell`, `Gear`, `Rune`, `Battlefield`,
  `Signature Spell`, `Signature Gear`, `Signature Unit`, and token forms such as `Unit;Token`.

## Cyberpunk TCG — format `standard`

Source: WeirdCo, "The Official Cyberpunk Trading Card Game Gameplay Guide", <https://cyberpunktcg.com/gameplay-guide>,
section on deck building (no date on the page; footer "© 2026").

| Section | Min | Max | By hand | Sentence |
|---|---|---|---|---|
| Legends (`legends`) | 3 | 3 | no | "Use exactly 3 Legend cards with unique names." Different names built as at most 1 copy of a card in the section (`maxCopies`), Alperen, 2026-11-16 (A21). |
| Main Deck (`main`) | 40 | 50 | no | "Include no fewer than 40 and no more than 50 cards (not including your Legends)." |
| Side Deck (`side`) | sizes 0 or 7 | | yes | Alperen, 2026-11-16 (A21): 0 or 7 cards (`DeckSection.sizes`). |

- Copy limit 3: "Use no more than 3 copies of the same card." Counted over the Main Deck and the Side Deck together
  (`countedSections` = main, side), Alperen, 2026-11-16 (A21); the Legends have their own rule (unique names).
- Card types (for `CardKind`): the printable guide (<https://cyberpunktcg.com/docs/printable-gameplay-guide.pdf>):
  "It designates the card as a Legend, Unit, Program, or Gear." The catalog's `CardType` values are those four.
- Not built: the RAM limit ("Cards must stay within the RAM limit set by your Legends").

## Where the rules and the approved sections differ

The sections of spec 5.3 are approved and kept. In three places an official rule counts or names cards differently:

| Rule | Sentence | What the app does |
|---|---|---|
| Magic Commander, CR 903.5a | "Each deck must contain exactly 100 cards, including its commander." | The commander stands in its own section (Commander, 1–2, by hand only). A total "Commander deck" over Commander + Deck is exactly 100; the Deck section has no bound of its own. |
| Riftbound, CR 103.3 (A20) | "A Main Deck of at least 40 cards: A Chosen Champion Unit, as well as Units, Gear, and Spells" | The Chosen Champion stands in its own section (Champion, exactly 1, by hand only). A total "Main Deck with its Champion" over Champion + Main Deck is exactly 40 (Alperen, 2026-11-16); the Main Deck section has no bound of its own. A Champion Unit still goes to the Main Deck by default (spec 5.3), so the Champion section is under its minimum until the user moves the champion there. |
| Riftbound, TR 601.1.b | "In competitions, a player's Main Deck must be exactly 40 cards." | Superseded by A20 (Alperen, 2026-11-16): the app builds exactly 40. |

## Not confirmed (built as nil)

None. The numbers that were not confirmed (Cyberpunk Side Deck size, Cyberpunk copy limit over the Side Deck, Riftbound's
Champion "exactly 1" and Main Deck "exactly 40") were answered by Alperen on 2026-11-16 (A19–A21) and stand as his word,
not as a quoted official page.

## Questions for Alperen

Questions 1–4 (Cyberpunk Side Deck size, Cyberpunk copy limit and the Side Deck, Riftbound Champion, Riftbound Main Deck
size) were closed on 2026-11-16 (A19–A21).
