import Foundation
import Testing
@testable import TCGCollection2

struct TCGCollectionAppTests {
    /// M14: the tests run inside the app, and the app makes no model (no store, no download) only when it sees this
    /// variable. If the test runner stopped setting it, the tests would open the real store and download the catalog.
    @Test func theTestProcessHasTheVariableTheAppGuardReads() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }
}
