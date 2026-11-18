import Foundation
import Testing
@testable import CedricCore

@Suite struct GitRemoteTests {
    @Test func httpsAndSSHForms() {
        let want = GitHubRemote(host: "github.com", owner: "d4rkwyng", repo: "cedric")
        #expect(GitHubRemote.parse("https://github.com/d4rkwyng/cedric.git") == want)
        #expect(GitHubRemote.parse("https://github.com/d4rkwyng/cedric") == want)
        #expect(GitHubRemote.parse("https://github.com/d4rkwyng/cedric/") == want)
        #expect(GitHubRemote.parse("git@github.com:d4rkwyng/cedric.git") == want)
        #expect(GitHubRemote.parse("git@github.com:d4rkwyng/cedric") == want)
        #expect(GitHubRemote.parse("ssh://git@github.com/d4rkwyng/cedric.git") == want)
        #expect(GitHubRemote.parse("ssh://git@github.com:22/d4rkwyng/cedric.git") == want)
        #expect(GitHubRemote.parse("git://github.com/d4rkwyng/cedric.git") == want)
        // Credentials in an https URL are dropped, the host lower-cased.
        #expect(GitHubRemote.parse("https://user:tok@GitHub.com/d4rkwyng/cedric.git\n") == want)
    }

    @Test func enterpriseHostsAndOthers() {
        #expect(GitHubRemote.parse("git@github.example.com:team/tool.git") == GitHubRemote(host: "github.example.com", owner: "team", repo: "tool"))
        #expect(GitHubRemote.parse("https://github.corp.local/team/tool") == GitHubRemote(host: "github.corp.local", owner: "team", repo: "tool"))
        // Not GitHub, or not a repository URL.
        #expect(GitHubRemote.parse("git@gitlab.com:team/tool.git") == nil)
        #expect(GitHubRemote.parse("/Users/me/repos/tool.git") == nil)
        #expect(GitHubRemote.parse("file:///srv/git/tool.git") == nil)
        #expect(GitHubRemote.parse("https://github.com/onlyowner") == nil)
        #expect(GitHubRemote.parse("https://github.com/a/b/c") == nil)
        #expect(GitHubRemote.parse("") == nil)
    }

    @Test func blobLinks() {
        let r = GitHubRemote(host: "github.com", owner: "o", repo: "r")
        #expect(r.blobURL(ref: "main", path: "Sources/App/main.swift") == "https://github.com/o/r/blob/main/Sources/App/main.swift")
        #expect(r.blobURL(ref: "main", path: "a.txt", lines: 10...10) == "https://github.com/o/r/blob/main/a.txt#L10")
        #expect(r.blobURL(ref: "feature/x", path: "a.txt", lines: 10...20) == "https://github.com/o/r/blob/feature/x/a.txt#L10-L20")
        #expect(r.blobURL(ref: "abc123", path: "docs/my notes#1.md") == "https://github.com/o/r/blob/abc123/docs/my%20notes%231.md")
    }
}

@Suite struct GitStatusTests {
    @Test func headFile() {
        #expect(GitHead.parse("ref: refs/heads/main\n") == .branch("main"))
        #expect(GitHead.parse("ref: refs/heads/feature/x") == .branch("feature/x"))
        #expect(GitHead.parse("0123456789abcdef0123456789abcdef01234567\n") == .detached("0123456789abcdef0123456789abcdef01234567"))
        #expect(GitHead.parse("garbage") == nil)
    }

    @Test func porcelainV2() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        var s = GitFileStatus.parse(porcelainV2: "# branch.oid \(sha)\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0")
        #expect(s.headSHA == sha && s.branch == "main" && s.upstream == "origin/main" && !s.changed && s.label == "main")
        s = GitFileStatus.parse(porcelainV2: "# branch.oid \(sha)\0# branch.head (detached)\01 .M N... 100644 100644 100644 a b a.txt\0")
        #expect(s.branch == nil && s.changed && !s.untracked && s.label == "0123456")
        s = GitFileStatus.parse(porcelainV2: "# branch.oid (initial)\0# branch.head main\0? new.txt\0")
        #expect(s.headSHA == nil && s.changed && s.untracked && s.upstream == nil)
        s = GitFileStatus.parse(porcelainV2: "# branch.oid \(sha)\0# branch.head main\02 R. N... 100644 100644 100644 a a R100 new.txt\0old.txt\0")
        #expect(s.changed && !s.untracked)
    }
}

