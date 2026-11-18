import Foundation
import Testing
@testable import CedricCore

@Suite struct LineOperationsTests {
    func r(_ l: Int, _ n: Int = 0) -> NSRange { NSRange(location: l, length: n) }
    func apply(_ e: TextEdit?, _ t: String) -> String { e.map { $0.applied(to: t) } ?? t }

    @Test func lineBlockCoversWholeLines() {
        let t = "one\ntwo\nthree" as NSString
        #expect(LineOperations.lineBlock(r(5), in: t) == r(4, 4))
        #expect(LineOperations.lineBlock(r(1, 5), in: t) == r(0, 8))
        // Ending at the start of a line doesn't take that line.
        #expect(LineOperations.lineBlock(r(0, 4), in: t) == r(0, 4))
        #expect(LineOperations.lineBlock(r(10), in: t) == r(8, 5))
    }

    @Test func duplicate() {
        let t = "one\ntwo\nthree"
        let e = LineOperations.duplicate(r(5), in: t as NSString)
        #expect(apply(e, t) == "one\ntwo\ntwo\nthree")
        #expect(e.selection == r(9))
        // The last line (no newline) and a two-line selection.
        #expect(apply(LineOperations.duplicate(r(9), in: t as NSString), t) == "one\ntwo\nthree\nthree")
        let two = LineOperations.duplicate(r(1, 4), in: t as NSString)
        #expect(apply(two, t) == "one\ntwo\none\ntwo\nthree")
        #expect(two.selection == r(9, 4))
    }

    @Test func moveUpAndDown() {
        let t = "one\ntwo\nthree"
        let up = LineOperations.moveUp(r(5), in: t as NSString)
        #expect(apply(up, t) == "two\none\nthree")
        #expect(up?.selection == r(1))
        #expect(LineOperations.moveUp(r(1), in: t as NSString) == nil)
        // The last line, without a newline, moving up.
        #expect(apply(LineOperations.moveUp(r(9), in: t as NSString), t) == "one\nthree\ntwo")
        let down = LineOperations.moveDown(r(1), in: t as NSString)
        #expect(apply(down, t) == "two\none\nthree")
        #expect(down?.selection == r(5))
        // Down onto the last line, and off the end: nothing.
        #expect(apply(LineOperations.moveDown(r(5), in: t as NSString), t) == "one\nthree\ntwo")
        #expect(LineOperations.moveDown(r(9), in: t as NSString) == nil)
        // Two lines move together and stay selected.
        let block = LineOperations.moveDown(r(0, 5), in: "a\nbb\nc\n" as NSString)
        #expect(apply(block, "a\nbb\nc\n") == "c\na\nbb\n")
        #expect(block?.selection == r(2, 5))
        // Moving down then up is the original.
        let once = apply(LineOperations.moveDown(r(2), in: "x\ny\nz\n" as NSString), "x\ny\nz\n")
        #expect(once == "x\nz\ny\n")
        #expect(apply(LineOperations.moveUp(r(4), in: once as NSString), once) == "x\ny\nz\n")
    }

    @Test func deleteLines() {
        let t = "one\ntwo\nthree"
        let d = LineOperations.deleteLines(r(5), in: t as NSString)
        #expect(apply(d, t) == "one\nthree")
        #expect(d.selection == r(4))
        // The last line takes the newline before it.
        let last = LineOperations.deleteLines(r(10), in: t as NSString)
        #expect(apply(last, t) == "one\ntwo")
        #expect(last.selection == r(4))
        #expect(apply(LineOperations.deleteLines(r(0, 13), in: t as NSString), t) == "")
        #expect(LineOperations.deletionRange(r(2), in: t as NSString) == r(0, 4))
    }

    @Test func toggleLineComments() {
        let swift = Language.swift.commentSyntax
        let t = "func f() {\n    let a = 1\n\n    return a\n}\n"
        // Lines 2–4 (one blank): the comment goes at the smallest indent, blank lines stay.
        let sel = r(12, 25)
        let on = LineOperations.toggleComment(sel, in: t as NSString, syntax: swift)
        let commented = apply(on, t)
        #expect(commented == "func f() {\n    // let a = 1\n\n    // return a\n}\n")
        // And back.
        let off = LineOperations.toggleComment(on!.selection, in: commented as NSString, syntax: swift)
        #expect(apply(off, commented) == t)
        // A caret: its line only, and the caret moves with the text.
        let caret = LineOperations.toggleComment(r(20), in: t as NSString, syntax: swift)
        #expect(apply(caret, t) == "func f() {\n    // let a = 1\n\n    return a\n}\n")
        #expect(caret?.selection == r(23))
        // Mixed lines: comment them all. "#" for Python, "//" not touched.
        let py = "x = 1\n# y = 2\n"
        #expect(apply(LineOperations.toggleComment(r(0, 13), in: py as NSString, syntax: Language.python.commentSyntax), py)
                == "# x = 1\n# # y = 2\n")
        // A comment without a space after the marker comes off too.
        #expect(apply(LineOperations.toggleComment(r(0), in: "#x\n" as NSString, syntax: Language.shell.commentSyntax), "#x\n") == "x\n")
        // No comments in JSON or plain text.
        #expect(LineOperations.toggleComment(r(0), in: "{}" as NSString, syntax: Language.json.commentSyntax) == nil)
        #expect(Language.plain.commentSyntax == nil)
    }

    @Test func toggleBlockComments() {
        let css = "  a { color: red; }\n"
        let on = LineOperations.toggleComment(r(4), in: css as NSString, syntax: Language.css.commentSyntax)
        let c = apply(on, css)
        #expect(c == "  /* a { color: red; } */\n")
        #expect(apply(LineOperations.toggleComment(r(4), in: c as NSString, syntax: Language.css.commentSyntax), c) == css)
        let html = "<p>hi</p>\n<p>there</p>"
        let h = apply(LineOperations.toggleComment(r(0, 22), in: html as NSString, syntax: Language.html.commentSyntax), html)
        #expect(h == "<!-- <p>hi</p>\n<p>there</p> -->")
        #expect(apply(LineOperations.toggleComment(r(0, (h as NSString).length), in: h as NSString, syntax: Language.html.commentSyntax), h) == html)
    }
}
