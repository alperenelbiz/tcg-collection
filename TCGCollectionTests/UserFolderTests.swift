import Foundation
import Testing
@testable import TCGCollection2

/// The folder rule is the safety boundary between a test or a Debug run and the owner's iCloud Drive. Every bookmark here
/// points into a temporary directory; nothing reads `~/Library/Mobile Documents`.
struct UserFolderTests {
    @Test func whereTheFolderIs() throws {
        let root = URL(fileURLWithPath: "/tmp/r"), drive = URL(fileURLWithPath: "/tmp/drive")
        #expect(UserFolder.resolve(storeRoot: root, isDebugBuild: true, bookmark: nil, iCloudDrive: drive) == .testRoot(root.appending(path: "user")))
        #expect(UserFolder.resolve(storeRoot: root, isDebugBuild: false, bookmark: nil, iCloudDrive: drive) == .testRoot(root.appending(path: "user")))
        if case .debugLocal = UserFolder.resolve(storeRoot: nil, isDebugBuild: true, bookmark: nil, iCloudDrive: drive) {} else { Issue.record("a Debug build must stay local") }
        #expect(UserFolder.resolve(storeRoot: nil, isDebugBuild: false, bookmark: nil, iCloudDrive: drive) == .none)
        #expect(UserFolder.resolve(storeRoot: nil, isDebugBuild: false, bookmark: Data("junk".utf8), iCloudDrive: drive) == .none)
        #expect(UserFolder.defaultICloudFolder(in: drive).path == "/tmp/drive/TCG Collection")
    }