@Suite struct GitLocationTests {
    func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func walksUpToDotGitFolderAndFile() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let deep = repo.appendingPathComponent("a/b/c")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let loc = GitLocation.find(for: deep.appendingPathComponent("x.txt"))
        #expect(loc?.workTree.path == repo.standardizedFileURL.path)
        #expect(loc?.gitDir.path == repo.appendingPathComponent(".git").standardizedFileURL.path)
        // Outside any repository.
        let other = root.appendingPathComponent("plain")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(GitLocation.find(for: other.appendingPathComponent("y.txt")) == nil)
        // An empty .git folder (no HEAD) isn't a repository.
        let fake = root.appendingPathComponent("fake")
        try fm.createDirectory(at: fake.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(GitLocation.find(for: fake.appendingPathComponent("z.txt")) == nil)
        // A linked work tree: .git is a file pointing at the real git dir (relative here).
        let wt = root.appendingPathComponent("wt")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: ../repo/.git/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let wl = GitLocation.find(for: wt.appendingPathComponent("f.txt"))
        #expect(wl?.workTree.path == wt.standardizedFileURL.path)
        #expect(wl?.gitDir.path == repo.appendingPathComponent(".git/worktrees/wt").standardizedFileURL.path)
    }

    @Test(.offPool) func realRepositoryAndWorktree() throws {
        guard GitRunner.executable != nil else { return }
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        #expect(GitRunner.run(["init", "-q", "-b", "main"], cwd: repo)?.status == 0)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        #expect(GitRunner.run(["add", "."], cwd: repo)?.status == 0)
        #expect(GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "x"], cwd: repo)?.status == 0)
        let loc = GitLocation.find(for: repo.appendingPathComponent("src/a.txt"))
        #expect(loc?.workTree.path == repo.standardizedFileURL.path)
        #expect(GitHead.parse((try? String(contentsOf: loc!.gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? "") == .branch("main"))
        let st = GitRunner.run(["status", "--porcelain=v2", "--branch", "-z", "--", "a.txt"], cwd: repo.appendingPathComponent("src"))
        let parsed = GitFileStatus.parse(porcelainV2: st?.text ?? "")
        #expect(parsed.branch == "main" && parsed.headSHA?.count == 40 && !parsed.changed)
        // A linked work tree: its own HEAD and index under .git/worktrees/<name>.
        let wt = root.appendingPathComponent("wt")
        #expect(GitRunner.run(["worktree", "add", "-q", "-b", "side", wt.path], cwd: repo)?.status == 0)
        let wl = GitLocation.find(for: wt.appendingPathComponent("src/a.txt"))
        #expect(wl?.workTree.path == wt.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: wl!.gitDir.appendingPathComponent("HEAD").path))
        #expect(GitHead.parse((try? String(contentsOf: wl!.gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? "") == .branch("side"))
    }
}

@Suite struct GitLineChangesTests {
    typealias C = GitLineChanges

    @Test func none() {
        #expect(C.compute(base: "a\nb\nc\n", current: "a\nb\nc\n").isEmpty)
    }

    @Test func addedModifiedDeleted() {
        // b changed, x added after it, d deleted.
        let c = C.compute(base: "a\nb\nc\nd\ne\n", current: "a\nB\nx\nc\ne\n")
        #expect(c.lines == [1: .modified, 2: .added])
        #expect(c.deletedBefore == [4])
    }

    @Test func insertAtTopAndAppend() {
        var c = C.compute(base: "a\nb\n", current: "new\na\nb\n")
        #expect(c.lines == [0: .added] && c.deletedBefore.isEmpty)
        c = C.compute(base: "a\nb\n", current: "a\nb\nc\nd\n")
        #expect(c.lines == [2: .added, 3: .added])
    }

    @Test func deletedAtStartAndEnd() {
        var c = C.compute(base: "a\nb\nc\n", current: "b\nc\n")
        #expect(c.lines.isEmpty && c.deletedBefore == [0])
        c = C.compute(base: "a\nb\nc\n", current: "a\nb\n")
        #expect(c.lines.isEmpty && c.deletedBefore == [2])
    }

    @Test func moreDeletedThanInserted() {
        // Three lines replaced by one: one modified line and a deleted mark after it.
        let c = C.compute(base: "a\nb\nc\nd\ne\n", current: "a\nX\ne\n")
        #expect(c.lines == [1: .modified])
        #expect(c.deletedBefore == [2])
    }

    @Test func emptyBaseAndCurrent() {
        #expect(C.compute(base: "", current: "a\nb").lines == [0: .added, 1: .added])
        #expect(C.compute(base: "a\nb\n", current: "").deletedBefore == [0])
    }

    @Test func shiftFollowsEdits() {
        var c = C()
        c.lines = [1: .modified, 5: .added]
        c.deletedBefore = [3, 8]
        // Two lines inserted at line 2: marks below move down.
        c.shift(fromLine: 2, by: 2)
        #expect(c.lines == [1: .modified, 7: .added] && c.deletedBefore == [5, 10])
        // Three lines removed after line 4: marks inside the removed span go.
        c.shift(fromLine: 4, by: -3)
        #expect(c.lines == [1: .modified] && c.deletedBefore == [7])
    }
}
