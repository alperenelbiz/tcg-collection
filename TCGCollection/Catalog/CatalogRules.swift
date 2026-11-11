import Foundation

/// The version of the rules that turn tcgcsv products into catalog rows (which products are cards, card names, type
/// facets). Each set keeps the version its products were stored with (`CatalogSet.rulesVersion`); a set stored with
/// an older version holds stale rows and is fetched again (P3).
nonisolated enum CatalogRules {
    /// 1: phase 1. 2: Alperen's decisions A1–A4 (2026-11-12).
    static let version = 2
}
