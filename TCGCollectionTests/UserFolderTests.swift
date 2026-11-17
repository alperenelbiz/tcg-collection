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

    /// Item 3: a bookmark whose folder was deleted does not resolve, but its path is read from the bookmark data. The
    /// Release setup then opens the sheet and says where the folder was.
    @Test func theOldPathOfAFolderThatIsGone() throws {
        let gone = tempDir().appending(path: "TCG Collection")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let mark = try UserFolder.bookmark(for: gone)
        try FileManager.default.removeItem(at: gone)
        #expect(UserFolder.url(fromBookmark: mark) == nil)
        let path = try #require(UserFolder.path(ofBookmark: mark))
        #expect(UserFolder.isSameFolder(URL(fileURLWithPath: path), gone), "\(path)")
        #expect(UserFolder.path(ofBookmark: Data("junk".utf8)) == nil)
        let setup = UserFolder.setup(storeRoot: nil, isDebugBuild: false, askUserFolder: false, bookmark: mark) { nil }
        #expect(setup.choice == .none); #expect(setup.lost == .gone(path: path))
        #expect(setup.lost?.sentence == "Your collection folder was at \(path). It is not there now. Choose it again, or choose another folder.")
        // No bookmark, or one that cannot be read: the plain first run.
        #expect(UserFolder.setup(storeRoot: nil, isDebugBuild: false, askUserFolder: false, bookmark: nil) { nil }.lost == nil)
        #expect(UserFolder.setup(storeRoot: nil, isDebugBuild: false, askUserFolder: false, bookmark: Data("junk".utf8)) { nil }.lost == nil)
        // A fixed folder says nothing about a bookmark.
        #expect(UserFolder.setup(storeRoot: nil, isDebugBuild: true, askUserFolder: false, bookmark: mark) { nil }.lost == nil)
    }

    /// Item 7: a folder in a Trash (the user's, iCloud Drive's `.Trash`, a volume's `.Trashes`) is not the collection folder.
    @Test func aFolderInATrashIsNotTheCollectionFolder() throws {
        let trash = URL(fileURLWithPath: "/Users/x/.Trash")
        #expect(UserFolder.isInTrash(URL(fileURLWithPath: "/Users/x/.Trash/TCG Collection"), trash: trash))
        #expect(UserFolder.isInTrash(URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/.Trash/TCG Collection"), trash: nil))
        #expect(UserFolder.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/TCG Collection"), trash: nil))
        #expect(UserFolder.isInTrash(URL(fileURLWithPath: "/elsewhere/bin/TCG Collection"), trash: URL(fileURLWithPath: "/elsewhere/bin")))
        #expect(!UserFolder.isInTrash(URL(fileURLWithPath: "/Users/x/Documents/TCG Collection"), trash: trash))
        #expect(!UserFolder.isInTrash(URL(fileURLWithPath: "/Users/x/my.Trash/TCG Collection"), trash: trash))
        // A real bookmark into a folder named `.Trash`: it resolves, but counts as not resolving, and the sheet says where.
        let inTrash = tempDir().appending(path: ".Trash").appending(path: "TCG Collection")
        try FileManager.default.createDirectory(at: inTrash, withIntermediateDirectories: true)
        let mark = try UserFolder.bookmark(for: inTrash)
        #expect(UserFolder.resolve(storeRoot: nil, isDebugBuild: false, bookmark: mark, iCloudDrive: nil) == .none)
        let setup = UserFolder.setup(storeRoot: nil, isDebugBuild: false, askUserFolder: false, bookmark: mark) { nil }
        #expect(setup.choice == .none)
        guard case .inTrash(let path) = setup.lost else { Issue.record("lost: \(String(describing: setup.lost))"); return }
        #expect(UserFolder.isSameFolder(URL(fileURLWithPath: path), inTrash), "\(path)")
        #expect(setup.lost?.sentence == "Your collection folder is in the Trash (\(path)). Put it back, or choose another folder.")
    }

    /// Phase 6A (A55, ruling P3): the iPhone shows no "Use iCloud Drive" button, also where a drive (or the stand-in of
    /// `-askUserFolder`) is known; the Mac shows it whenever the folder can be chosen and a drive exists. The platform is
    /// a parameter of the pure setup, so this runs on the Mac.
    @Test func theIPhoneOffersNoICloudButton() {
        let root = URL(fileURLWithPath: "/tmp/r"), drive = URL(fileURLWithPath: "/tmp/drive")
        func setup(_ storeRoot: URL?, ask: Bool, phone: Bool, drive found: URL?) -> UserFolderSetup {
            UserFolder.setup(storeRoot: storeRoot, isDebugBuild: storeRoot != nil, askUserFolder: ask, bookmark: nil,
                             offersICloud: !phone) { found }
        }
        // A Release first run and an `-askUserFolder` run.
        #expect(!setup(nil, ask: false, phone: true, drive: drive).showsICloudButton)
        #expect(!setup(root, ask: true, phone: true, drive: nil).showsICloudButton)
        #expect(setup(nil, ask: false, phone: false, drive: drive).showsICloudButton)
        #expect(setup(root, ask: true, phone: false, drive: nil).showsICloudButton)
        // The Mac without a drive, and a fixed folder: no button either.
        #expect(!setup(nil, ask: false, phone: false, drive: nil).showsICloudButton)
        #expect(!setup(root, ask: false, phone: false, drive: drive).showsICloudButton)
        // The platform's own value: false on the iPhone, true on the Mac.
        #if os(iOS)
        #expect(!UserFolder.offersICloud)
        #else
        #expect(UserFolder.offersICloud)
        #endif
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
