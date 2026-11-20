import Foundation
import Testing
@testable import CedricCore

/// A hostile repository must never make Cedric's git run a program
/// (security audit H1): config keys that name commands are refused, and
/// the commands Cedric runs never invoke fsmonitor, filters, textconv or
/// anything an includeIf pulls in.
@Suite(.offPool) struct GitSafetyTests {
    @Test func parsesScopedConfig() {
        let z = "global\0filter.lfs.clean\ngit-lfs clean -- %f\0local\0core.bare\nfalse\0local\0x.flag\0command\0core.fsmonitor\nfalse\0"
        let e = GitConfigSafety.parse(z)
        #expect(e.count == 4)
        #expect(e[2] == .init(scope: "local", key: "x.flag", value: nil))
        #expect(GitConfigSafety.dangerousKeys(e).isEmpty, "global and command-line scopes are trusted")
    }

    @Test func dangerousKeys() {
        func bad(_ k: String, _ v: String? = "x") -> Bool { GitConfigSafety.isDangerous(key: k, value: v) }
        #expect(bad("core.fsmonitor", "touch /tmp/m"))
        #expect(!bad("core.fsmonitor", "true") && !bad("core.fsmonitor", "false"), "a boolean is git's own daemon")
        #expect(bad("core.sshCommand") && bad("core.gitProxy") && bad("core.pager") && bad("core.editor"))
        #expect(bad("filter.evil.clean") && bad("filter.evil.smudge") && bad("filter.evil.process"))
        #expect(bad("filter.lfs.clean", "sh -c evil"))
        #expect(!bad("filter.lfs.clean", "git-lfs clean -- %f") && !bad("filter.lfs.process", "git-lfs filter-process"))
        #expect(bad("diff.evil.textconv") && bad("diff.evil.command") && bad("diff.external"))
        #expect(bad("merge.x.driver") && bad("credential.helper") && bad("credential.https://h.helper"))
        #expect(bad("gpg.program") && bad("gpg.ssh.program") && bad("pager.log") && bad("remote.origin.uploadpack"))
        #expect(bad("uploadpack.packObjectsHook") && bad("gc.recentObjectsHook"))
        #expect(bad("Filter.Evil.CLEAN"), "section and name are case-insensitive")
        #expect(!bad("core.bare") && !bad("remote.origin.url") && !bad("branch.main.merge") && !bad("core.hooksPath", "/x"), "hooksPath is pinned to /dev/null; husky repos set it")
        #expect(!bad("filter.evil.required") && !bad("diff.evil.binary"))
    }

    @Test func safetyArgsOnEveryCall() {
        #expect(GitRunner.safetyArgs.contains("core.fsmonitor=false"))
        #expect(GitRunner.safetyArgs.contains("core.hooksPath=/dev/null"))
        #expect(GitRunner.safetyArgs.contains("diff.external="))
        #expect(GitRunner.safetyArgs.contains("gc.auto=0"))
        #expect(GitRunner.safetyArgs.contains("maintenance.auto=false"))
        var env = ["GIT_CONFIG_PARAMETERS": "x", "GIT_EXTERNAL_DIFF": "y", "PATH": "/usr/bin"]
        GitRunner.applyGitSafety(to: &env)
        #expect(env["GIT_NO_LAZY_FETCH"] == "1")
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_CONFIG_PARAMETERS"] == nil && env["GIT_EXTERNAL_DIFF"] == nil)
    }

