import Foundation
import Testing
@testable import CedricCore

@Suite struct MarkdownPasteTests {
    @Test func urlOverSelectionMakesALink() {
        func p(_ s: String, _ pasted: String) -> String? { let (t, sel) = caretText(s); return shown(t, MarkdownPaste.linkPaste(in: t, selection: sel, pasted: pasted)) }
        #expect(p("read ‸the docs‸ now", "https://example.com/x?y=1") == "read [the docs](https://example.com/x?y=1)‸ now")
        #expect(p("read ‸the docs‸", " https://x.org\n") == "read [the docs](https://x.org)‸")
        // Not a URL, no selection, a selected URL, several lines, a code span: an ordinary paste.
        #expect(p("read ‸the docs‸", "just text") == nil)
        #expect(p("read ‸", "https://x.org") == nil)
        #expect(p("‸https://a.org‸", "https://x.org") == nil)
        #expect(p("‸a\nb‸", "https://x.org") == nil)
        #expect(p("run `‸ls‸`", "https://x.org") == nil)
        #expect(p("`a` then ‸b‸", "https://x.org") == "`a` then [b](https://x.org)‸")
    }

    @Test func pathsAndNames() {
        let dir = URL(fileURLWithPath: "/tmp/notes")
        #expect(MarkdownPaste.relativePath(of: URL(fileURLWithPath: "/tmp/notes/images/a b.png"), from: dir) == "images/a%20b.png")
        #expect(MarkdownPaste.relativePath(of: URL(fileURLWithPath: "/tmp/notes/x(1).png"), from: dir) == "x%281%29.png")
        #expect(MarkdownPaste.relativePath(of: URL(fileURLWithPath: "/tmp/other/a.png"), from: dir) == nil)
        #expect(MarkdownPaste.relativePath(of: URL(fileURLWithPath: "/tmp/notesX/a.png"), from: dir) == nil)
        let taken: Set = ["a.png", "a-2.png"]
        #expect(MarkdownPaste.uniqueName("a.png") { taken.contains($0) } == "a-3.png")
        #expect(MarkdownPaste.uniqueName("b.png") { taken.contains($0) } == "b.png")
        #expect(MarkdownPaste.isImageFile(URL(fileURLWithPath: "/x/A.JPG")) && !MarkdownPaste.isImageFile(URL(fileURLWithPath: "/x/a.pdf")))
        #expect(MarkdownPaste.imageLinks(["images/a.png", "b.png"]) == "![](images/a.png)\n![](b.png)")
    }
}
