import Foundation
import Testing
@testable import CedricCore

/// Export-flavoured output (wikilinks and embeds by relative path), data-line stripped.
private func ex(_ s: String, vault: WikiVault?) -> String {
    Markdown.render(s, options: .export(vault: vault)).replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
}

private func put(_ root: URL, _ rel: String, _ text: String) throws {
    let u = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: u)
}

@Suite struct ObsidianExportTests {
    @Test func relativeHrefs() {
        let f = URL(fileURLWithPath: "/Users/x/vault/notes")
        #expect(WikiVault.relativeHref(URL(fileURLWithPath: "/Users/x/vault/notes/Other.md"), from: f) == "Other.md")
        #expect(WikiVault.relativeHref(URL(fileURLWithPath: "/Users/x/vault/notes/sub/Deep.md"), from: f) == "sub/Deep.md")
        #expect(WikiVault.relativeHref(URL(fileURLWithPath: "/Users/x/vault/att/my pic#1.png"), from: f) == "../att/my%20pic%231.png")
        #expect(WikiVault.relativeHref(URL(fileURLWithPath: "/Users/x/other/a.md"), from: f) == "../../other/a.md")
    }

    @Test func wikilinksBecomeRelativeLinksOrPlainText() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/x/Target.md", "v/notes/Other Note.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("v/notes"))
        let html = ex("See [[Target|the target]], [[Other Note#Setup]] and [[Missing|gone]].", vault: vault)
        #expect(html == "<p>See <a class=\"wikilink\" href=\"../x/Target.md\">the target</a>, <a class=\"wikilink\" href=\"Other%20Note.md\">Other Note › Setup</a> and gone.</p>\n")
        #expect(!html.contains("cedric-doc"))
    }

    /// Building the note-name index first (as Copy as Rich Text does, off the
    /// main thread) leaves the exported HTML the same as a cold vault.
    @Test func aWarmedIndexExportsTheSameHtml() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/x/Target.md", "v/notes/Other Note.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let folder = t.appendingPathComponent("v/notes")
        let md = "See [[Target|the target]], [[Other Note#Setup]] and [[Missing|gone]]."
        let golden = "<p>See <a class=\"wikilink\" href=\"../x/Target.md\">the target</a>, <a class=\"wikilink\" href=\"Other%20Note.md\">Other Note › Setup</a> and gone.</p>\n"
        let cold = WikiVault(documentFolder: folder)
        let warm = WikiVault(documentFolder: folder)
        #expect(!warm.indexIsFresh)
        DispatchQueue.global(qos: .userInitiated).sync { warm.prepareIndex() }
        #expect(warm.indexIsFresh)
        #expect(ex(md, vault: cold) == golden)
        #expect(ex(md, vault: warm) == golden)
    }

    @Test func imageEmbedsBecomeRelativeSources() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/attachments/pic one.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("v/notes"))
        let html = ex("![[pic one.png|300]]", vault: vault)
        #expect(html.contains(#"<img class="embed" src="../attachments/pic%20one.png" alt="pic one.png" width="300">"#), "\(html)")
        #expect(!html.contains("cedric-doc"))
    }

    @Test func noteTransclusionsAreInlinedWithRelativeLinks() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/img/dot.png", "v/Far.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        try put(t, "v/ref/Setup Guide.md", "# Setup Guide\n\nIntro.\n\n## Install\n\nRun **make** and see [[Far]].\n\n![[dot.png]]\n\n![[Far]]\n\n## Other\n\nNot this.\n")
        let vault = WikiVault(documentFolder: t.appendingPathComponent("v/notes"))
        let html = ex("![[Setup Guide#Install]]", vault: vault)
        #expect(html.contains(#"<blockquote class="embed"><p class="embed-title"><a class="wikilink" href="../ref/Setup%20Guide.md">Setup Guide › Install</a></p>"#), "\(html)")
        #expect(html.contains("Run <strong>make</strong> and see <a class=\"wikilink\" href=\"../Far.md\">Far</a>."), "the note's text, rendered")
        #expect(html.contains(#"<img class="embed" src="../img/dot.png""#), "an image inside the embedded note, relative to the document")
        #expect(!html.contains("<blockquote class=\"embed\"><p class=\"embed-title\"><a class=\"wikilink\" href=\"../Far.md\""),
                "a note embedded in the embedded note stays a link")
        #expect(!html.contains("Not this") && !html.contains("cedric-doc"))
    }

    @Test func withoutAVaultNothingPointsIntoTheApp() {
        let html = ex("[[Note]] [[Note|alias]] ![[pic.png]]", vault: nil)
        #expect(html == "<p>Note alias ![[pic.png]]</p>\n")
    }

    @Test func previewKeepsInAppLinks() throws {
        let t = try makeTree(["n/doc.md", "n/Note.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("n"))
        let p = Markdown.render("[[Note]] [[Gone]]", options: .preview(vault: vault))
        #expect(p.contains(#"href="cedric-doc://doc"#) && p.contains("is-unresolved"))
    }
}