    /// The audit's PoC repo plus a textconv driver and an includeIf'd file.
    func hostileRepo(_ root: URL, markers: URL) throws -> URL {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        #expect(GitRunner.run(["init", "-q", "-b", "main"], cwd: repo)?.status == 0)
        try "hi\n".write(to: repo.appendingPathComponent("src/a.md"), atomically: true, encoding: .utf8)
        try "*.md filter=evil diff=evil\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        #expect(GitRunner.run(["add", "."], cwd: repo)?.status == 0)
        #expect(GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "x"], cwd: repo)?.status == 0)
        let m = markers.path
        let cfg = repo.appendingPathComponent(".git/config")
        let inc = repo.appendingPathComponent(".git/evil.inc")
        try "[core]\n\tfsmonitor = \"touch \(m)/inc-fsmonitor; false\"\n[filter \"inc\"]\n\tclean = \"touch \(m)/inc-clean; cat\"\n"
            .write(to: inc, atomically: true, encoding: .utf8)
        var c = try String(contentsOf: cfg, encoding: .utf8)
        c += "[core]\n\tfsmonitor = \"touch \(m)/fsmonitor; false\"\n"
        c += "[filter \"evil\"]\n\tclean = \"touch \(m)/clean; cat\"\n\tsmudge = \"touch \(m)/smudge; cat\"\n"
        c += "[diff \"evil\"]\n\ttextconv = \"touch \(m)/textconv; cat\"\n"
        c += "[includeIf \"gitdir:\((realpath(repo.path, nil).map { String(cString: $0) } ?? repo.path))/.git\"]\n\tpath = \(inc.path)\n"
        try c.write(to: cfg, atomically: true, encoding: .utf8)
        // Stat data no longer matches the index (as after an unzip) and the
        // content changed: a `git status` would run the clean filter.
        try "hi\nmore\n".write(to: repo.appendingPathComponent("src/a.md"), atomically: true, encoding: .utf8)
        return repo
    }

