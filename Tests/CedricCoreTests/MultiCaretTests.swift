import Foundation
import Testing
@testable import CedricCore

@Suite struct MultiCaretTests {
    typealias Caret = MultiCaret.Caret

    func carets(_ offsets: Int...) -> [Caret] { offsets.map { Caret(at: $0) } }

    /// Applies per-caret edits like the view: resolved, last first.
    func run(_ text: String, _ edits: [MultiCaret.Edit], primary: Int = 0) -> (String, [NSRange]) {
        let r = MultiCaret.carets(after: edits, primary: primary)
        return (MultiCaret.apply(r.edits, to: text), r.carets.map(\.range))
    }

    func r(_ l: Int, _ n: Int = 0) -> NSRange { NSRange(location: l, length: n) }

    // MARK: Normalising

    @Test func normalizeSortsAndMerges() {
        let n = MultiCaret.normalize([Caret(at: 9), Caret(at: 2), Caret(at: 5)], primary: 0)
        #expect(n.carets.map(\.head) == [2, 5, 9])
        #expect(n.primary == 2)
        // The same place twice: one caret.
        #expect(MultiCaret.normalize(carets(3, 3)).carets.count == 1)
    }

    @Test func overlappingSelectionsMerge() {
        let n = MultiCaret.normalize([Caret(r(2, 4)), Caret(r(4, 4)), Caret(r(20, 1))], primary: 1)
        #expect(n.carets.map(\.range) == [r(2, 6), r(20, 1)])
        #expect(n.primary == 0)
        // A caret inside or touching a selection merges into it; two touching selections stay apart.
        #expect(MultiCaret.normalize([Caret(r(2, 4)), Caret(at: 6)]).carets.map(\.range) == [r(2, 4)])
        #expect(MultiCaret.normalize([Caret(r(2, 4)), Caret(at: 3)]).carets.map(\.range) == [r(2, 4)])
        #expect(MultiCaret.normalize([Caret(r(2, 2)), Caret(r(4, 2))]).carets.map(\.range) == [r(2, 2), r(4, 2)])
    }

    @Test func mergeKeepsDirection() {
        let n = MultiCaret.normalize([Caret(anchor: 6, head: 2), Caret(r(5, 3))])
        #expect(n.carets == [Caret(anchor: 8, head: 2)])
    }

    // MARK: Edits

    @Test func insertAtThreeCaretsShifts() {
        let (t, c) = run("ab\ncd\nef", MultiCaret.insert("XY", at: carets(1, 4, 7)))
        #expect(t == "aXYb\ncXYd\neXYf")
        #expect(c == [r(3), r(8), r(13)])
    }

    @Test func insertReplacesSelectionsInOrder() {
        let (t, c) = run("one two one", MultiCaret.insert("1", at: [Caret(r(8, 3)), Caret(r(0, 3))]))
        #expect(t == "1 two 1")
        #expect(c == [r(1), r(7)])
    }

    @Test func deleteAtLineStartJoinsLines() {
        let text = "ab\ncd\nef" as NSString
        let lines = LineIndex(text)
        let e = MultiCaret.delete(.backward, at: carets(3, 6), in: text, lines: lines)
        let (t, c) = run(text as String, e)
        #expect(t == "abcdef")
        #expect(c == [r(2), r(4)])
    }

    @Test func caretsThatCollideAfterDeleteMerge() {
        // Carets at 1 and 2: each deletes one character; they end up at 0, together.
        let text = "abc" as NSString
        let e = MultiCaret.delete(.backward, at: carets(1, 2), in: text, lines: LineIndex(text))
        let (t, c) = run(text as String, e)
        #expect(t == "c")
        #expect(c == [r(0)])
    }

    @Test func overlappingDeletesClipped() {
        // Pair delete "(|)" at 1 takes 0..<2; a caret at 2 also deletes 1..<2: once only.
        let text = "()x" as NSString
        let e = MultiCaret.delete(.backward, at: carets(1, 2), in: text, lines: LineIndex(text), language: .swift, pairing: true)
        #expect(e[0].range == r(0, 2))
        let (t, c) = run(text as String, e)
        #expect(t == "x")
        #expect(c == [r(0)])
    }

