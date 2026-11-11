import Foundation
import SwiftData
import Testing
@testable import TCGCollection2

/// A store with a schema the catalog never had: SwiftData cannot say which version it is.
private enum ForeignSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }

    @Model final class Note {
        var text: String
        init(text: String) { self.text = text }
    }
}

/// A store file at a new temporary path; its folder exists.
private func newStoreURL() throws -> URL {
    let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "catalog.store")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

/// What `CatalogStore(url:)` throws for the store at `url`.
private func openError(_ url: URL) -> (any Error)? {
    do {
        _ = try CatalogStore(url: url)
        return nil
    } catch {
        return error
    }
}

struct CatalogSchemaTests {
    @Test func aPhase1StoreMigratesWithEveryRow() async throws {        // Review Focus 2
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "catalog.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {                                                             // write a store with the V1 schema only
            let container = try ModelContainer(for: Schema(versionedSchema: CatalogSchemaV1.self), configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            context.insert(CatalogSchemaV1.CatalogSet(groupID: 24819, gameID: "riftbound", name: "Radiance", abbreviation: "RAD", publishedOn: nil, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), failed: false))
            for record in try ProductParser.products(fixture("products-89.json"), game: Games.game("riftbound")!).cards { context.insert(CatalogSchemaV1.CatalogProduct(record)) }
            try context.save()
        }
        let store = try CatalogStore(url: url)
        #expect(try await store.fetchDates(game: "riftbound")[24819] == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await store.rulesVersions(game: "riftbound")[24819] == 1)
        let gear = try #require(try await store.product(721334))
        #expect(gear.typeFacets == ["Gear"] && gear.fields["Domain"] == "Order")
        #expect(try await store.search(game: "riftbound", text: "", filter: .init(typeFacet: "Gear"), limit: 50).count == 1)
    }

    /// Every product of the V1 store comes back the same, and a migrated set takes the current rules when it is filled again.
    @Test func aMigratedStoreKeepsEveryProductAndTakesTheCurrentRulesOnTheNextFill() async throws {
        let url = try newStoreURL()
        let cards = try ProductParser.products(fixture("products-89.json"), game: Games.game("riftbound")!).cards
        do {
            let container = try ModelContainer(for: Schema(versionedSchema: CatalogSchemaV1.self), configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            context.insert(CatalogSchemaV1.CatalogSet(groupID: 24819, gameID: "riftbound", name: "Radiance", abbreviation: "RAD", publishedOn: nil))
            for record in cards { context.insert(CatalogSchemaV1.CatalogProduct(record)) }
            try context.save()
        }
        let store = try CatalogStore(url: url)
        for card in cards { #expect(try await store.product(card.productID) == card) }
        try await store.replaceProducts(of: 24819, with: cards, at: .now)
        #expect(try await store.rulesVersions(game: "riftbound") == [24819: CatalogRules.version])
    }

    /// `|a|b|` holds the type facets; an empty text and `||` hold none.
    @Test func theTypeFacetsComeFromTheFacetText() {
        let row = CatalogProduct(product(id: 1, cardType: "Champion Unit"))
        for (text, facets) in [("|Champion Unit|", ["Champion Unit"]), ("|Artifact|Creature|", ["Artifact", "Creature"]),
                               ("", []), ("||", [])] {
            row.facetText = text
            #expect(row.record.typeFacets == facets)
        }
    }

    @Test func openErrorsAreClassified() {
        #expect(CatalogStore.classify(NSError(domain: "NSSQLiteErrorDomain", code: 26)) == .unreadable)
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 134110)) == .unreadable)
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSSQLiteErrorDomain", code: 11)])) == .unreadable)
        if case .other = CatalogStore.classify(NSError(domain: NSPOSIXErrorDomain, code: 28)) {} else { Issue.record("a full disk is not unreadable") }
        if case .other = CatalogStore.classify(NSError(domain: "NSSQLiteErrorDomain", code: 13)) {} else { Issue.record("SQLITE_FULL is not unreadable") }
    }

    /// The forms seen on macOS 27: Core Data puts an SQLite code in the user info of a Cocoa error, extended codes keep
    /// the primary code in their low byte, and SwiftData names a store whose schema it does not know.
    @Test func openErrorsAreClassifiedInTheFormsSwiftDataAndCoreDataUse() {
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 259, userInfo: ["NSSQLiteErrorDomain": 26])) == .unreadable)
        #expect(CatalogStore.classify(NSError(domain: "NSSQLiteErrorDomain", code: 779)) == .unreadable)   // SQLITE_CORRUPT_INDEX
        #expect(CatalogStore.classify(SwiftDataError.unknownDataStoreSchema) == .unreadable)
        // A read-only folder: SQLITE_READONLY_DIRECTORY (1544) in a Cocoa error.
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: ["NSSQLiteErrorDomain": 1544, NSLocalizedDescriptionKey: "No folder"])) == .other("No folder"))
        if case .other = CatalogStore.classify(SwiftDataError.loadIssueModelContainer) {} else { Issue.record("no cause is not unreadable") }
    }

    /// What `CatalogStore(url:)` really throws, judged: a file that is not a database, a corrupt file and a store with
    /// an unknown schema are unreadable; a healthy store in a folder that cannot be written is not.
    @Test func theErrorsOfARealOpenAreClassified() async throws {
        let text = try newStoreURL()
        try Data("not a database".utf8).write(to: text)
        #expect(openError(text).map(CatalogStore.classify) == .unreadable)

        let corrupt = try newStoreURL()
        do {
            let store = try CatalogStore(url: corrupt)
            try await store.replaceProducts(of: 1, with: (1...500).map { product(id: $0, name: "Card \($0)") }, at: .now)
        }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: corrupt.path + suffix) }
        let handle = try FileHandle(forUpdating: corrupt)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 4096)                                     // the header page stays, the rest is noise
        try handle.write(contentsOf: Data(repeating: 0xAB, count: Int(size) - 4096))
        try handle.close()
        #expect(openError(corrupt).map(CatalogStore.classify) == .unreadable)

        let foreign = try newStoreURL()
        do {
            let container = try ModelContainer(for: Schema(versionedSchema: ForeignSchema.self), configurations: ModelConfiguration(url: foreign))
            let context = ModelContext(container)
            context.insert(ForeignSchema.Note(text: "x"))
            try context.save()
        }
        #expect(openError(foreign).map(CatalogStore.classify) == .unreadable)

        let locked = try newStoreURL()
        do {
            let store = try CatalogStore(url: locked)
            try await store.replaceProducts(of: 1, with: [product(id: 1)], at: .now)
        }
        // SQLite opens a store in a read-only folder while its -wal and -shm files exist; without them it cannot.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: locked.path + suffix) }
        let folder = locked.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let failure = try #require(openError(locked).map(CatalogStore.classify))
        if case .other = failure {} else { Issue.record("a read-only folder is not unreadable") }
    }
}
