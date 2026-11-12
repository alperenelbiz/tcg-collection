import Foundation

/// Where the user folder of this run is, and why.
nonisolated enum UserFolderChoice: Equatable, Sendable {
    /// `-store <root>`: `<root>/user`.
    case testRoot(URL)
    /// A Debug build without `-store`: the Debug support folder's `user`.
    case debugLocal(URL)
    /// A chosen folder inside iCloud Drive.
    case iCloud(URL)
    /// A chosen folder anywhere else.
    case picked(URL)
    /// Nothing chosen yet: the first-run sheet decides.
    case none

    var url: URL? {
        switch self {
        case .testRoot(let url), .debugLocal(let url), .iCloud(let url), .picked(let url): url
        case .none: nil
        }
    }
}

/// What the folder sheet may do in this run. Made once at launch (`UserFolder.setup`).
nonisolated struct UserFolderSetup: Equatable, Sendable {
    /// The folder at launch; `.none` means the first-run sheet decides.
    var choice: UserFolderChoice
    /// The folder "Use iCloud Drive" puts `TCG Collection` in; nil hides the button.
    var iCloudDrive: URL?
    /// True when the sheet may change the folder; the choice is then kept as a bookmark. False when the folder is fixed:
    /// a `-store` run without `-askUserFolder`, or a Debug build without `-store`.
    var canChoose: Bool
    /// A chosen folder must be inside this one (a Debug build with `-askUserFolder`: the store root). Nil: anywhere.
    var boundary: URL?
}

nonisolated enum UserFolderError: LocalizedError, Equatable {
    /// This run's folder cannot be changed (`-store`, or a Debug build).
    case fixed
    /// A Debug build may keep its collection only inside its store root.
    case outside(path: String)

    var errorDescription: String? {
        switch self {
        case .fixed: "This run keeps its collection in a fixed folder."
        case .outside(let path): "A Debug build keeps its collection inside \(path)."
        }
    }
}

/// Where the user folder is. This is the safety boundary between a test or a Debug run and the owner's iCloud Drive:
/// - `-store <root>` (any build): `<root>/user`, never anything else.
/// - A Debug build without `-store`: `Application Support/TCGCollection2-Debug/user`, whatever bookmark is stored.
/// - A Release build without `-store`: the stored bookmark's folder when it resolves; else `.none`.
/// - `-askUserFolder YES` (Debug, with `-store`): as a Release build, but only a folder inside the store root counts, and
///   "Use iCloud Drive" uses `<root>/icloud` instead of iCloud Drive.
nonisolated enum UserFolder {
    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// The folder name that "Use iCloud Drive" makes in iCloud Drive (B6). The old app's folder is `tcg`.
    static let iCloudFolderName = "TCG Collection"

    static func resolve(storeRoot: URL?, isDebugBuild: Bool, bookmark: Data?, iCloudDrive: URL?,
                        askUserFolder: Bool = false) -> UserFolderChoice {
        if let storeRoot {
            guard isDebugBuild, askUserFolder else { return .testRoot(AppPaths.userTestRoot(storeRoot)) }
            guard let choice = chosen(bookmark, iCloudDrive: iCloudDrive), let url = choice.url,
                  isInside(url, storeRoot) else { return .none }
            return choice
        }
        if isDebugBuild { return .debugLocal(debugLocalFolder) }
        return chosen(bookmark, iCloudDrive: iCloudDrive) ?? .none
    }

    /// The setup of a run. `iCloudDrive` is called only in a Release build without `-store`; `-askUserFolder` gets
    /// `<root>/icloud` as its stand-in, so a test never reaches the real iCloud Drive.
    static func setup(storeRoot: URL?, isDebugBuild: Bool, askUserFolder: Bool, bookmark: Data?,
                      iCloudDrive: () -> URL?) -> UserFolderSetup {
        if let storeRoot, isDebugBuild, askUserFolder {
            let drive = storeRoot.appending(path: "icloud")
            let choice = resolve(storeRoot: storeRoot, isDebugBuild: true, bookmark: bookmark, iCloudDrive: drive, askUserFolder: true)
            return UserFolderSetup(choice: choice, iCloudDrive: drive, canChoose: true, boundary: storeRoot)
        }
        if storeRoot == nil, !isDebugBuild {
            let drive = iCloudDrive()
            let choice = resolve(storeRoot: nil, isDebugBuild: false, bookmark: bookmark, iCloudDrive: drive)
            return UserFolderSetup(choice: choice, iCloudDrive: drive, canChoose: true, boundary: nil)
        }
        let choice = resolve(storeRoot: storeRoot, isDebugBuild: isDebugBuild, bookmark: nil, iCloudDrive: nil)
        return UserFolderSetup(choice: choice, iCloudDrive: nil, canChoose: false, boundary: nil)
    }

    /// The bookmark's folder, as `.iCloud` when it is inside `iCloudDrive`, else `.picked`. Nil when it does not resolve.
    private static func chosen(_ bookmark: Data?, iCloudDrive: URL?) -> UserFolderChoice? {
        guard let bookmark, let url = url(fromBookmark: bookmark)?.url else { return nil }
        if let iCloudDrive, isInside(url, iCloudDrive) { return .iCloud(url) }
        return .picked(url)
    }

    /// A Debug build's folder without `-store`, also when this code runs in a Release build (it then never returns it).
    static var debugLocalFolder: URL {
        URL.applicationSupportDirectory.appending(path: AppPaths.debugFolderName).appending(path: "user")
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` when that folder exists (the Mac build has no sandbox). Nil on
    /// the iPhone: there iCloud Drive is reached through "Choose a folder…". Only a Release build calls it.
    static func iCloudDriveRoot() -> URL? {
        #if os(macOS)
        let drive = URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory) && isDirectory.boolValue ? drive : nil
        #else
        return nil
        #endif
    }

    static func defaultICloudFolder(in drive: URL) -> URL {
        drive.appending(path: iCloudFolderName)
    }

    /// A security-scoped bookmark on the Mac (B6), a plain one on the iPhone. Make it while access to `url` is started.
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder of a bookmark; `stale` says it should be made again. Nil when it does not resolve (the folder is gone).
    static func url(fromBookmark data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// True when `url` is `folder` or inside it, by whole folder names, after `..` and links are resolved. `/private/var`,
    /// `/private/tmp` and `/private/etc` count as `/var`, `/tmp` and `/etc` (Foundation strips `/private` only from a path
    /// that exists). A path that differs only in case counts as outside: the check fails closed.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        func components(_ url: URL) -> [String] {
            var parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            if parts.count > 2, parts[0] == "/", parts[1] == "private", ["var", "tmp", "etc"].contains(parts[2]) {
                parts.remove(at: 1)
            }
            return parts
        }
        let inner = components(url), outer = components(folder)
        return inner.count >= outer.count && Array(inner.prefix(outer.count)) == outer
    }

    /// True when both name one folder, by the rule of `isInside`.
    static func isSameFolder(_ a: URL, _ b: URL) -> Bool { isInside(a, b) && isInside(b, a) }
}