    @Test func deleteKindsAndDocumentStart() {
        let text = "foo bar\nbaz" as NSString
        let lines = LineIndex(text)
        #expect(run(text as String, MultiCaret.delete(.backward, at: carets(0, 11), in: text, lines: lines)).0 == "foo bar\nba")
        #expect(run(text as String, MultiCaret.delete(.forward, at: carets(0, 8), in: text, lines: lines)).0 == "oo bar\naz")
        #expect(run(text as String, MultiCaret.delete(.wordBackward, at: carets(7, 11), in: text, lines: lines)).0 == "foo \n")
        #expect(run(text as String, MultiCaret.delete(.toLineStart, at: carets(5, 10), in: text, lines: lines)).0 == "ar\nz")
        #expect(run(text as String, MultiCaret.delete(.toLineEnd, at: carets(1, 9), in: text, lines: lines)).0 == "f\nb")
    }

    @Test func surrogatePairsAndComposedCharactersNeverSplit() {
        // "😀" is 2 units; "é" as e + combining acute is 2 units, one character.
        let text = "a😀\ne\u{301}" as NSString
        let lines = LineIndex(text)
        let e = MultiCaret.delete(.backward, at: carets(3, 6), in: text, lines: lines)
        #expect(e.map(\.range) == [r(1, 2), r(4, 2)])
        #expect(run(text as String, e).0 == "a\n")
        let moved = MultiCaret.move(carets(1, 4), .right, extend: false, in: text, lines: lines)
        #expect(moved.map(\.head) == [3, 6])
        #expect(MultiCaret.move(carets(3, 6), .left, extend: false, in: text, lines: lines).map(\.head) == [1, 4])
    }

    @Test func pasteSplitsLinesAcrossCarets() {
        let three = carets(0, 2, 4)
        #expect(MultiCaret.paste("x\ny\nz", at: three).map(\.replacement) == ["x", "y", "z"])
        // One trailing newline is ignored.
        #expect(MultiCaret.paste("x\ny\nz\n", at: three).map(\.replacement) == ["x", "y", "z"])
        // Not N lines: the whole text at each.
        #expect(MultiCaret.paste("x\ny", at: three).map(\.replacement) == ["x\ny", "x\ny", "x\ny"])
        #expect(MultiCaret.paste("one", at: carets(5)).map(\.replacement) == ["one"])
    }

    @Test func copyJoinsSelectionsInOrder() {
        let text = "alpha beta gamma" as NSString
        #expect(MultiCaret.copyText([Caret(r(0, 5)), Caret(at: 7), Caret(r(11, 5))], in: text) == "alpha\ngamma")
    }

    // MARK: Moving

    @Test func goalColumnAcrossShortLinesAndTabs() {
        let text = "abcdef\nab\n\tx\nabcdefgh" as NSString
        let lines = LineIndex(text)
        var c = [Caret(at: 5)]
        c = MultiCaret.move(c, .down, extend: false, in: text, lines: lines, tabWidth: 4)
        #expect(c[0].head == 9) // end of "ab"
        #expect(c[0].goalColumn == 5)
        c = MultiCaret.move(c, .down, extend: false, in: text, lines: lines, tabWidth: 4)
        #expect(c[0].head == 12) // "\tx" is 5 columns wide: its end
        c = MultiCaret.move(c, .down, extend: false, in: text, lines: lines, tabWidth: 4)
        #expect(c[0].head == 18) // column 5 of "abcdefgh"
        #expect(MultiCaret.visualColumn(of: 12, in: text, lines: lines, tabWidth: 4) == 5)
        // A column inside a tab's span: the nearer side.
        #expect(MultiCaret.offset(forColumn: 1, line: 2, in: text, lines: lines, tabWidth: 4) == 10)
        #expect(MultiCaret.offset(forColumn: 3, line: 2, in: text, lines: lines, tabWidth: 4) == 11)
        // A horizontal move forgets the goal.
        #expect(MultiCaret.move(c, .left, extend: false, in: text, lines: lines)[0].goalColumn == nil)
    }