    @Test func aBookmarkRoundTrips() throws {
        let dir = tempDir(); let made = try #require(UserFolder.url(fromBookmark: try UserFolder.bookmark(for: dir)))
        #expect(made.url.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    /// The Debug folder without `-store` is the Debug support folder's `user`, never the installed app's.
    @Test func theDebugFolderIsTheDebugSupportFolder() {
        let expected = URL.applicationSupportDirectory.appending(path: "TCGCollection2-Debug").appending(path: "user")
        #expect(UserFolder.resolve(storeRoot: nil, isDebugBuild: true, bookmark: nil, iCloudDrive: nil) == .debugLocal(expected))
    }

    /// A stored bookmark counts only in a Release build without `-store`. A Debug build and a `-store` run ignore it,
    /// whatever it points at.
    @Test func aBookmarkCountsOnlyInAReleaseBuildWithoutARoot() throws {
        let drive = tempDir(), picked = tempDir()
        let inDrive = drive.appending(path: "TCG Collection")
        try FileManager.default.createDirectory(at: inDrive, withIntermediateDirectories: true)
        let pickedMark = try UserFolder.bookmark(for: picked), driveMark = try UserFolder.bookmark(for: inDrive)
        let root = tempDir()

        #expect(same(UserFolder.resolve(storeRoot: nil, isDebugBuild: false, bookmark: pickedMark, iCloudDrive: drive), .picked(picked)))
        #expect(same(UserFolder.resolve(storeRoot: nil, isDebugBuild: false, bookmark: driveMark, iCloudDrive: drive), .iCloud(inDrive)))
        // No iCloud Drive on this device: a folder is a picked one.
        #expect(same(UserFolder.resolve(storeRoot: nil, isDebugBuild: false, bookmark: driveMark, iCloudDrive: nil), .picked(inDrive)))
        for mark in [pickedMark, driveMark] {
            if case .debugLocal = UserFolder.resolve(storeRoot: nil, isDebugBuild: true, bookmark: mark, iCloudDrive: drive) {} else {
                Issue.record("a Debug build used a bookmark")
            }
            for debug in [true, false] {
                #expect(UserFolder.resolve(storeRoot: root, isDebugBuild: debug, bookmark: mark, iCloudDrive: drive) == .testRoot(root.appending(path: "user")))
            }
        }
    }

    /// `-askUserFolder YES` (Debug, with `-store`): the choice is made as in a Release build, but only a folder inside the
    /// store root counts. A Release build ignores the flag.
    @Test func askingForTheFolderStaysInsideTheRoot() throws {
        let root = tempDir(), outside = tempDir()
        let drive = root.appending(path: "icloud"), inDrive = drive.appending(path: "TCG Collection"), picked = root.appending(path: "mine")
        for dir in [inDrive, picked] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        func ask(_ bookmark: Data?, debug: Bool = true) -> UserFolderChoice {
            UserFolder.resolve(storeRoot: root, isDebugBuild: debug, bookmark: bookmark, iCloudDrive: drive, askUserFolder: true)
        }
        #expect(ask(nil) == .none)
        #expect(ask(Data("junk".utf8)) == .none)
        #expect(same(ask(try UserFolder.bookmark(for: inDrive)), .iCloud(inDrive)))
        #expect(same(ask(try UserFolder.bookmark(for: picked)), .picked(picked)))
        #expect(ask(try UserFolder.bookmark(for: outside)) == .none)
        #expect(ask(try UserFolder.bookmark(for: inDrive), debug: false) == .testRoot(root.appending(path: "user")))
        // Without -store the flag means nothing: a Debug build stays local.
        if case .debugLocal = UserFolder.resolve(storeRoot: nil, isDebugBuild: true, bookmark: try UserFolder.bookmark(for: inDrive),
                                                 iCloudDrive: drive, askUserFolder: true) {} else {
            Issue.record("-askUserFolder without -store left the Debug folder")
        }
    }

    @Test func insideComparesWholeFolderNames() throws {
        let root = tempDir()
        let child = root.appending(path: "a/b"), sibling = URL(fileURLWithPath: root.path + "-other")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        #expect(UserFolder.isInside(child, root)); #expect(UserFolder.isInside(root, root))
        #expect(!UserFolder.isInside(sibling, root)); #expect(!UserFolder.isInside(root.deletingLastPathComponent(), root))
        // A path through `..` that leaves the root is outside.
        #expect(!UserFolder.isInside(root.appending(path: "a/../../x"), root))
        // `/var` is a link to `/private/var`: both spellings are one folder.
        let tmp = URL(fileURLWithPath: "/private" + root.path)
        if root.path.hasPrefix("/var/") { #expect(UserFolder.isInside(tmp.appending(path: "a"), root)) }
    }

    /// What each kind of run may do. Only a Release build without `-store` asks where iCloud Drive is; `-askUserFolder` gets a
    /// stand-in inside the store root and may not leave it.
    @Test func theSetupOfEachKindOfRun() {
        let root = URL(fileURLWithPath: "/tmp/r"), realDrive = URL(fileURLWithPath: "/tmp/drive")
        var asked = 0
        func setup(_ storeRoot: URL?, debug: Bool, ask: Bool) -> UserFolderSetup {
            UserFolder.setup(storeRoot: storeRoot, isDebugBuild: debug, askUserFolder: ask, bookmark: nil) { asked += 1; return realDrive }
        }
        let fixedTest = UserFolderSetup(choice: .testRoot(root.appending(path: "user")), iCloudDrive: nil, canChoose: false, boundary: nil)
        for debug in [true, false] { #expect(setup(root, debug: debug, ask: false) == fixedTest) }
        #expect(setup(root, debug: false, ask: true) == fixedTest)                      // a Release build ignores the flag
        let debugLocal = UserFolder.resolve(storeRoot: nil, isDebugBuild: true, bookmark: nil, iCloudDrive: nil)
        for ask in [false, true] {
            #expect(setup(nil, debug: true, ask: ask) == UserFolderSetup(choice: debugLocal, iCloudDrive: nil, canChoose: false, boundary: nil))
        }
        #expect(setup(root, debug: true, ask: true)
                == UserFolderSetup(choice: .none, iCloudDrive: root.appending(path: "icloud"), canChoose: true, boundary: root))
        #expect(asked == 0, "only a Release build without -store may look for iCloud Drive")
        #expect(setup(nil, debug: false, ask: false) == UserFolderSetup(choice: .none, iCloudDrive: realDrive, canChoose: true, boundary: nil))
        #expect(asked == 1)
    }

    @Test func choiceURLs() {
        let u = URL(fileURLWithPath: "/tmp/x")
        #expect(UserFolderChoice.testRoot(u).url == u); #expect(UserFolderChoice.debugLocal(u).url == u)
        #expect(UserFolderChoice.iCloud(u).url == u); #expect(UserFolderChoice.picked(u).url == u)
        #expect(UserFolderChoice.none.url == nil)
    }

    /// The same case, and the same folder once links (`/var` → `/private/var`) are resolved.
    private func same(_ a: UserFolderChoice, _ b: UserFolderChoice) -> Bool {
        func path(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().standardizedFileURL.path }
        switch (a, b) {
        case (.iCloud(let x), .iCloud(let y)), (.picked(let x), .picked(let y)): return path(x) == path(y)
        default: Issue.record("\(a) is not \(b)"); return false
        }
    }
}
