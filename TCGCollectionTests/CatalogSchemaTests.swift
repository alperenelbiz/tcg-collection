import Foundation
import SwiftData
import Testing
@testable import TCGCollection2

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

    /// Fix round 1, item 3: a store that needs a migration is opened only when the volume has 2 × its size + 100 MB free.
    /// Without that space the file is not opened and not changed. A store that needs no migration, or no file, is
    /// opened whatever the space.
    @Test func aStoreIsMigratedOnlyWithTheSpaceForIt() async throws {
        let url = try newStoreURL()
        try await writePhase1Store(at: url)
        let before = try sizeAndDate(url)
        let needed = 2 * before.size + 100_000_000
        do {
            _ = try CatalogStore(url: url, availableCapacity: { _ in needed - 1 })
            Issue.record("a store that needs a migration was opened without the space for it")
        } catch {
            let megabytes = Int((Double(needed) / 1_000_000).rounded(.up))
            #expect(CatalogStore.classify(error) == .other("Not enough free disk space to update the catalog (needs about \(megabytes) MB). Free some space and open the app again."))
        }
        let after = try sizeAndDate(url)
        #expect(after.size == before.size); #expect(after.date == before.date)

        let migrated = try CatalogStore(url: url, availableCapacity: { _ in needed })
        #expect(try await migrated.rulesVersions(game: "riftbound") == [24819: 1])
        _ = try CatalogStore(url: url, availableCapacity: { _ in 0 })            // up to date: no migration, no check
        _ = try CatalogStore(url: try newStoreURL(), availableCapacity: { _ in 0 })   // no file
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

    /// Changed by fix round 1, item 1: a bare 134110 (NSMigrationError) is no longer unreadable. Only a file whose
    /// metadata Core Data cannot read (SQLite 11 or 26) is; with no file to read, only those SQLite codes count.
    @Test func openErrorsAreClassified() {
        #expect(CatalogStore.classify(NSError(domain: "NSSQLiteErrorDomain", code: 26)) == .unreadable)
        if case .other(let text) = CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 134110)) {
            #expect(text.hasPrefix("The catalog could not be updated to this version ("))
        } else { Issue.record("a failed migration alone is not unreadable") }
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSSQLiteErrorDomain", code: 11)])) == .unreadable)
        if case .other = CatalogStore.classify(NSError(domain: NSPOSIXErrorDomain, code: 28)) {} else { Issue.record("a full disk is not unreadable") }
        if case .other = CatalogStore.classify(NSError(domain: "NSSQLiteErrorDomain", code: 13)) {} else { Issue.record("SQLITE_FULL is not unreadable") }
    }

    /// The forms seen on macOS 27: Core Data puts an SQLite code in the user info of a Cocoa error, extended codes keep
    /// the primary code in their low byte, and SwiftData names a store whose schema it does not know.
    @Test func openErrorsAreClassifiedInTheFormsSwiftDataAndCoreDataUse() {
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 259, userInfo: ["NSSQLiteErrorDomain": 26])) == .unreadable)
        #expect(CatalogStore.classify(NSError(domain: "NSSQLiteErrorDomain", code: 779)) == .unreadable)   // SQLITE_CORRUPT_INDEX
        #expect(CatalogStore.classify(SwiftDataError.unknownDataStoreSchema) == .other(StatusText.storeFromNewerVersion))
        // A read-only folder: SQLITE_READONLY_DIRECTORY (1544) in a Cocoa error.
        #expect(CatalogStore.classify(NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: ["NSSQLiteErrorDomain": 1544, NSLocalizedDescriptionKey: "No folder"])) == .other("Catalog: the store cannot be opened (No folder)"))
        if case .other = CatalogStore.classify(SwiftDataError.loadIssueModelContainer) {} else { Issue.record("no cause is not unreadable") }
        // A failed migration of a file whose metadata could be read, and one whose metadata read failed with SQLITE_NOTADB.
        let migration = NSError(domain: NSCocoaErrorDomain, code: 134110)
        if case .other = CatalogStore.classify(StoreOpenError.cannotOpen(migration, fileError: nil)) {} else { Issue.record("a readable file is kept") }
        #expect(CatalogStore.classify(StoreOpenError.cannotOpen(migration, fileError: NSError(domain: "NSSQLiteErrorDomain", code: 26))) == .unreadable)
    }

    /// The phase 1 build opening a store this build has migrated (the probe's reverse case): SwiftData tries V2 → V1 and
    /// fails with NSMigrationError (134110), which it keeps inside a `SwiftDataError`. The file is a readable database:
    /// it is kept, and it is still the V2 store with its row.
    @Test func aStoreWhoseMigrationFailsIsKept() async throws {
        let url = try newStoreURL()
        try await writeClosedStore(at: url)
        let phase1 = Schema([CatalogSchemaV1.CatalogSet.self, CatalogSchemaV1.CatalogProduct.self])
        let error: any Error
        do {
            _ = try ModelContainer(for: phase1, configurations: ModelConfiguration(schema: phase1, url: url))
            Issue.record("the phase 1 schema opened a V2 store"); return
        } catch let thrown { error = thrown }
        let failure = CatalogStore.classify(StoreOpenError(opening: url, failedWith: error))
        // The reason is the Cocoa error that SwiftData keeps (read through `Mirror`).
        #expect(failure == .other(StatusText.storeNotUpdated("An error occurred during persistent store migration.")))
        #expect(try await CatalogStore(url: url).product(1) != nil)
    }

    /// What `CatalogStore(url:)` really throws, judged: a file that is not a database, a truncated file and a corrupt file
    /// are unreadable; a store with an unknown schema (Core Data reads its metadata) and a healthy store in a folder that
    /// cannot be written are kept.
    @Test func theErrorsOfARealOpenAreClassified() async throws {
        let text = try newStoreURL()
        try Data("not a database".utf8).write(to: text)
        #expect(openError(text).map(CatalogStore.classify) == .unreadable)

        let truncated = try newStoreURL()
        try await writeClosedStore(at: truncated)
        let cut = try FileHandle(forUpdating: truncated)
        try cut.truncate(atOffset: 8192)
        try cut.close()
        #expect(openError(truncated).map(CatalogStore.classify) == .unreadable)

        let corrupt = try newStoreURL()
        try await writeClosedStore(at: corrupt, products: (1...500).map { product(id: $0, name: "Card \($0)") })
        let handle = try FileHandle(forUpdating: corrupt)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 4096)                                     // the header page stays, the rest is noise
        try handle.write(contentsOf: Data(repeating: 0xAB, count: Int(size) - 4096))
        try handle.close()
        #expect(openError(corrupt).map(CatalogStore.classify) == .unreadable)

        let foreign = try newStoreURL()
        try ForeignSchema.writeStore(at: foreign)
        #expect(openError(foreign).map(CatalogStore.classify) == .other(StatusText.storeFromNewerVersion))

        // SQLite opens a store in a read-only folder while its -wal and -shm files exist; without them it cannot.
        let locked = try newStoreURL()
        try await writeClosedStore(at: locked)
        let folder = locked.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let failure = try #require(openError(locked).map(CatalogStore.classify))
        if case .other = failure {} else { Issue.record("a read-only folder is not unreadable") }
    }
}
