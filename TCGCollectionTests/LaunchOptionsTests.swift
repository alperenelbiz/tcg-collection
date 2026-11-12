import Foundation
import Testing
@testable import TCGCollection2

struct LaunchOptionsTests {
    @Test func parsesEveryFlag() {
        let o = LaunchOptions(arguments: ["app", "-store", "/tmp/s", "-game", "yu-gi-oh", "-search", "ash blossom",
                                          "-card", "692993", "-offline", "YES", "-snapshot", "/tmp/a.png", "-catalogReport", "YES"])
        #expect(o.storeRoot?.path == "/tmp/s"); #expect(o.game == "yu-gi-oh"); #expect(o.search == "ash blossom")
        #expect(o.card == 692993); #expect(o.offline); #expect(o.snapshot?.path == "/tmp/a.png"); #expect(o.catalogReport)
    }
    @Test func defaultsAreEmpty() {
        let o = LaunchOptions(arguments: ["app"])
        #expect(o.storeRoot == nil && o.game == nil && o.card == nil && !o.offline && o.snapshot == nil && !o.catalogReport)
    }
    @Test func aFlagWithoutAValueIsIgnored() { #expect(LaunchOptions(arguments: ["app", "-game"]).game == nil) }
    @Test func parsesTheFixturesFlag() {
        #expect(LaunchOptions(arguments: ["app", "-fixtures", "/tmp/f"]).fixtures?.path == "/tmp/f")
        #expect(LaunchOptions(arguments: ["app"]).fixtures == nil)
    }
    @Test func parsesTheFixtureDelayFlag() {
        #expect(LaunchOptions(arguments: ["app", "-fixtureDelay", "1200"]).fixtureDelay == 1200)
        #expect(LaunchOptions(arguments: ["app"]).fixtureDelay == nil)
        #expect(LaunchOptions(arguments: ["app", "-fixtureDelay", "soon"]).fixtureDelay == nil)
    }
    /// I3: `-fixtures` is honoured only in a Debug build with `-store`. Otherwise the run is offline (as `-offline YES`),
    /// never on the real network, and the app prints one line that says why. Without `-fixtures` the network is real.
    @Test func theFixtureNetworkFailsClosed() {
        let fixtures = URL(fileURLWithPath: "/tmp/f", isDirectory: true)
        let withStore = LaunchOptions(arguments: ["app", "-store", "/tmp/s", "-fixtures", "/tmp/f"])
        let withoutStore = LaunchOptions(arguments: ["app", "-fixtures", "/tmp/f"])
        let release = LaunchNetwork.offline(notice: "-fixtures works only in a Debug build: this run is offline")
        let noStore = LaunchNetwork.offline(notice: "-fixtures needs -store <dir>: this run is offline")
        #expect(LaunchNetwork.choose(withStore, isDebugBuild: true) == .fixtures(fixtures))
        #expect(LaunchNetwork.choose(withStore, isDebugBuild: false) == release)
        #expect(LaunchNetwork.choose(withoutStore, isDebugBuild: true) == noStore)
        #expect(LaunchNetwork.choose(withoutStore, isDebugBuild: false) == release)
        for debug in [true, false] {
            #expect(LaunchNetwork.choose(LaunchOptions(arguments: ["app", "-store", "/tmp/s"]), isDebugBuild: debug) == .internet)
            #expect(LaunchNetwork.choose(LaunchOptions(arguments: ["app"]), isDebugBuild: debug) == .internet)
        }
    }

    #if DEBUG
    /// A Debug run without `-store` uses its own folders, never the installed app's store. (A Release build uses the
    /// installed app's folders: this test runs only in Debug.)
    @Test func aDebugBuildWithoutARootHasItsOwnFolders() {
        let folders = AppPaths.systemFolders()
        #expect(folders.support == URL.applicationSupportDirectory.appending(path: "TCGCollection2-Debug", directoryHint: .isDirectory))
        #expect(folders.caches == URL.cachesDirectory.appending(path: "TCGCollection2-Debug", directoryHint: .isDirectory))
    }
    #endif
    @Test func pathsUnderARootStayUnderIt() {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let p = AppPaths(root: root)
        #expect(p.catalogStore.path.hasPrefix(root.path)); #expect(p.archives.path.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: p.support.path))
    }
}
