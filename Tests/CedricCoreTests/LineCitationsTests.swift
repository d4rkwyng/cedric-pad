import Foundation
import Testing
@testable import CedricCore

@Suite struct LineCitationsTests {
    @Test func citationsBecomeLinksToTheirFirstLine() {
        let text = "See Line 123. Then lines 40-80 and Lines 12\u{2013}40, plus LINE 7."
        #expect(LineCitations.lines(in: text) == [123, 40, 12, 7])
        let linked = LineCitations.linked(text)
        #expect(linked.contains("[Line 123](owlink-line://123)"))
        #expect(linked.contains("[lines 40-80](owlink-line://40)"))
        #expect(linked.contains("[Lines 12\u{2013}40](owlink-line://12)"))
        #expect(linked.contains("[LINE 7](owlink-line://7)"))
        #expect(LineCitations.line(from: URL(string: "owlink-line://123")!) == 123)
        #expect(LineCitations.line(from: URL(string: "https://example/123")!) == nil)
    }

    @Test func codeAndExistingLinksAreNotCitations() {
        let text = """
        Still Line 2.
        ```
        Line 9 is sample code
        ```
        `line 8` stays code, and [the note](https://example/Line%204) is a link.
        Not a baseline 4 or line 0.
        """
        #expect(LineCitations.lines(in: text) == [2])
        let linked = LineCitations.linked(text)
        #expect(linked.contains("[Line 2](owlink-line://2)"))
        #expect(!linked.contains("owlink-line://9"))
        #expect(!linked.contains("owlink-line://8"))
        #expect(!linked.contains("owlink-line://4"))
        #expect(!linked.contains("owlink-line://0"))
        #expect(linked.contains("https://example/Line%204"))
    }

    @Test func anEmDashRangeUsesTheFirstLine() {
        #expect(LineCitations.lines(in: "Lines 3\u{2014}9") == [3])
        #expect(LineCitations.linked("Lines 3\u{2014}9") == "[Lines 3\u{2014}9](owlink-line://3)")
    }
}
