import Foundation
import Testing
@testable import CedricCore

@Suite struct MarkdownTableTests {
    @Test func displayWidth() {
        #expect(MarkdownTable.displayWidth("abc") == 3)
        #expect(MarkdownTable.displayWidth("日本語") == 6)
        #expect(MarkdownTable.displayWidth("한글") == 4)
        #expect(MarkdownTable.displayWidth("ｱｲ") == 2) // halfwidth katakana
        #expect(MarkdownTable.displayWidth("🦉") == 2)
        #expect(MarkdownTable.displayWidth("👍🏽") == 2)
        #expect(MarkdownTable.displayWidth("e\u{301}") == 1) // é, combining
        #expect(MarkdownTable.displayWidth("❤️") == 2) // with VS16
    }

    @Test func cellsSkipEscapesAndCode() {
        #expect(MarkdownTable.cells("| a | b |").map(\.text) == ["a", "b"])
        #expect(MarkdownTable.cells("a | b").map(\.text) == ["a", "b"])
        #expect(MarkdownTable.cells("| a \\| b | `x|y` |").map(\.text) == ["a \\| b", "`x|y`"])
        #expect(MarkdownTable.cells("| a | |").map(\.text) == ["a", ""])
        #expect(MarkdownTable.isDelimiter("|:--|--:|:-:|---|"))
        #expect(!MarkdownTable.isDelimiter("| a | - |"))
    }

    @Test func formatsWithAlignmentAndWideText() {
        let (t, sel) = caretText("| Name | n |\n|:-|-:|\n| 日本‸ | 1 |\n| owl 🦉 | 100 |")
        #expect(shown(t, MarkdownTable.format(in: t, selection: sel)) ==
            "| Name   |   n |\n| :----- | --: |\n| 日本‸   |   1 |\n| owl 🦉 | 100 |")
        // Center, and a short row padded.
        let (u, s2) = caretText("|a|b|\n|:-:|---|\n|‸x|")
        #expect(shown(u, MarkdownTable.format(in: u, selection: s2)) == "|  a  | b   |\n| :-: | --- |\n|  ‸x  |     |")
        // Not a table: no delimiter row.
        let (v, s3) = caretText("a | b‸\nc | d")
        #expect(MarkdownTable.format(in: v, selection: s3) == nil)
    }

    @Test func tabMovesBetweenCells() {
        func tab(_ s: String, _ forward: Bool = true) -> String? { let (t, sel) = caretText(s); return shown(t, MarkdownTable.tab(in: t, selection: sel, forward: forward)) }
        #expect(tab("| a‸ | bb |\n|---|---|\n| c | d |") == "| a   | ‸bb‸  |\n| --- | --- |\n| c   | d   |")
        // From the last cell of the header, over the delimiter row.
        #expect(tab("| a | b‸ |\n|---|---|\n| c | d |") == "| a   | b   |\n| --- | --- |\n| ‸c‸   | d   |")
        // Past the last cell: a new row.
        #expect(tab("| a | b |\n|---|---|\n| c | d‸ |") == "| a   | b   |\n| --- | --- |\n| c   | d   |\n| ‸    |     |")
        #expect(tab("| a | b |\n|---|---|\n| c | ‸d |", false) == "| a   | b   |\n| --- | --- |\n| ‸c‸   | d   |")
        #expect(tab("| a | b |\n|---|---|\n| ‸c | d |", false) == "| a   | b   |\n| --- | --- |\n| c   | d   |".replacingOccurrences(of: "| b   |\n", with: "| ‸b‸   |\n"))
        // A lone header line: the delimiter row is built.
        #expect(tab("| Name | Age |‸") == "| Name | Age |\n| ---- | --- |\n| ‸     |     |")
        #expect(tab("text | not a table‸") == nil)
        #expect(tab("plain‸") == nil)
    }

    @Test func returnAddsARow() {
        func ret(_ s: String) -> String? { let (t, sel) = caretText(s); return shown(t, MarkdownTable.newline(in: t, selection: sel)) }
        #expect(ret("| a | b |\n|---|---|\n| c | d |‸") == "| a   | b   |\n| --- | --- |\n| c   | d   |\n| ‸    |     |")
        // An empty last row: Return ends the table.
        #expect(ret("| a | b |\n|---|---|\n| c | d |\n|  |  |‸") == "| a   | b   |\n| --- | --- |\n| c   | d   |\n‸")
        // In a middle row: the same cell one row down; from the header, over the delimiter row.
        #expect(ret("| a | b |\n|---|---|\n| c‸ | d |\n| e | f |") == "| a   | b   |\n| --- | --- |\n| c   | d   |\n| ‸e   | f   |")
        #expect(ret("| a | b‸ |\n|---|---|") == "| a   | b   |\n| --- | --- |\n|     | ‸    |")
        // Before the row, or on the delimiter row: a plain Return.
        #expect(ret("‸| a | b |\n|---|---|") == nil)
        #expect(ret("| a | b |\n|---|---|‸") == nil)
    }
}
