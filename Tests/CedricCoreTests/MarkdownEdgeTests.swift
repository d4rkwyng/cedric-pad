import Foundation
import Testing
@testable import CedricCore

/// Inputs that could make the Markdown editing maths trap: empty text,
/// the caret at the very end, huge list numbers, odd tab widths, stale
/// selections; then every command over random text at every caret.
@Suite struct MarkdownEdgeTests {
    let empty = "" as NSString

    @Test func emptyTextAndEnds() {
        let z = NSRange(location: 0, length: 0)
        #expect(MarkdownLists.newline(in: empty, selection: z, language: .markdown) == nil)
        #expect(MarkdownLists.shiftItem(in: empty, selection: z, right: true) == nil)
        #expect(MarkdownLists.toggleTasks(in: empty, selection: z) == nil)
        #expect(MarkdownTable.tab(in: empty, selection: z, forward: true) == nil)
        #expect(MarkdownTable.newline(in: empty, selection: z) == nil)
        #expect(MarkdownTable.format(in: empty, selection: z) == nil)
        #expect(MarkdownFormat.toggle(.bold, in: empty, selection: z).replacement == "****")
        #expect(MarkdownFormat.link(in: empty, selection: z, clipboard: nil).replacement == "[]()")
        // The caret after a final newline, on the empty last line.
        let t = "- a\n" as NSString
        #expect(MarkdownLists.newline(in: t, selection: NSRange(location: 4, length: 0), language: .markdown) == nil)
        #expect(MarkdownLists.shiftItem(in: t, selection: NSRange(location: 4, length: 0), right: true) == nil)
        #expect(MarkdownTable.tab(in: "| a |\n" as NSString, selection: NSRange(location: 6, length: 0), forward: true) == nil)
    }

    @Test func staleSelectionsDontTrap() {
        let t = "- a" as NSString
        for sel in [NSRange(location: NSNotFound, length: 0), NSRange(location: 99, length: 0), NSRange(location: 1, length: 99),
                    NSRange(location: -1, length: 0)] {
            #expect(MarkdownLists.newline(in: t, selection: sel, language: .markdown) == nil)
            #expect(MarkdownLists.shiftItem(in: t, selection: sel, right: false) == nil)
            #expect(MarkdownLists.toggleTasks(in: t, selection: sel) == nil)
            #expect(MarkdownTable.tab(in: t, selection: sel, forward: true) == nil)
            #expect(MarkdownPaste.linkPaste(in: t, selection: sel, pasted: "https://x.org") == nil)
            _ = MarkdownFormat.toggle(.italic, in: t, selection: sel)
            _ = MarkdownFormat.link(in: t, selection: sel, clipboard: "https://x.org")
        }
        #expect(!MarkdownPaste.inCodeSpan(t, at: NSNotFound))
    }

    @Test func hugeNumbersAndWidths() {
        func ret(_ s: String) -> String? { let (x, sel) = caretText(s); return shown(x, MarkdownLists.newline(in: x, selection: sel, language: .markdown)) }
        // Over 9 digits isn't a list item (CommonMark): no Int overflow.
        #expect(MarkdownLists.parse("99999999999999999999. big") == nil)
        #expect(ret("99999999999999999999. big‸") == nil)
        #expect(ret("999999999. big‸") == "999999999. big\n1000000000. ‸")
        #expect(ret("1. a‸\n999999999. b") == "1. a\n2. ‸\n3. b")
        // Tab widths out of range are clamped, never divided by.
        let (t, sel) = caretText("- a\n\t- b‸")
        #expect(MarkdownLists.shiftItem(in: t, selection: sel, right: false, useTabs: true, tabWidth: 0) != nil)
        #expect(MarkdownLists.shiftItem(in: t, selection: sel, right: true, useTabs: true, tabWidth: -5) == nil)
        #expect(MarkdownLists.newline(in: t, selection: sel, language: .markdown, tabWidth: 0) != nil)
        // A very long line is never a list item.
        let long = "- " + String(repeating: "x", count: 20_000)
        #expect(MarkdownLists.newline(in: long as NSString, selection: NSRange(location: (long as NSString).length, length: 0), language: .markdown) == nil)
    }

