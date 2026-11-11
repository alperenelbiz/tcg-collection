import Foundation
@testable import TCGCollection2

func product(id: Int = 1, game: String = "riftbound", name: String = "Card", number: String = "",
             rarity: String = "", cardType: String = "", fields: [String: String] = [:]) -> ProductRecord {
    let cardName = CardName.base(name)
    return ProductRecord(productID: id, gameID: game, groupID: 1, name: name, cardName: cardName,
                         searchKey: CardName.searchKey(cardName), number: number, rarity: rarity,
                         cardType: cardType, typeFacets: [], rulesText: "", url: "", fields: fields)
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tcg-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Answers every request with one body, or with a body chosen per URL; counts the calls.
actor FakeFetcher: DataFetching {
    private let body: Data
    private let status: Int
    private let bodies: [URL: Data]
    private(set) var calls = 0

    init(body: Data = Data(), status: Int = 200, bodies: [URL: Data] = [:]) {
        self.body = body
        self.status = status
        self.bodies = bodies
    }

    func data(from url: URL) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(for: .milliseconds(50))
        return (bodies[url] ?? body, status)
    }
}
