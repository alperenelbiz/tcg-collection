import Foundation

/// The current version of the catalog schema (`CatalogSchema.swift`), named only here: the store opens, migrates to,
/// vacuums with and checks against this one. A new version is added as `CatalogSchemaV3` and pointed at here
/// with a migration stage; a shipped version is never edited.
typealias CatalogSchemaCurrent = CatalogSchemaV2

/// The catalog models of the current schema version. The rest of the app names only these.
typealias CatalogSet = CatalogSchemaCurrent.CatalogSet
typealias CatalogProduct = CatalogSchemaCurrent.CatalogProduct
