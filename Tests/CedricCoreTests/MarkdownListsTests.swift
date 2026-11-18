import Foundation
import Testing
@testable import CedricCore

/// "‸" marks the caret (and a second one the selection's end).
func caretText(_ s: String) -> (NSString, NSRange) {
    let ns = s as NSString
    let a = ns.range(of: "‸").location
    let stripped = s.replacingOccurrences(of: "‸", with: "") as NSString
    let rest = ns.substring(from: a + 1) as NSString
    let b = rest.range(of: "‸").location
    return (stripped, NSRange(location: a, length: b == NSNotFound ? 0 : b))
}

/// The edit applied, with "‸" at the new caret (and selection end).
func shown(_ text: NSString, _ e: TextEdit?) -> String? {
    guard let e else { return nil }
    let out = e.applied(to: text as String) as NSString
    let withEnd = e.selection.length > 0 ? out.replacingCharacters(in: NSRange(location: NSMaxRange(e.selection), length: 0), with: "‸") as NSString : out
    return withEnd.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "‸")
}

@Suite struct MarkdownListsTests {
    func ret(_ s: String, _ lang: Language = .markdown) -> String? {
        let (t, sel) = caretText(s)
        return shown(t, MarkdownLists.newline(in: t, selection: sel, language: lang))
    }

    func tab(_ s: String, right: Bool = true, tabs: Bool = false) -> String? {
        let (t, sel) = caretText(s)
        return shown(t, MarkdownLists.shiftItem(in: t, selection: sel, right: right, useTabs: tabs))
    }