    @Test func movesAndExtends() {
        let text = "one two\nthree" as NSString
        let lines = LineIndex(text)
        let sel = [Caret(r(0, 3)), Caret(r(8, 5))]
        // ← / → on selections collapse to their start / end.
        #expect(MultiCaret.move(sel, .left, extend: false, in: text, lines: lines).map(\.head) == [0, 8])
        #expect(MultiCaret.move(sel, .right, extend: false, in: text, lines: lines).map(\.head) == [3, 13])
        // ⇧→ grows from the anchor.
        let grown = MultiCaret.move(carets(0, 8), .wordRight, extend: true, in: text, lines: lines)
        #expect(grown.map(\.range) == [r(0, 3), r(8, 5)])
        #expect(MultiCaret.move(carets(5, 10), .lineStart, extend: false, in: text, lines: lines).map(\.head) == [0, 8])
        #expect(MultiCaret.move(carets(1, 9), .lineEnd, extend: false, in: text, lines: lines).map(\.head) == [7, 13])
        #expect(MultiCaret.move(carets(2), .up, extend: false, in: text, lines: lines).map(\.head) == [0])
        #expect(MultiCaret.move(carets(10), .down, extend: false, in: text, lines: lines).map(\.head) == [13])
    }

    @Test func caretBesideAboveAndBelow() {
        let text = "abcd\nab\nabcd" as NSString
        let lines = LineIndex(text)
        let below = MultiCaret.caretBeside(carets(3), below: true, in: text, lines: lines)
        #expect(below?.head == 7 && below?.goalColumn == 3)
        // From the bottommost caret, keeping the goal column of the short line.
        let next = MultiCaret.caretBeside([Caret(at: 3), below!], below: true, in: text, lines: lines)
        #expect(next?.head == 11)
        #expect(MultiCaret.caretBeside(carets(3), below: false, in: text, lines: lines) == nil)
        #expect(MultiCaret.caretBeside(carets(11), below: false, in: text, lines: lines)?.head == 7)
    }

    // MARK: Occurrences

    @Test func nextOccurrenceWrapsAndSkipsExisting() {
        let text = "foo bar foo baz foo" as NSString
        #expect(MultiCaret.nextOccurrence(of: "foo", wholeWord: true, in: text, after: 3, existing: [r(0, 3)]) == r(8, 3))
        // Past the last: wraps to the first one not taken.
        #expect(MultiCaret.nextOccurrence(of: "foo", wholeWord: true, in: text, after: 19, existing: [r(16, 3), r(0, 3)]) == r(8, 3))
        // All taken: none.
        #expect(MultiCaret.nextOccurrence(of: "foo", wholeWord: true, in: text, after: 19, existing: [r(0, 3), r(8, 3), r(16, 3)]) == nil)
    }

    @Test func wholeWordVersusSubstring() {
        let text = "id width id idle" as NSString
        #expect(MultiCaret.nextOccurrence(of: "id", wholeWord: true, in: text, after: 2, existing: [r(0, 2)]) == r(9, 2))
        #expect(MultiCaret.nextOccurrence(of: "id", wholeWord: false, in: text, after: 2, existing: [r(0, 2)]) == r(4, 2))
        let all = MultiCaret.allOccurrences(of: "id", wholeWord: true, in: text)
        #expect(all.ranges == [r(0, 2), r(9, 2)] && !all.capped)
        let capped = MultiCaret.allOccurrences(of: "id", wholeWord: false, in: text, limit: 2)
        #expect(capped.ranges.count == 2 && capped.capped)
    }

    @Test func shiftFollowsForeignEdits() {
        // An input method inserts 1 unit at 4 (the primary): later carets move.
        let c = MultiCaret.shift([Caret(at: 1), Caret(at: 4), Caret(at: 8)], oldRange: r(4), newLength: 1)
        #expect(c.map(\.head) == [1, 5, 9])
        // A replaced range: carets inside it go to its end.
        let d = MultiCaret.shift([Caret(at: 1), Caret(at: 5), Caret(at: 9)], oldRange: r(4, 3), newLength: 1)
        #expect(d.map(\.head) == [1, 5, 7])
    }

    @Test func lfOnlyBufferLines() {
        // The buffer is LF-normalised: line ends and columns never see "\r".
        let text = "ab\ncd" as NSString
        let lines = LineIndex(text)
        #expect(MultiCaret.move(carets(0, 3), .lineEnd, extend: false, in: text, lines: lines).map(\.head) == [2, 5])
    }
}
