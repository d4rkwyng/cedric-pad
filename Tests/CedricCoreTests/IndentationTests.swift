import Foundation
import Testing
@testable import CedricCore

@Suite struct IndentationTests {
    func apply(_ e: TextEdit?, _ text: String) -> String { e!.applied(to: text) }

    @Test func detectsSpacesAndWidth() {
        let two = "a:\n  b:\n    c: 1\n  d: 2\n"
        #expect(Indentation.detect(two as NSString) == Indentation(usesTabs: false, width: 2))
        let four = "func f() {\n    if x {\n        y()\n    }\n}\n"
        #expect(Indentation.detect(four as NSString) == Indentation(usesTabs: false, width: 4))
        let tabs = "func f() {\n\tif x {\n\t\ty()\n\t}\n}\n"
        #expect(Indentation.detect(tabs as NSString)?.usesTabs == true)
        // Block-comment continuation lines (" * ") aren't a 1-space indent.
        let doc = "/**\n * doc\n * more\n */\nfunc f() {\n    a()\n    b()\n}\n"
        #expect(Indentation.detect(doc as NSString) == Indentation(usesTabs: false, width: 4))
    }

    @Test func detectNeedsEvidenceAndIsBounded() {
        #expect(Indentation.detect("" as NSString) == nil)
        #expect(Indentation.detect("plain\ntext\nonly\n" as NSString) == nil)
        // Indented lines past the limit aren't read.
        let big = String(repeating: "x\n", count: 5000) + "\ty\n\tz\n"
        #expect(Indentation.detect(big as NSString, maxLines: 2000) == nil)
        #expect(Indentation.detect(big as NSString, maxLines: 10_000)?.usesTabs == true)
    }

    @Test func unitAndClampedWidth() {
        #expect(Indentation(usesTabs: false, width: 2).unit == "  ")
        #expect(Indentation(usesTabs: true, width: 8).unit == "\t")
        #expect(Indentation(usesTabs: false, width: 99).width == 16)
    }

    @Test func indentEveryTouchedLineSkippingBlanks() {
        let t = "a\n\nb\nc\n"
        // Lines 1–3 selected (from "a" into "b").
        let e = LineOperations.indent(NSRange(location: 0, length: 4), in: t as NSString, unit: "    ")
        #expect(apply(e, t) == "    a\n\n    b\nc\n")
        // Whole lines selected from a line start stay selected whole.
        #expect(e!.selection == NSRange(location: 0, length: 12))
        // With tabs.
        let tabbed = LineOperations.indent(NSRange(location: 0, length: 5), in: t as NSString, unit: "\t")
        #expect(apply(tabbed, t) == "\ta\n\n\tb\nc\n")
        // Nothing but blank lines: nothing to do.
        #expect(LineOperations.indent(NSRange(location: 0, length: 2), in: "\n\n" as NSString, unit: "\t") == nil)
    }

    @Test func indentCaretMovesWithItsText() {
        let t = "abc\n"
        let e = LineOperations.indent(NSRange(location: 2, length: 0), in: t as NSString, unit: "  ")
        #expect(apply(e, t) == "  abc\n")
        #expect(e!.selection == NSRange(location: 4, length: 0))
    }

    @Test func outdentRemovesOneStep() {
        let t = "        a\n    b\nc\n\td\n  \te\n"
        let all = NSRange(location: 0, length: (t as NSString).length)
        let e = LineOperations.outdent(all, in: t as NSString, width: 4)
        #expect(apply(e, t) == "    a\nb\nc\nd\ne\n")
        #expect(e!.selection == NSRange(location: 0, length: ("    a\nb\nc\nd\ne\n" as NSString).length))
        // Nothing indented: nil (beep).
        #expect(LineOperations.outdent(NSRange(location: 0, length: 1), in: "x\ny\n" as NSString, width: 4) == nil)
        // Caret: moves left with the text, not before the line start.
        let c = LineOperations.outdent(NSRange(location: 6, length: 0), in: "    abc\n" as NSString, width: 4)
        #expect(c!.selection == NSRange(location: 2, length: 0))
        let c2 = LineOperations.outdent(NSRange(location: 1, length: 0), in: "    abc\n" as NSString, width: 4)
        #expect(c2!.selection == NSRange(location: 0, length: 0))
    }

    @Test func indentThenOutdentRoundTrips() {
        let t = "if x {\n  y()\n}\nlast"
        let all = NSRange(location: 0, length: (t as NSString).length)
        let i = LineOperations.indent(all, in: t as NSString, unit: "  ")!
        let indented = i.applied(to: t)
        #expect(indented == "  if x {\n    y()\n  }\n  last")
        let o = LineOperations.outdent(i.selection, in: indented as NSString, width: 2)!
        #expect(o.applied(to: indented) == t)
    }

    @Test func convertIndentationKeepsColumns() {
        let spaces = "a\n    b\n        c\n      d\n"
        let tabs = LineOperations.convertIndentation(spaces, from: Indentation(usesTabs: false, width: 4),
                                                     to: Indentation(usesTabs: true, width: 4))
        #expect(tabs == "a\n\tb\n\t\tc\n\t  d\n")
        let back = LineOperations.convertIndentation(tabs, from: Indentation(usesTabs: true, width: 4),
                                                     to: Indentation(usesTabs: false, width: 4))
        #expect(back == spaces)
    }

    @Test func autoIndentUsesTheDocumentsUnit() {
        let t = "if x {" as NSString
        let r = AutoEdit.newline(in: t, lineStart: 0, caret: t.length, after: t.length, language: .javascript, unit: "\t")
        #expect(r.text == "\n\t")
        let r2 = AutoEdit.newline(in: t, lineStart: 0, caret: t.length, after: t.length, language: .javascript, unit: "  ")
        #expect(r2.text == "\n  ")
        // A tab-indented line keeps tabs whatever the setting.
        let u = "\tif x {" as NSString
        #expect(AutoEdit.newline(in: u, lineStart: 0, caret: u.length, after: u.length, language: .javascript, unit: "  ").text == "\n\t\t")
    }

    @Test func sessionKeepsIndentation() throws {
        let tab = SessionTab(path: "/x", indentation: Indentation(usesTabs: true, width: 8))
        let data = try JSONEncoder().encode(Session(windows: [SessionWindow(tabs: [tab])]))
        let back = try JSONDecoder().decode(Session.self, from: data)
        #expect(back.allTabs.first?.indentation == Indentation(usesTabs: true, width: 8))
        // Older sessions (no key) still decode.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}"#
        #expect(try JSONDecoder().decode(SessionTab.self, from: Data(old.utf8)).indentation == nil)
    }
}
