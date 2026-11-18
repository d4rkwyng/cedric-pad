import Foundation
import Testing
@testable import CedricCore

/// The owl's tools: dispatch, argument checks, output caps and the frozen snapshot.
@Suite struct OwlToolsTests {
    static let doc: String = {
        var s = "# Title\n\nIntro line.\n\n## Usage\n\n"
        for i in 1...300 { s += "line \(i) value=\(i * 3)\n" }
        s += "## End\nlast"
        return s
    }()
    func snap(_ sel: NSRange = NSRange(location: 0, length: 0)) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: Self.doc, generation: 3, selection: sel, fileName: "notes.md", language: "markdown")
    }
    func call(_ name: String, _ args: [String: OwlJSON] = [:]) -> OwlToolCall { OwlToolCall(name: name, arguments: .object(args)) }

    @Test func unknownAndDisallowedToolsAreRefused() {
        let r = OwlTools.run(call("rm_rf"), on: snap())
        #expect(!r.ok && r.text.hasPrefix("error: unknown tool"))
        let d = OwlTools.run(call("get_outline"), on: snap(), allowed: [.getLines])
        #expect(!d.ok && d.text.contains("not available"))
    }

    @Test func getLinesIsNumberedClampedAndCapped() {
        let r = OwlTools.run(call("get_lines", ["start": .number(10), "end": .number(11)]), on: snap())
        #expect(r.ok && r.text == "10| line 4 value=12\n11| line 5 value=15")
        // Quoted numbers from small models are fine.
        #expect(OwlTools.run(call("get_lines", ["start": .string("10"), "end": .string("10")]), on: snap()).text == "10| line 4 value=12")
        let big = OwlTools.run(call("get_lines", ["start": .number(1), "end": .number(5000)]), on: snap())
        #expect(big.text.utf8.count <= OwlTools.maxOutputBytes)
        #expect(big.text.hasSuffix("[… cut]"))
        #expect(!OwlTools.run(call("get_lines", ["start": .number(0)]), on: snap()).ok)
        #expect(!OwlTools.run(call("get_lines", ["start": .number(9999)]), on: snap()).ok)
        #expect(!OwlTools.run(call("get_lines"), on: snap()).ok)
    }

    @Test func searchFindsLinesPlainOrRegexWithLimits() {
        let r = OwlTools.run(call("search_document", ["query": .string("value=300")]), on: snap())
        #expect(r.ok && r.text == "106| line 100 value=300")
        let many = OwlTools.run(call("search_document", ["query": .string("line")]), on: snap())
        #expect(many.text.components(separatedBy: "\n").filter { $0.contains("| ") }.count == OwlTools.maxMatches)
        #expect(many.text.contains("more lines match"))
        let re = OwlTools.run(call("search_document", ["query": .string(#"value=9\d\d\b"#), "regex": .bool(true)]), on: snap())
        #expect(re.ok && re.text.hasPrefix("306| line 300 value=900"))
        // A plain query with regex characters is literal.
        #expect(OwlTools.run(call("search_document", ["query": .string("(")]), on: snap()).text == "no matches")
        #expect(!OwlTools.run(call("search_document", ["query": .string("("), "regex": .bool(true)]), on: snap()).ok)
        #expect(!OwlTools.run(call("search_document", ["query": .string(String(repeating: "a", count: 300))]), on: snap()).ok)
    }

    @Test func outlineStatsAndSelection() {
        #expect(OwlTools.run(call("get_outline"), on: snap()).text == "1| # Title\n5| ## Usage\n307| ## End")
        let stats = OwlTools.run(call("document_stats"), on: snap()).text
        #expect(stats.contains("lines: 308") && stats.contains("file: notes.md") && stats.contains("language: Markdown"))
        #expect(OwlTools.run(call("get_selection"), on: snap()).text == "(nothing selected)")
        let ns = Self.doc as NSString
        let sel = OwlTools.run(call("get_selection"), on: snap(ns.range(of: "Intro line.")))
        #expect(sel.text == "Selected text (lines 3-3):\n3| Intro line.")
    }

    @Test func proposeEditReturnsAProposalAgainstTheSnapshot() {
        let r = OwlTools.run(call("propose_edit", ["start": .number(3), "end": .number(3), "new_text": .string("Intro, rewritten."), "reason": .string("clearer")]), on: snap())
        let p = try! #require(r.proposal)
        #expect(p.original == "Intro line." && p.replacement == "Intro, rewritten." && p.generation == 3 && p.reason == "clearer")
        #expect(p.isCurrent(text: Self.doc as NSString, generation: 3))
        #expect(!OwlTools.run(call("propose_edit", ["start": .number(3), "end": .number(3), "new_text": .string("Intro line.")]), on: snap()).ok)
        #expect(!OwlTools.run(call("propose_edit", ["start": .number(5), "end": .number(2), "new_text": .string("x")]), on: snap()).ok)
        #expect(!OwlTools.run(call("propose_edit", ["start": .number(1)]), on: snap()).ok)
    }

    @Test func toolsReadTheSnapshotNotTheLiveText() {
        var live = Self.doc
        let s = snap()
        live = "changed"
        _ = live
        #expect(OwlTools.run(call("get_lines", ["start": .number(1), "end": .number(1)]), on: s).text == "1| # Title")
    }
}