    @Test func parsesItems() {
        let i = MarkdownLists.parse("  > - [x] done")
        #expect(i?.quote == "  > " && i?.indent == "") // up to 3 spaces before a quote
        let q = MarkdownLists.parse("> - [x] done")
        #expect(q?.quote == "> " && q?.bullet == "-" && q?.task == "[x]" && q?.content == "done")
        let o = MarkdownLists.parse("   12) twelve")
        #expect(o?.number == 12 && o?.delimiter == ")" && o?.indent == "   " && o?.contentWidth == 4)
        #expect(MarkdownLists.parse("-no space") == nil)
        #expect(MarkdownLists.parse("- - -") == nil)
        #expect(MarkdownLists.parse("* * *") == nil)
        #expect(MarkdownLists.parse("**bold**") == nil)
        #expect(MarkdownLists.parse("-") == nil)
        for s in ["- a", "  * [ ] b", "1. c", "> > + d"] { #expect(MarkdownLists.parse(s)?.line == s) }
    }

    @Test func returnContinuesBullets() {
        #expect(ret("- one‸") == "- one\n- ‸")
        #expect(ret("  * two‸") == "  * two\n  * ‸")
        #expect(ret("+ a‸ b") == "+ a\n+ ‸ b")
        #expect(ret("- [x] done‸") == "- [x] done\n- [ ] ‸")
        #expect(ret("- [ ] todo‸") == "- [ ] todo\n- [ ] ‸")
        #expect(ret("> - quoted‸") == "> - quoted\n> - ‸")
        // Before the marker: an ordinary Return.
        #expect(ret("‸- one") == nil)
        #expect(ret("plain‸") == nil)
    }

    @Test func returnOnAnEmptyItemLeaves() {
        #expect(ret("- a\n- ‸") == "- a\n‸")
        #expect(ret("- a\n- [ ] ‸") == "- a\n‸")
        // Nested: outdent first.
        #expect(ret("- a\n  - b\n  - ‸") == "- a\n  - b\n- ‸")
        #expect(ret("> - a\n> - ‸") == "> - a\n> ‸")
        // A block quote carries on, and an empty one ends.
        #expect(ret("> said‸") == "> said\n> ‸")
        #expect(ret("> said\n> ‸") == "> said\n‸")
    }

    @Test func orderedListsCountAndRenumber() {
        #expect(ret("1. a‸") == "1. a\n2. ‸")
        #expect(ret("9) a‸") == "9) a\n10) ‸")
        // Inserting in the middle renumbers what follows.
        #expect(ret("1. a‸\n2. b\n3. c") == "1. a\n2. ‸\n3. b\n4. c")
        // The rest of the line goes along.
        #expect(ret("1. ab‸cd\n2. e") == "1. ab\n2. ‸cd\n3. e")
        // "1. 1. 1." stays that way.
        #expect(ret("1. a‸\n1. b") == "1. a\n1. ‸\n1. b")
        // A paragraph ends the list: nothing after it changes.
        #expect(ret("1. a‸\n2. b\n\nText\n\n7. z") == "1. a\n2. ‸\n3. b\n\nText\n\n7. z")
    }

    @Test func tabIndentsTheItem() {
        #expect(tab("- a\n- b‸") == "- a\n  - b‸")
        #expect(tab("1. a\n2. b‸") == "1. a\n   1. b‸")
        // Children move too; the next items renumber.
        #expect(tab("1. a\n2. b‸\n   - c\n3. d") == "1. a\n   1. b‸\n      - c\n2. d")
        // The first item can't go under anything.
        #expect(tab("- a‸") == nil)
        #expect(tab("text‸") == nil)
        // Lists indented with tabs get a tab.
        #expect(tab("- a\n- b‸", tabs: true) == "- a\n\t- b‸")
    }

    @Test func shiftTabOutdentsTheItem() {
        #expect(tab("- a\n  - b‸", right: false) == "- a\n- b‸")
        #expect(tab("1. a\n   1. b‸\n2. c", right: false) == "1. a\n2. b‸\n3. c")
        #expect(tab("- a‸", right: false) == nil)
        #expect(tab("1. a\n1. b\n   1. c‸", right: false) == "1. a\n1. b\n1. c‸")
        #expect(tab("- a\n    - b\n      - c‸", right: false) == "- a\n    - b\n    - c‸")
    }

    @Test func yamlItems() {
        #expect(ret("items:\n  - one‸", .yaml) == "items:\n  - one\n  - ‸")
        #expect(ret("  - ‸", .yaml) == "  ‸")
        #expect(ret("- name: a‸", .yaml) == "- name: a\n  ‸")
        #expect(ret("- key:‸", .yaml) == nil)
        #expect(ret("key: 1‸", .yaml) == nil)
        // No other markers in YAML.
        #expect(ret("* one‸", .yaml) == nil)
    }

    @Test func toggleTasks() {
        func t(_ s: String) -> String? { let (x, sel) = caretText(s); return shown(x, MarkdownLists.toggleTasks(in: x, selection: sel)) }
        #expect(t("- [ ] a‸") == "- [x] a‸")
        #expect(t("- [x] a‸") == "- [ ] a‸")
        #expect(t("- a‸") == "- [ ] a‸")
        #expect(t("  plain‸") == "  - [ ] plain‸")
        #expect(t("‸- [ ] a\n\n1. [x] b‸") == "‸- [x] a\n\n1. [ ] b‸")
        #expect(t("\n‸") == nil)
    }

    @Test func fences() {
        let s = "a\n```swift\n- x\n```\n- y\n~~~\n```\n~~~\n" as NSString
        let idx = LineIndex(s)
        #expect(!MarkdownLists.isInFence(s, index: idx, line: 0))
        #expect(MarkdownLists.isInFence(s, index: idx, line: 1))
        #expect(MarkdownLists.isInFence(s, index: idx, line: 2))
        #expect(MarkdownLists.isInFence(s, index: idx, line: 3))
        #expect(!MarkdownLists.isInFence(s, index: idx, line: 4))
        #expect(MarkdownLists.isInFence(s, index: idx, line: 6)) // ``` inside ~~~
        #expect(!MarkdownLists.isInFence(s, index: idx, line: 8))
    }
}