    /// Every command at every caret (and a few selections) of random
    /// Markdown-ish text: none traps, and every edit's ranges fit the text.
    @Test func fuzz() {
        var rng = SystemRandomNumberGenerator.Seeded(seed: 42)
        let pieces = ["- ", "* ", "1. ", "99) ", "> ", "  ", "\t", "[ ] ", "[x] ", "|", " | ", "---", ":-:", "```", "~~~", "**", "*", "~~", "`",
                      "[a](b)", "word", "日本", "🦉", "\n", "\n", "\n", "e\u{301}", "\\|", "_", "https://x.org", ""]
        for _ in 0..<150 {
            var s = ""
            for _ in 0..<Int.random(in: 0...14, using: &rng) { s += pieces.randomElement(using: &rng)! }
            let t = s as NSString
            for loc in 0...t.length {
                for len in [0, 1, 3] where loc + len <= t.length {
                    let sel = NSRange(location: loc, length: len)
                    var edits: [TextEdit?] = [
                        MarkdownLists.newline(in: t, selection: sel, language: .markdown),
                        MarkdownLists.newline(in: t, selection: sel, language: .yaml),
                        MarkdownLists.shiftItem(in: t, selection: sel, right: true),
                        MarkdownLists.shiftItem(in: t, selection: sel, right: false, useTabs: true),
                        MarkdownLists.toggleTasks(in: t, selection: sel),
                        MarkdownTable.tab(in: t, selection: sel, forward: true),
                        MarkdownTable.tab(in: t, selection: sel, forward: false),
                        MarkdownTable.newline(in: t, selection: sel),
                        MarkdownTable.format(in: t, selection: sel),
                        MarkdownFormat.link(in: t, selection: sel, clipboard: "https://x.org"),
                        MarkdownPaste.linkPaste(in: t, selection: sel, pasted: "https://x.org"),
                    ]
                    for st in MarkdownFormat.Style.allCases { edits.append(MarkdownFormat.toggle(st, in: t, selection: sel)) }
                    for case let e? in edits {
                        let ok = e.range.location >= 0 && NSMaxRange(e.range) <= t.length
                        #expect(ok, "edit range \(e.range) out of \(t.length) in \(s.debugDescription)")
                        guard ok else { continue }
                        let n = (e.applied(to: s) as NSString).length
                        #expect(e.selection.location >= 0 && NSMaxRange(e.selection) <= n, "selection \(e.selection) out of \(n) in \(s.debugDescription)")
                    }
                }
            }
        }
    }

    @Test func fenceIndexCachesAndInvalidates() {
        var s = "# t\n```\n- a\n```\n- b\n" as NSString
        var idx = LineIndex(s)
        let f = FenceIndex()
        #expect(f.isInFence(s, index: idx, line: 2))
        #expect(!f.isInFence(s, index: idx, line: 4))
        #expect(f.validCount == 5)
        // Delete the closing fence: line 4 is now in the fence, once invalidated.
        s = "# t\n```\n- a\n\n- b\n" as NSString
        idx = LineIndex(s)
        f.invalidate(fromLine: 3)
        #expect(f.isInFence(s, index: idx, line: 4))
        #expect(!f.isInFence(s, index: idx, line: 99))
        #expect(!f.isInFence(s, index: idx, line: -1))
        // A longer opening fence needs as long a closer.
        let u = "````\n```\nx\n````\ny" as NSString
        let g = FenceIndex()
        #expect(g.isInFence(u, index: LineIndex(u), line: 2))
        #expect(!g.isInFence(u, index: LineIndex(u), line: 4))
    }
}

extension SystemRandomNumberGenerator {
    /// A seeded generator, so the fuzz test is the same every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
