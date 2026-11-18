import Foundation
import Testing
@testable import CedricCore

@Suite struct MarkdownOutlineTests {
    typealias H = MarkdownOutline.Heading

    @Test func atxAndSetextHeadingsSkippingCode() {
        let text = """
        ---
        title: # not a heading
        ---
        # One #
        text
        ```sh
        # a shell comment
        ```
        Two **bold**
        ===
        ~~~~
        ## in tildes
        ~~~~
            # indented code
        <!--
        # commented out
        -->
        ### Three [link](x) `code` ###
        Para
        ---
        #hashtag
        - item
        ---
        """
        #expect(MarkdownOutline.headings(in: text) == [
            H(level: 1, title: "One", line: 3),
            H(level: 1, title: "Two bold", line: 8),
            H(level: 3, title: "Three link code", line: 17),
            H(level: 2, title: "Para", line: 18),
        ])
    }

    @Test func limitAndCurrent() {
        let text = (0..<50).map { "## H\($0)\ntext" }.joined(separator: "\n")
        let all = MarkdownOutline.headings(in: text)
        #expect(all.count == 50 && all[3].line == 6)
        #expect(MarkdownOutline.headings(in: text, limit: 10).count == 10)
        #expect(MarkdownOutline.current(all, line: 0) == 0)
        #expect(MarkdownOutline.current(all, line: 7) == 3)
        #expect(MarkdownOutline.current(all, line: 1000) == 49)
        #expect(MarkdownOutline.current([H(level: 1, title: "a", line: 5)], line: 2) == nil)
    }
}
