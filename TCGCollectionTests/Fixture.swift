import Foundation

private final class FixtureBundleToken {}

/// The URL of `Fixtures/<name>` in the test bundle.
func fixtureURL(_ name: String) -> URL {
    (Bundle(for: FixtureBundleToken.self).resourceURL ?? Bundle(for: FixtureBundleToken.self).bundleURL).appendingPathComponent("Fixtures/\(name)")
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}
