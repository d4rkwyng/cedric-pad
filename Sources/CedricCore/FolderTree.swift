import Foundation

/// One entry of a folder listing, as the folder sidebar shows it.
public struct FolderEntry: Equatable, Hashable, Sendable {
    public var name: String
    /// A folder the sidebar can expand (packages are files; a symbolic
    /// link to a folder is a folder, flagged `isSymlink`).
    public var isDirectory: Bool
    /// A dot file or a file with the hidden flag.
    public var isHidden: Bool
    public var isSymlink: Bool

    public init(name: String, isDirectory: Bool, isHidden: Bool = false, isSymlink: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
    }

    /// What a re-listing matches entries by: a file that became a folder
    /// of the same name is a remove and an insert.
    public var key: String { (isDirectory ? "d:" : "f:") + name }
}

/// The folder sidebar's model (plan-0.2.0.md §6): listing one folder
/// (only folders the user expands are listed), Finder's order, the hidden
/// filter, diffing a re-listing against what is shown, and the symlink
/// loop guard. Foundation only; the app lists off the main thread.
public enum FolderTree {
    /// Never shown, hidden files on or off.
    public static let alwaysHidden: Set<String> = [".git", ".DS_Store"]

    /// The entries of `url`, filtered and sorted. Throws if the folder
    /// can't be read. Doesn't recurse.
    public static func list(_ url: URL, showHidden: Bool = false) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        var out: [FolderEntry] = []
        out.reserveCapacity(urls.count)
        for u in urls {
            let name = u.lastPathComponent
            if alwaysHidden.contains(name) { continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            let hidden = v?.isHidden ?? name.hasPrefix(".")
            if hidden && !showHidden { continue }
            let link = v?.isSymbolicLink ?? false
            var dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            if link {
                // A link to a folder (not a package) can be expanded; the
                // loop guard stops it at an ancestor.
                var isDir: ObjCBool = false
                dir = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
                    && !isPackage(u.resolvingSymlinksInPath())
            }
            out.append(FolderEntry(name: name, isDirectory: dir, isHidden: hidden, isSymlink: link))
        }
        return sorted(out)
    }

    private static func isPackage(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    /// `entries` without the always-hidden names, and without hidden ones
    /// unless `showHidden`.
    public static func filter(_ entries: [FolderEntry], showHidden: Bool) -> [FolderEntry] {
        entries.filter { !alwaysHidden.contains($0.name) && (showHidden || !$0.isHidden) }
    }

    /// Finder's order: folders first, then names compared as Finder does
    /// (numbers by value, case-insensitive).
    public static func sorted(_ entries: [FolderEntry]) -> [FolderEntry] {
        entries.sorted(by: precedes)
    }

    public static func precedes(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name < b.name
        }
    }

    /// How a re-listing differs from what is shown: indexes into `old`
    /// that went (apply first) and indexes into `new` that came. Both
    /// lists are in `sorted` order, so the entries kept keep their order
    /// and an outline view can apply the two steps in turn without
    /// disturbing the rows (and expansion) in between. A rename is one
    /// removal and one insertion.
    public struct Diff: Equatable, Sendable {
        public var removed: [Int]
        public var inserted: [Int]
        public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
        public init(removed: [Int], inserted: [Int]) { self.removed = removed; self.inserted = inserted }
    }

    public static func diff(old: [FolderEntry], new: [FolderEntry]) -> Diff {
        let newKeys = Set(new.map(\.key)), oldKeys = Set(old.map(\.key))
        return Diff(removed: old.indices.filter { !newKeys.contains(old[$0].key) },
                    inserted: new.indices.filter { !oldKeys.contains(new[$0].key) })
    }

    /// True if expanding `url` would loop: its real path (symbolic links
    /// resolved) is that of one of `ancestors` (the folders above it).
    public static func wouldLoop(_ url: URL, ancestors: [URL]) -> Bool {
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        return ancestors.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == real }
    }

    /// `url`'s path relative to `root` ("" for the root itself), or nil if
    /// it isn't inside it.
    public static func relativePath(of url: URL, in root: URL) -> String? {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        if p == r { return "" }
        let prefix = r.hasSuffix("/") ? r : r + "/"
        guard p.hasPrefix(prefix) else { return nil }
        return String(p.dropFirst(prefix.count))
    }
}

/// One row of the folder tree. `children` is nil until the folder has
/// been listed (lazy loading); a re-listing keeps the nodes that stayed,
/// so their own loaded children and expansion survive.
public final class FolderNode {
    public let url: URL
    public private(set) var entry: FolderEntry
    public private(set) weak var parent: FolderNode?
    public private(set) var children: [FolderNode]?
    /// A listing is under way (the app shows nothing new until it lands).
    public var isLoading = false
    /// The folder couldn't be read (permissions); shown empty.
    public var loadError: String?

    public init(url: URL, entry: FolderEntry, parent: FolderNode? = nil) {
        self.url = url
        self.entry = entry
        self.parent = parent
    }

    /// The root of a tree: `url`, a folder.
    public convenience init(root url: URL) {
        self.init(url: url, entry: FolderEntry(name: url.lastPathComponent, isDirectory: true))
    }

    public var name: String { entry.name }
    public var isDirectory: Bool { entry.isDirectory }
    public var isLoaded: Bool { children != nil }

    /// The folders above this one, nearest first.
    public var ancestors: [FolderNode] {
        var out: [FolderNode] = []
        var p = parent
        while let n = p { out.append(n); p = n.parent }
        return out
    }

    /// Takes a listing of this folder. Returns the change against what was
    /// loaded before (everything inserted on the first listing).
    @discardableResult
    public func apply(_ listing: [FolderEntry]) -> FolderTree.Diff {
        let old = children ?? []
        let d = FolderTree.diff(old: old.map(\.entry), new: listing)
        var byKey: [String: FolderNode] = [:]
        for c in old { byKey[c.entry.key] = c }
        children = listing.map { e in
            if let kept = byKey[e.key] { kept.entry = e; return kept }
            return FolderNode(url: url.appendingPathComponent(e.name, isDirectory: e.isDirectory), entry: e, parent: self)
        }
        return d
    }

    /// Forgets the listing (the folder reads as not loaded again).
    public func unload() { children = nil }

    /// The child with this name, if loaded.
    public func child(named name: String) -> FolderNode? { children?.first { $0.name == name } }

    /// The node at `relativePath` below this one, walking only loaded folders.
    public func descendant(_ relativePath: String) -> FolderNode? {
        var n: FolderNode? = self
        for part in relativePath.split(separator: "/") where !part.isEmpty {
            n = n?.child(named: String(part))
        }
        return n
    }

    /// Every loaded folder in this subtree, this one first, parents before children.
    public var loadedFolders: [FolderNode] {
        guard let children else { return [] }
        return [self] + children.flatMap(\.loadedFolders)
    }
}
