import Foundation

/// Launch flags for development and checks. Every flag takes a value, because macOS opens a
/// lone trailing argument as a file and shows no window. A flag without a value is ignored.
nonisolated struct LaunchOptions: Sendable {
    var storeRoot: URL?
    var game: String?
    var search: String?
    var card: Int?
    var offline = false
    var snapshot: URL?
    var catalogReport = false

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        storeRoot = value("-store").map { URL(fileURLWithPath: $0) }
        game = value("-game")
        search = value("-search")
        card = value("-card").flatMap { Int($0) }
        offline = value("-offline") == "YES"
        snapshot = value("-snapshot").map { URL(fileURLWithPath: $0) }
        catalogReport = value("-catalogReport") == "YES"
    }
}
