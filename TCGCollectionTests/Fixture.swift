import Foundation

private final class FixtureBundleToken {}

/// The `Fixtures` folder in the test bundle.
func fixturesDirectory() -> URL {
    let bundle = Bundle(for: FixtureBundleToken.self)
    return (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("Fixtures", isDirectory: true)
}

/// The URL of `Fixtures/<name>` in the test bundle.
func fixtureURL(_ name: String) -> URL {
    fixturesDirectory().appendingPathComponent(name)
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}
