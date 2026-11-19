import Foundation
import Testing
@testable import CedricCore

private func e(_ name: String, dir: Bool = false, hidden: Bool = false) -> FolderEntry {
    FolderEntry(name: name, isDirectory: dir, isHidden: hidden)
}

private func makeTree(_ files: [String], dirs: [String] = []) throws -> URL {
    let root = tempDir()
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for d in dirs { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
    for f in files {
        let u = root.appendingPathComponent(f)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(f.utf8).write(to: u)
    }
    return root
}

@Suite struct FolderTreeTests {
    @Test func foldersFirstThenFinderOrder() {
        let sorted = FolderTree.sorted([e("b.txt"), e("file10.txt"), e("Zed", dir: true), e("file2.txt"), e("alpha", dir: true), e("A.txt")])
        #expect(sorted.map(\.name) == ["alpha", "Zed", "A.txt", "b.txt", "file2.txt", "file10.txt"])
    }

    @Test func hiddenFilter() {
        let all = [e(".git", dir: true, hidden: true), e(".DS_Store", hidden: true), e(".env", hidden: true), e("src", dir: true), e("a.txt")]
        #expect(FolderTree.filter(all, showHidden: false).map(\.name) == ["src", "a.txt"])
        // .git and .DS_Store never show, hidden files on or off.
        #expect(FolderTree.filter(all, showHidden: true).map(\.name) == [".env", "src", "a.txt"])
    }

    @Test func listsOneLevelFilteredAndSorted() throws {
        let root = try makeTree([".git/HEAD", ".DS_Store", ".hidden", "src/deep/x.swift", "b.md", "a10.txt", "a9.txt"], dirs: ["Thing.app/Contents"])
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try FolderTree.list(root)
        #expect(list.map(\.name) == ["src", "a9.txt", "a10.txt", "b.md", "Thing.app"])
        // A package is a file; nothing below the first level is listed.
        #expect(list.first { $0.name == "Thing.app" }?.isDirectory == false)
        #expect(list.first { $0.name == "src" }?.isDirectory == true)
        let withHidden = try FolderTree.list(root, showHidden: true)
        #expect(withHidden.map(\.name) == ["src", ".hidden", "a9.txt", "a10.txt", "b.md", "Thing.app"])
        #expect(withHidden.first { $0.name == ".hidden" }?.isHidden == true)
    }

    @Test func listingAMissingFolderThrows() {
        #expect(throws: (any Error).self) { try FolderTree.list(tempDir()) }
    }

    @Test func diffAddRemoveRename() {
        let old = [e("docs", dir: true), e("a.txt"), e("b.txt"), e("c.txt")]
        // b.txt removed, d.txt added, c.txt renamed to aa.txt.
        let new = FolderTree.sorted([e("docs", dir: true), e("a.txt"), e("aa.txt"), e("d.txt")])
        let d = FolderTree.diff(old: old, new: new)
        #expect(d.removed == [2, 3])
        #expect(d.inserted == [2, 3])
        #expect(FolderTree.diff(old: old, new: old).isEmpty)
        // A file replaced by a folder of the same name: a removal and an insertion.
        let swapped = FolderTree.diff(old: [e("x")], new: [e("x", dir: true)])
        #expect(swapped.removed == [0] && swapped.inserted == [0])
    }

    @Test func diffAppliedInOrderGivesTheNewList() {
        let old = FolderTree.sorted((0..<30).map { e("f\($0).txt") } + [e("d1", dir: true)])
        let new = FolderTree.sorted(old.filter { $0.name.hasSuffix("3.txt") == false } + [e("f100.txt"), e("d0", dir: true)])
        let d = FolderTree.diff(old: old, new: new)
        var rows = old
        for i in d.removed.reversed() { rows.remove(at: i) }
        for i in d.inserted { rows.insert(new[i], at: i) }
        #expect(rows == new)
    }

    @Test func nodesLoadLazilyAndKeepTheirChildrenAcrossRelistings() {
        let root = FolderNode(root: URL(fileURLWithPath: "/p"))
        #expect(!root.isLoaded && root.children == nil)
        root.apply([e("src", dir: true), e("a.txt")])
        #expect(root.isLoaded)
        let src = root.child(named: "src")!
        #expect(!src.isLoaded && src.parent === root)
        #expect(src.url.path == "/p/src")
        src.apply([e("x.swift")])
        // Re-listing the root: src is the same node, still loaded.
        let d = root.apply([e("src", dir: true), e("b.txt")])
        #expect(d == FolderTree.Diff(removed: [1], inserted: [1]))
        #expect(root.child(named: "src") === src && src.isLoaded)
        #expect(root.descendant("src/x.swift")?.url.path == "/p/src/x.swift")
        #expect(root.descendant("nope/x") == nil)
        #expect(root.loadedFolders.map(\.name) == ["p", "src"])
        #expect(src.child(named: "x.swift")?.ancestors.map(\.name) == ["src", "p"])
        src.unload()
        #expect(root.loadedFolders.map(\.name) == ["p"])
    }

    @Test func symlinkLoopGuard() throws {
        let root = try makeTree(["src/a.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("src/up").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("src/self").path, withDestinationPath: ".")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-to-src").path, withDestinationPath: "src")
        let src = root.appendingPathComponent("src")
        let list = try FolderTree.list(src)
        #expect(list.filter(\.isSymlink).map(\.name) == ["self", "up"])
        #expect(list.filter(\.isSymlink).allSatisfy { $0.isDirectory })
        #expect(FolderTree.wouldLoop(src.appendingPathComponent("up"), ancestors: [src, root]))
        #expect(FolderTree.wouldLoop(src.appendingPathComponent("self"), ancestors: [src, root]))
        // A link to a sibling folder is fine to expand.
        #expect(!FolderTree.wouldLoop(root.appendingPathComponent("link-to-src"), ancestors: [root]))
    }

    @Test func relativePaths() {
        let root = URL(fileURLWithPath: "/a/b")
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/a/b"), in: root) == "")
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/a/b/c/d.txt"), in: root) == "c/d.txt")
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/a/bc/d.txt"), in: root) == nil)
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/x"), in: root) == nil)
    }

    @Test(.offPool) func twentyThousandEntriesListQuickly() throws {
        let root = tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<20_000 { fm.createFile(atPath: root.appendingPathComponent("f\(i).txt").path, contents: nil) }
        let start = Date()
        let list = try FolderTree.list(root)
        let elapsed = Date().timeIntervalSince(start)
        #expect(list.count == 20_000)
        #expect(list[1].name == "f1.txt" && list[2].name == "f2.txt")
        // Listed off the main thread in the app; generous for a CI runner.
        #expect(elapsed < 5, "20,000 entries took \(elapsed) s")
    }
}

@Suite struct FolderSessionTests {
    @Test func sessionWithoutAFolderStillDecodes() throws {
        // A 0.1.x session.json: no "folder" key.
        let json = #"{"version": 1, "untitledCounter": 0, "windows": [{"selectedTab": 0, "tabs": [{"id": "7E1C9B3A-1F2D-4C5B-9A8E-0123456789AB", "path": "/tmp/a.txt", "hasBuffer": false, "encoding": "utf8", "lineEnding": "lf", "selectionLocation": 0, "selectionLength": 0, "topLine": 0}]}]}"#
        let s = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(s.folder == nil)
        #expect(s.allTabs.first?.path == "/tmp/a.txt")
    }

    @Test func folderRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let folder = SessionFolder(path: "/Users/x/proj", visible: true, width: 260, expanded: ["src", "src/util"], showHidden: true)
        try store.save(Session(windows: [SessionWindow(tabs: [SessionTab(path: "/tmp/a.txt")])], folder: folder))
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back.folder == folder)
        // A hidden sidebar is kept too (shown again from the menu).
        try store.save(Session(windows: [], folder: SessionFolder(path: "/p", visible: false)))
        #expect(SessionStore(directory: dir).load()?.folder?.visible == false)
    }

    @Test func expandedFoldersAreCapped() {
        let f = SessionFolder(path: "/p", expanded: (0..<500).map { "d\($0)" })
        #expect(f.expanded?.count == SessionFolder.expandedLimit)
        #expect(f.expanded?.first == "d0")
    }
}
