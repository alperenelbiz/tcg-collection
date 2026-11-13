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
    @Test func parsesTheAskUserFolderFlag() {
        #expect(LaunchOptions(arguments: ["app", "-askUserFolder", "YES"]).askUserFolder)
        #expect(!LaunchOptions(arguments: ["app", "-askUserFolder", "NO"]).askUserFolder)
        #expect(!LaunchOptions(arguments: ["app"]).askUserFolder)
    }
    @Test func parsesTheScreenFlag() {
        #expect(LaunchOptions(arguments: ["app", "-screen", "collection"]).screen == .collection)
        #expect(LaunchOptions(arguments: ["app", "-screen", "all-cards"]).screen == .allCards)
        #expect(LaunchOptions(arguments: ["app", "-screen", "for-sale"]).screen == .forSale)
        #expect(LaunchOptions(arguments: ["app", "-screen", "wanted"]).screen == .wanted)
        #expect(LaunchOptions(arguments: ["app", "-screen", "allCards"]).screen == nil)      // the flag's spelling only
        #expect(LaunchOptions(arguments: ["app", "-screen", "forSale"]).screen == nil)
        #expect(LaunchOptions(arguments: ["app", "-screen", "Wanted"]).screen == nil)
        #expect(LaunchOptions(arguments: ["app", "-screen", "sold"]).screen == nil)
        #expect(LaunchOptions(arguments: ["app"]).screen == nil)
    }
    @Test func theUserTestRootIsInTheStoreRoot() {
        #expect(AppPaths.userTestRoot(URL(fileURLWithPath: "/tmp/s")).path == "/tmp/s/user")
    }
    @Test func parsesTheFixtureDelayFlag() {
        #expect(LaunchOptions(arguments: ["app", "-fixtureDelay", "1200"]).fixtureDelay == 1200)
        #expect(LaunchOptions(arguments: ["app"]).fixtureDelay == nil)
        #expect(LaunchOptions(arguments: ["app", "-fixtureDelay", "soon"]).fixtureDelay == nil)
        #expect(LaunchOptions(arguments: ["app", "-writeDelay", "1500"]).writeDelay == 1500)
        #expect(LaunchOptions(arguments: ["app"]).writeDelay == nil)
        #expect(LaunchOptions(arguments: ["app", "-writeDelay", "later"]).writeDelay == nil)
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

    /// `-importCSV <path>` is honoured only in a Debug build with `-store`; otherwise it is ignored (fails closed).
    @Test func theImportFlagNeedsADebugBuildAndAStore() {
        let withStore = LaunchOptions(arguments: ["app", "-store", "/tmp/s", "-importCSV", "/tmp/c.csv"])
        #expect(withStore.importCSV?.path == "/tmp/c.csv")
        #expect(withStore.launchImport(isDebugBuild: true)?.path == "/tmp/c.csv")
        #expect(withStore.launchImport(isDebugBuild: false) == nil)
        let withoutStore = LaunchOptions(arguments: ["app", "-importCSV", "/tmp/c.csv"])
        #expect(withoutStore.launchImport(isDebugBuild: true) == nil)
        #expect(LaunchOptions(arguments: ["app", "-store", "/tmp/s"]).launchImport(isDebugBuild: true) == nil)
    }

    /// `-exportPDF <path>` is honoured only in a Debug build with `-store`, with `-screen wanted` or `for-sale`, and with a
    /// path inside the store root (not the root itself); in every other case it is ignored (fails closed).
    @Test func theExportFlagNeedsADebugBuildAStoreAListScreenAndAPathInTheRoot() {
        func pdf(_ arguments: [String], debug: Bool = true) -> LaunchPDF? {
            LaunchOptions(arguments: ["app"] + arguments).launchPDF(isDebugBuild: debug)
        }
        let forSale = ["-store", "/tmp/s", "-screen", "for-sale", "-exportPDF", "/tmp/s/out.pdf"]
        #expect(LaunchOptions(arguments: ["app"] + forSale).exportPDF?.path == "/tmp/s/out.pdf")
        #expect(pdf(forSale) == LaunchPDF(screen: .forSale, file: URL(fileURLWithPath: "/tmp/s/out.pdf")))
        #expect(pdf(["-store", "/tmp/s", "-screen", "wanted", "-exportPDF", "/tmp/s/pdf/w.pdf"])
                == LaunchPDF(screen: .wanted, file: URL(fileURLWithPath: "/tmp/s/pdf/w.pdf")))
        #expect(pdf(forSale, debug: false) == nil)                                                  // a Release build
        #expect(pdf(["-screen", "for-sale", "-exportPDF", "/tmp/s/out.pdf"]) == nil)                // no -store
        #expect(pdf(["-store", "/tmp/s", "-exportPDF", "/tmp/s/out.pdf"]) == nil)                   // no -screen
        #expect(pdf(["-store", "/tmp/s", "-screen", "collection", "-exportPDF", "/tmp/s/out.pdf"]) == nil)
        #expect(pdf(["-store", "/tmp/s", "-screen", "all-cards", "-exportPDF", "/tmp/s/out.pdf"]) == nil)
        #expect(pdf(["-store", "/tmp/s", "-screen", "for-sale", "-exportPDF", "/tmp/other/out.pdf"]) == nil)   // outside
        #expect(pdf(["-store", "/tmp/s", "-screen", "for-sale", "-exportPDF", "/tmp/s/../out.pdf"]) == nil)    // outside
        #expect(pdf(["-store", "/tmp/s", "-screen", "for-sale", "-exportPDF", "/tmp/s2/out.pdf"]) == nil)      // a sibling
        #expect(pdf(["-store", "/tmp/s", "-screen", "for-sale", "-exportPDF", "/tmp/s"]) == nil)               // the root
        #expect(pdf(["-store", "/tmp/s", "-screen", "for-sale"]) == nil)
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
