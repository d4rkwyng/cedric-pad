import Foundation
import Testing
@testable import CedricCore

@Suite struct GrammarTests {
    let text = "Hi Sam,\n\nWe saw a elephant at the zoo. We went to the the park.\n" as NSString

    func results() -> [GrammarResult] {
        let s1 = text.range(of: "We saw a elephant at the zoo.")
        let s2 = text.range(of: "We went to the the park.")
        return [GrammarResult(sentence: s1, details: [GrammarDetail(range: NSRange(location: 7, length: 1),
                                                                    description: "Consider ‘an’  instead", corrections: ["an"])]),
                GrammarResult(sentence: s2, details: [GrammarDetail(range: NSRange(location: 11, length: 7),
                                                                    description: "The word ‘the’ may be inadvertently doubled.", corrections: ["the"])])]
    }

    @Test func mapsSentenceRelativeRanges() {
        let issues = GrammarMap.issues(results(), text: text)
        #expect(issues.count == 2)
        #expect(issues[0].range.location == text.range(of: "a elephant").location)
        #expect(issues[0].correction == "an")
        #expect(issues[0].description == "Consider ‘an’ instead.")
        #expect(issues[1].original == "the the")
        #expect(GrammarMap.isDoubledWord(issues[1]))
        #expect(!GrammarMap.isDoubledWord(issues[0]))
    }

    @Test func offsetAndProseScope() {
        // Checked text starting at 100 in the document; only the first sentence is prose.
        let s1 = text.range(of: "We saw a elephant at the zoo.")
        let prose = [NSRange(location: 100 + s1.location, length: s1.length)]
        let issues = GrammarMap.issues(results(), text: text, offset: 100, prose: prose)
        #expect(issues.count == 1)
        #expect(issues[0].range.location == 100 + text.range(of: "a elephant").location)
    }

    @Test func dropsBadRanges() {
        let bad = [GrammarResult(sentence: NSRange(location: 0, length: 5), details: [
            GrammarDetail(range: NSRange(location: 3, length: 9), description: "x", corrections: []),  // past the sentence
            GrammarDetail(range: NSRange(location: 1, length: 0), description: "x", corrections: []),  // empty
        ]), GrammarResult(sentence: NSRange(location: 900, length: 5), details: [
            GrammarDetail(range: NSRange(location: 0, length: 1), description: "x", corrections: []),  // past the text
        ])]
        #expect(GrammarMap.issues(bad, text: text).isEmpty)
    }

    @Test func hintTitleIdAndRange() {
        let issues = GrammarMap.issues(results(), text: text, offset: 50)
        let h = GrammarMap.hint(issues[0], textStart: 40)
        #expect(h.title == "Grammar: ‘a’ → ‘an’?")
        #expect(h.detail == "Consider ‘an’ instead.")
        #expect(h.replacement == "an")
        #expect(h.range == NSRange(location: issues[0].range.location - 40, length: 1))
        #expect(GrammarMap.isGrammarHint(h.id) && h.id == "grammar.a→an")
        let none = GrammarIssue(range: NSRange(location: 0, length: 4), original: String(repeating: "word ", count: 10),
                                description: "Hmm.", corrections: [])
        let t = GrammarMap.title(none)
        #expect(t.count <= 60 && t.hasSuffix("’?") && t.contains("…"))
        #expect(GrammarMap.hint(none, textStart: 0).replacement == nil)
        #expect(GrammarMap.plainWords("  ") == "This may not be grammatical.")
    }

    @Test func pickSkipsDoubledAndPrefersAfterCaret() {
        let issues = GrammarMap.issues(results(), text: text)
        #expect(GrammarMap.pick(issues, caret: 0)?.original == "a")
        #expect(GrammarMap.pick(issues, caret: 200)?.original == "a") // wraps
        #expect(GrammarMap.pick([issues[1]], caret: 0) == nil)
        #expect(GrammarMap.pick(issues, caret: 0, eligible: { $0.original != "a" }) == nil)
    }

    @Test func shiftFollowsEdits() {
        let a = GrammarIssue(range: NSRange(location: 10, length: 3), original: "abc", description: "", corrections: [])
        #expect(GrammarMap.shift([a], oldRange: NSRange(location: 0, length: 2), newLength: 5)[0].range.location == 13)
        #expect(GrammarMap.shift([a], oldRange: NSRange(location: 20, length: 2), newLength: 0)[0].range.location == 10)
        #expect(GrammarMap.shift([a], oldRange: NSRange(location: 11, length: 1), newLength: 1).isEmpty)  // inside
        #expect(GrammarMap.shift([a], oldRange: NSRange(location: 13, length: 0), newLength: 1).isEmpty)  // typed right after
        #expect(GrammarMap.shift([a], oldRange: NSRange(location: 10, length: 0), newLength: 1).isEmpty)  // typed right before
        let merged = GrammarMap.merge([a], fresh: [], checked: NSRange(location: 0, length: 50))
        #expect(merged.isEmpty)
        #expect(GrammarMap.merge([a], fresh: [], checked: NSRange(location: 20, length: 50)) == [a])
    }

    @Test func popupPolicy() {
        var p = GrammarPopupPolicy(minInterval: 600, typingPause: 2)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(!p.mayPopUp(now: t0, lastTyping: t0.addingTimeInterval(-1)))   // still typing
        #expect(p.mayPopUp(now: t0, lastTyping: t0.addingTimeInterval(-3)))
        p.noteShown(t0)
        #expect(!p.mayPopUp(now: t0.addingTimeInterval(300), lastTyping: nil))  // once per 10 min
        #expect(p.mayPopUp(now: t0.addingTimeInterval(300), lastTyping: nil, userAsked: true))
        #expect(p.mayPopUp(now: t0.addingTimeInterval(601), lastTyping: nil))
    }

    @Test func stepperOrderProgressAndEdits() {
        func issue(_ at: Int) -> GrammarIssue { GrammarIssue(range: NSRange(location: at, length: 1), original: "a", description: "", corrections: ["an"]) }
        var s = GrammarStepper(issues: [issue(5), issue(50), issue(30)], caret: 20)
        #expect(s.total == 3)
        #expect(s.next()?.range.location == 30)
        #expect(s.progress == "1 of 3")
        // Change: "a" → "an" moves the later ones by one.
        let e = s.change(to: "an")!
        s.textEdited(e.range, newLength: 2)
        #expect(s.current == nil)
        #expect(s.next()?.range.location == 51)
        #expect(s.progress == "2 of 3")
        #expect(s.next()?.range.location == 5) // wraps round to the top
        #expect(s.progress == "3 of 3")
        #expect(s.next() == nil && s.isFinished)
    }
}
