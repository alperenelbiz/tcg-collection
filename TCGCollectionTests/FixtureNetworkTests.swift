import Foundation
import Testing
@testable import TCGCollection2

/// The fixture network (`-fixtures <dir>`) serves the three network protocols from the unit test bundle's Fixtures folder.
struct FixtureNetworkTests {
    @Test func catalogClientServesEveryGameFromFiles() async throws {
        let client = FileCatalogClient(directory: fixturesDirectory())
        for game in Games.all {
            let sets = try ProductParser.sets(try await client.groups(category: game.categoryID), game: game)
            #expect(!sets.isEmpty)
            let cards = try ProductParser.products(try await client.products(category: game.categoryID, group: sets[0].groupID), game: game).cards
            #expect(!cards.isEmpty)
        }
    }

    @Test func archiveClientAnswersAnyDayWithItsFile() async throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".7z")
        #expect(try await FileArchiveClient(directory: fixturesDirectory()).download(day: "2030-05-05", to: file))
        var rows = 0; try PriceArchive.read(file, categories: [89, 92]) { _, _, r in rows += r.count }
        #expect(rows == 21)
    }

    @Test func fetcherServesTheIndexAndAPicture() async throws {
        let fetcher = FileFetcher(directory: fixturesDirectory())
        let (index, s1) = try await fetcher.data(from: URL(string: "https://db.ygoprodeck.com/api/v7/cardinfo.php")!)
        #expect(s1 == 200); #expect(try YGOPictureIndex(cardinfo: index).pictureID(number: "JUSH-EN040", name: "") == 80181649)
        let (picture, s2) = try await fetcher.data(from: URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/1_200w.jpg")!)
        #expect(s2 == 200); #expect(picture.count > 1000)
    }

    @MainActor @Test func aModelOnTheFixtureNetworkFillsAllFourGames() async throws {
        let model = AppModel(options: .init(arguments: ["app", "-store", tempRoot().path, "-fixtures", fixturesDirectory().path]),
                             catalogClient: FileCatalogClient(directory: fixturesDirectory()),
                             archiveClient: FileArchiveClient(directory: fixturesDirectory()),
                             fetcher: FileFetcher(directory: fixturesDirectory()))
        let startedAt = Date()
        await model.start()
        for game in Games.all { #expect(try await model.reader.progress(game: game.id).fetched >= 1) }
        // The fixture archive (rows of 2026-01-02) answers the first day the model asks for, and the prices carry the
        // name of that day: the model's clock is not changed (two clock readings cover a start across 20:30 UTC).
        let asked = [PriceDay.wanted(now: startedAt), PriceDay.wanted(now: Date())]
        #expect(asked.contains(model.prices.day(game: "riftbound") ?? "none"))
        #expect(model.prices.prices(game: "riftbound", productID: 721334).contains { $0.finish == "Foil" })
    }
}
