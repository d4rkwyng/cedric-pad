import Foundation
import Testing
@testable import CedricCore

@Suite struct TextStatsTests {
    func c(_ s: String, _ r: NSRange? = nil) -> TextCounts? {
        let ns = s as NSString
        return TextStats.count(ns, range: r ?? NSRange(location: 0, length: ns.length))
    }

    @Test func wordsLinesCharacters() {
        #expect(c("hello world\nsecond line") == TextCounts(words: 4, lines: 2, characters: 23))
        // A trailing newline doesn't start a counted line; an empty text is one line.
        #expect(c("a\nb\n") == TextCounts(words: 2, lines: 2, characters: 4))
        #expect(c("") == TextCounts(words: 0, lines: 1, characters: 0))
        // Punctuation splits words; "_" doesn't; non-ASCII letters are letters.
        #expect(c("don't snake_case école, 42")?.words == 5)
        // A surrogate pair is one character.
        #expect(c("a😀b")?.characters == 3)
    }

    @Test func selectionRangesAndTheLimit() {
        let t = "one two\nthree four\nfive"
        #expect(c(t, NSRange(location: 4, length: 9)) == TextCounts(words: 2, lines: 2, characters: 9))
        // Ranges past the end are clamped.
        #expect(c(t, NSRange(location: 19, length: 100)) == TextCounts(words: 1, lines: 1, characters: 4))
        let big = String(repeating: "word ", count: 10) as NSString
        #expect(TextStats.count(big, range: NSRange(location: 0, length: big.length), limit: 20) == nil)
        #expect(TextStats.count(big, range: NSRange(location: 0, length: 20), limit: 20)?.words == 4)
    }
}
