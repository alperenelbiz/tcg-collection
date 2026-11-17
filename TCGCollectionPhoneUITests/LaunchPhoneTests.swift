import XCTest

/// The phone harness's smoke test: the app starts in the simulator on a fresh store and the fixture network, and its
/// catalog comes from the fixtures (the status line says it is up to date).
///
/// Paths (phase 6A task 1, step 2): `-store` is a folder this runner makes under its `NSTemporaryDirectory()` and
/// `-fixtures` is the `Fixtures` folder in this runner's bundle; the simulator app reads both directly by absolute path.
/// See `PhoneUITestCase`.
final class LaunchPhoneTests: PhoneUITestCase {
    func testTheAppStartsOnTheFixtures() throws {
        let app = launch()
        // Phase 6A task 2: the full status line is in Settings (the line above the tab bar shows only while there is
        // something to say: a sync, a failure, a notice).
        let gear = element(app, "settings-button")
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "no gear")
        gear.tap()
        let status = app.staticTexts["status-line"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "no status line in Settings")
        let upToDate = waitUntil(timeout: 30) { self.text(status).hasPrefix("Catalog up to date") }
        XCTAssertTrue(upToDate, "status line: \(text(status))")
        shot("launch-01")
        // The paths' evidence: the app wrote its catalog into the runner's root, and its fixture network (which reads
        // the runner's Fixtures folder) logged the day it served there.
        let root = try XCTUnwrap(self.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "support/catalog.store").path),
                      "no catalog store in the runner's root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "fixture-archive-requests.txt").path),
                      "the fixture network logged no archive request in the runner's root")
    }
}
