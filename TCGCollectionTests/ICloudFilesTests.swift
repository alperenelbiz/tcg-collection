import Foundation
import Testing
@testable import TCGCollection2

/// Phase 6B (A62): the iPhone asks iCloud for every known file of the folder that is only in the cloud.
struct ICloudFilesTests {
    @Test func onlyKnownPlaceholdersAreAsked() {
        let names = [".riftbound.json.icloud", ".yu-gi-oh.prices.json.icloud", ".settings.json.icloud",
                     ".notes.txt.icloud", "riftbound.json", ".pokemon.json.icloud", ".riftbound.conflict-x.json.icloud",
                     "riftbound.json.icloud", ".icloud"]
        #expect(ICloudFiles.placeholders(in: names, known: ICloudFiles.known)
                == ["riftbound.json", "yu-gi-oh.prices.json", "settings.json"])
    }

    @Test func theKnownNamesAreTheGameFilesTheHistoryFilesAndSettings() {
        for game in Games.all {
            #expect(ICloudFiles.known.contains("\(game.id).json"))
            #expect(ICloudFiles.known.contains("\(game.id).prices.json"))
        }
        #expect(ICloudFiles.known.contains("settings.json"))
        #expect(ICloudFiles.known.count == Games.all.count * 2 + 1)
    }

    @Test func aRequestAsksEachPlaceholderOnceByItsRealURL() throws {
        let dir = tempDir()
        for name in [".riftbound.json.icloud", ".cyberpunk.prices.json.icloud", ".notes.txt.icloud"] {
            try Data().write(to: dir.appending(path: name))
        }
        try Data("{}".utf8).write(to: dir.appending(path: "yu-gi-oh.json"))
        var asked: [URL] = []
        let names = ICloudFiles.request(folder: dir, names: ICloudFiles.listing(of: dir)) { asked.append($0) }
        #expect(names.sorted() == ["cyberpunk.prices.json", "riftbound.json"])
        #expect(asked.map(\.lastPathComponent).sorted() == ["cyberpunk.prices.json", "riftbound.json"])
        #expect(asked.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL })
    }

    @Test func aFolderThatCannotBeListedAsksNothing() {
        var asked: [URL] = []
        let gone = tempDir().appending(path: "gone")
        let names = ICloudFiles.request(folder: gone, names: ICloudFiles.listing(of: gone)) { asked.append($0) }
        #expect(names.isEmpty); #expect(asked.isEmpty)
    }
}
