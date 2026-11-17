import Foundation
import Testing
@testable import TCGCollection2

struct AppPathsTests {
    @Test func priceDaysLiveInSupportNotInCaches() {
        let root = tempDir()
        let paths = AppPaths(root: root)
        #expect(paths.priceDays.standardizedFileURL.path
                == root.appending(path: "support/price-days").standardizedFileURL.path)
        #expect(paths.priceDay("2026-11-16").standardizedFileURL.path
                == root.appending(path: "support/price-days/2026-11-16.prices").standardizedFileURL.path)
        #expect(!paths.priceDays.path.hasPrefix(paths.caches.path))
    }
}
