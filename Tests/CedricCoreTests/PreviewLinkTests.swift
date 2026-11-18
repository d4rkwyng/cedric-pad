import Foundation
import Testing
@testable import CedricCore

/// Security audit H2: preview links never launch anything.
@Suite struct PreviewLinkTests {
    func isText(_ u: URL) -> Bool { ["md", "txt", "command", "sh"].contains(u.pathExtension) }

    @Test func linksAreConfined() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("doc"), out = root.appendingPathComponent("out")
        let fm = FileManager.default
        try fm.createDirectory(at: doc.appendingPathComponent("Setup.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        for f in ["doc/a.md", "doc/build.command", "doc/x.pkg", "out/secret.md", "out/run.command"] {
            try "x".write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(at: doc.appendingPathComponent("link.md"), withDestinationURL: out.appendingPathComponent("secret.md"))
        func act(_ s: String) -> PreviewLinkAction { PreviewLinkAction.action(for: URL(string: s)!, folder: doc, isText: isText) }
        let page = PreviewFolder.pageURL(for: doc)!.absoluteString
        #expect(act("https://example.com/x?y=1") == .confirmExternal(URL(string: "https://example.com/x?y=1")!))
        #expect(act("mailto:a@example.com") == .confirmExternal(URL(string: "mailto:a@example.com")!))
        #expect(act(page + "a.md") == .openInCedric(doc.appendingPathComponent("a.md").standardizedFileURL))
        // A script opens as text in Cedric (never runs); an app, a package: shown only.
        #expect(act(page + "build.command") == .openInCedric(doc.appendingPathComponent("build.command").standardizedFileURL))
        #expect(act(page + "Setup.app") == .revealInFinder(doc.appendingPathComponent("Setup.app").standardizedFileURL))
        #expect(act(page + "x.pkg") == .revealInFinder(doc.appendingPathComponent("x.pkg").standardizedFileURL))
        // Outside the folder (.., an absolute path, a symlink, file:): shown, never read.
        #expect(act(page + "../out/secret.md") == .revealInFinder(out.appendingPathComponent("secret.md").standardizedFileURL))
        #expect(act("cedric-doc://doc" + out.path + "/run.command") == .revealInFinder(out.appendingPathComponent("run.command").standardizedFileURL))
        if case .revealInFinder = act(page + "link.md") {} else { Issue.record("a symlink out of the folder is only revealed") }
        #expect(act(URL(fileURLWithPath: out.path + "/secret.md").absoluteString) == .revealInFinder(out.appendingPathComponent("secret.md").standardizedFileURL))
        if case .openInCedric = act(URL(fileURLWithPath: doc.path + "/a.md").absoluteString) {} else { Issue.record("file: inside opens") }
        // Everything else: ignored.
        for s in ["smb://attacker/share", "x-apple.systempreferences:com.apple.Security", "ftp://h/x", "javascript:alert(1)", "vnc://h", "https:///nohost"] {
            if case .ignore = act(s) {} else { Issue.record("\(s) must be ignored") }
        }
        if case .ignore = act(page + "nothere.md") {} else { Issue.record("a missing file is ignored") }
        // Untitled (no folder): a local file is only revealed.
        #expect(PreviewLinkAction.action(for: URL(fileURLWithPath: doc.path + "/a.md"), folder: nil, isText: isText) == .revealInFinder(doc.appendingPathComponent("a.md").standardizedFileURL))
    }
}
