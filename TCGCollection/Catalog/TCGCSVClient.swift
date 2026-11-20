import Foundation

nonisolated protocol TCGCSVFetching: Sendable {
    func groups(category: Int) async throws -> Data
    func products(category: Int, group: Int) async throws -> Data
}

nonisolated struct TCGCSVClientError: Error, Equatable {
    let status: Int
}

nonisolated struct TCGCSVClient: TCGCSVFetching {
    var session: URLSession = .shared

    func groups(category: Int) async throws -> Data {
        try await get("https://tcgcsv.com/tcgplayer/\(category)/groups")
    }

    func products(category: Int, group: Int) async throws -> Data {
        try await get("https://tcgcsv.com/tcgplayer/\(category)/\(group)/products")
    }

    private func get(_ address: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("TCGCollection/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TCGCSVClientError(status: status) }
        return data
    }
}
