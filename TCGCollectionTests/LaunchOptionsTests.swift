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
    @Test func pathsUnderARootStayUnderIt() {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let p = AppPaths(root: root)
        #expect(p.catalogStore.path.hasPrefix(root.path)); #expect(p.archives.path.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: p.support.path))
    }
}
