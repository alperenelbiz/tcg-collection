import Testing
@testable import TCGCollection2

struct PictureSourceTests {
    let riftbound = Games.game("riftbound")!
    let yugioh = Games.game("yu-gi-oh")!

    /// One address per printing: the full size (feedback 1), for a gallery cell, a card page and the PDF alike.
    @Test func tcgplayerURLs() {
        let p = product(id: 721334, game: "riftbound")
        #expect(PictureSource.url(for: p, game: riftbound, ygo: nil)?.absoluteString == "https://tcgplayer-cdn.tcgplayer.com/product/721334_in_1000x1000.jpg")
    }

    @Test func yugiohUsesTheSetCodeThenTheName() throws {
        let index = try YGOPictureIndex(cardinfo: fixture("cardinfo-sample.json"))
        #expect(index.pictureID(number: "JUSH-EN040", name: "whatever") == 80181649)
        #expect(index.pictureID(number: "XXXX-EN000", name: "A Case for K9") == 80181649)      // quotes folded away
        #expect(index.pictureID(number: "TKN5-EN052", name: "Token: Joey and Red-Eyes Black Dragon") == nil)
        #expect(index.pictureID(number: "CT13-EN003", name: "") == 46986414)                     // two or more images: the first
        let p = product(id: 1, game: "yu-gi-oh", number: "JUSH-EN040")
        #expect(PictureSource.url(for: p, game: yugioh, ygo: index)?.absoluteString == "https://images.ygoprodeck.com/images/cards/80181649.jpg")
        #expect(PictureSource.url(for: p, game: yugioh, ygo: nil) == nil)
    }
}