    func markersIn(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    @Test func hostileRepoIsRefusedAndRunsNothing() throws {
        guard GitRunner.executable != nil else { return }
        let root = tempDir(), markers = root.appendingPathComponent("markers")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let repo = try hostileRepo(root, markers: markers)
        let file = repo.appendingPathComponent("src/a.md")
        let p = GitProbe.probe(file: file, location: GitLocation.find(for: file)!)
        #expect(p?.refused == true)
        let keys = Set(p?.refusedKeys.map { $0.lowercased() } ?? [])
        #expect(keys.isSuperset(of: ["core.fsmonitor", "filter.evil.clean", "filter.evil.smudge", "diff.evil.textconv", "filter.inc.clean"]),
                "includeIf'd keys are seen too")
        print("refused keys: \(keys.sorted())")
        // The second layer: even with the refusal bypassed, the commands the
        // probe uses run nothing.
        let dir = repo.appendingPathComponent("src")
        let id = GitRunner.run(["rev-parse", "-q", "--verify", "HEAD:src/a.md"], cwd: dir)
        #expect(id?.status == 0)
        #expect(GitRunner.run(["cat-file", "blob", id!.text.trimmingCharacters(in: .whitespacesAndNewlines)], cwd: dir)?.text == "hi\n")
        _ = GitRunner.run(["ls-files", "-z", "--", "a.md"], cwd: dir)
        _ = GitRunner.run(["ls-files", "-z", "-o", "-i", "--exclude-standard", "--", "a.md"], cwd: dir)
        _ = GitRunner.run(["rev-parse", "--show-prefix"], cwd: dir)
        #expect(markersIn(markers).isEmpty, "no repository program ran: \(markersIn(markers))")
        // Sanity: the PoC is real (plain git status runs fsmonitor).
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: GitRunner.executable!)
        plain.arguments = ["status", "--porcelain"]
        plain.currentDirectoryURL = repo
        plain.standardOutput = FileHandle.nullDevice
        plain.standardError = FileHandle.nullDevice
        try plain.run()
        plain.waitUntilExit()
        #expect(!markersIn(markers).isEmpty, "an unprotected git status does run them (the PoC)")
    }

    /// An `[include]`'d file that sets `gc.recentObjectsHook` must be refused
    /// by the real probe (`git config --list --includes`), and the hook must
    /// not run (GHSA-h2g3-rwxm-xfm3).
    @Test func includedRecentObjectsHookIsHostile() throws {
        guard GitRunner.executable != nil else { return }
        let root = tempDir(), markers = root.appendingPathComponent("markers")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(GitRunner.run(["init", "-q", "-b", "main"], cwd: repo)?.status == 0)
        try "x\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let marker = markers.appendingPathComponent("gc-hook").path
        try "[gc]\n\trecentObjectsHook = \"touch \(marker); false\"\n"
            .write(to: repo.appendingPathComponent(".git/evil.inc"), atomically: true, encoding: .utf8)
        let cfg = repo.appendingPathComponent(".git/config")
        var c = try String(contentsOf: cfg, encoding: .utf8)
        c += "[include]\n\tpath = evil.inc\n"
        try c.write(to: cfg, atomically: true, encoding: .utf8)
        let file = repo.appendingPathComponent("a.txt")
        let loc = try #require(GitLocation.find(for: file))
        let p = try #require(GitProbe.probe(file: file, location: loc))
        #expect(p.refused)
        let refused = Set(p.refusedKeys.map { $0.lowercased() })
        #expect(refused.contains("gc.recentobjectshook"), "included hook is seen: \(refused.sorted())")
        #expect(markersIn(markers).isEmpty, "the hook did not run: \(markersIn(markers))")
    }

    @Test func probeWithoutStatus() throws {
        guard GitRunner.executable != nil else { return }
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("r")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("s:d"), withIntermediateDirectories: true)
        #expect(GitRunner.run(["init", "-q", "-b", "main"], cwd: repo)?.status == 0)
        let colon = repo.appendingPathComponent("s:d/HEAD:a:b.txt")
        try "one\n".write(to: colon, atomically: true, encoding: .utf8)
        try "x\n".write(to: repo.appendingPathComponent("s:d/staged.txt"), atomically: true, encoding: .utf8)
        try "ign.txt\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(GitRunner.run(["add", "s:d/HEAD:a:b.txt", ".gitignore"], cwd: repo)?.status == 0)
        #expect(GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "x"], cwd: repo)?.status == 0)
        #expect(GitRunner.run(["config", "branch.main.merge", "refs/heads/main"], cwd: repo)?.status == 0)
        #expect(GitRunner.run(["config", "remote.origin.url", "git@github.com:o/r.git"], cwd: repo)?.status == 0)
        let loc = GitLocation.find(for: colon)!
        var p = try #require(GitProbe.probe(file: colon, location: loc))
        #expect(!p.refused && p.status.branch == "main" && p.status.upstream == "refs/heads/main" && p.status.headSHA?.count == 40)
        #expect(p.relativePath == "s:d/HEAD:a:b.txt", "a name with colons")
        #expect(p.base == Data("one\n".utf8) && !p.status.changed && !p.status.untracked)
        #expect(p.remoteURL == "git@github.com:o/r.git")
        try "two\n".write(to: colon, atomically: true, encoding: .utf8)
        let cached = (id: p.blobID!, data: p.base!)
        p = try #require(GitProbe.probe(file: colon, location: loc, cached: cached))
        #expect(p.status.changed && p.base == cached.data, "changed on disk: dirty; the cached blob is reused")
        // Staged only: in the index, not in HEAD.
        #expect(GitRunner.run(["add", "s:d/staged.txt"], cwd: repo)?.status == 0)
        p = try #require(GitProbe.probe(file: repo.appendingPathComponent("s:d/staged.txt"), location: loc))
        #expect(p.base == Data() && p.status.changed && !p.status.untracked)
        let un = repo.appendingPathComponent("s:d/new.txt")
        try "n\n".write(to: un, atomically: true, encoding: .utf8)
        p = try #require(GitProbe.probe(file: un, location: loc))
        #expect(p.base == nil && p.status.untracked && p.status.changed)
        let ig = repo.appendingPathComponent("s:d/ign.txt")
        try "i\n".write(to: ig, atomically: true, encoding: .utf8)
        p = try #require(GitProbe.probe(file: ig, location: loc))
        #expect(p.base == nil && p.status.ignored && !p.status.changed)
    }
}
