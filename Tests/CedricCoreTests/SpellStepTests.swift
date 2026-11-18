import Foundation
import Testing
@testable import CedricCore

@Suite struct SpellStepTests {
    /// Every occurrence of the words in `typos`, as a checker would flag them.
    func flagged(_ text: NSString, _ typos: Set<String>, in chunk: NSRange) -> [SpellStepItem] {
        var out: [SpellStepItem] = []
        let re = try! NSRegularExpression(pattern: "[A-Za-z]+")
        for m in re.matches(in: text as String, range: chunk) {
            let w = text.substring(with: m.range)
            if typos.contains(w) { out.append(SpellStepItem(range: m.range, word: w)) }
        }
        return out
    }

    /// Scans every chunk (as the app does in idle turns).
    func scanAll(_ s: inout SpellStepper, _ text: NSString, _ typos: Set<String>) {
        while let c = s.nextChunk() { s.add(flagged(text, typos, in: c)) }
    }

    func apply(_ edits: [SpellStepEdit], to text: NSMutableString) {
        for e in edits { text.replaceCharacters(in: e.range, with: e.replacement) }
    }

    @Test func wordsInOrderFromTheCaretThenWrap() {
        let text = "one tpyo two mispeled three wrod four" as NSString
        // Caret inside "two": its start is the anchor.
        var s = SpellStepper(text: text, caret: text.range(of: "two").location + 1, chunkLength: 16)
        #expect(s.anchor == text.range(of: "two").location)
        #expect(s.unscanned.count > 1) // chunked
        scanAll(&s, text, ["tpyo", "mispeled", "wrod"])
        var seen: [String] = []
        while let w = s.advance() { seen.append(w.word); s.skip() }
        #expect(seen == ["mispeled", "wrod", "tpyo"])
        #expect(s.isFinished)
        #expect(s.visited == 3)
    }

    @Test func chunksCoverTheTextAtWordBoundaries() {
        let text = String(repeating: "alpha beta gamma\n", count: 40) as NSString
        let chunks = SpellStepper.chunks(text, from: 0, to: text.length, chunkLength: 100)
        #expect(chunks.first?.location == 0)
        #expect(chunks.map(\.length).reduce(0, +) == text.length)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        // Each ends after a newline (or at the end).
        for c in chunks.dropLast() { #expect(text.character(at: NSMaxRange(c) - 1) == 10) }
        // A long line without newlines: cut at spaces.
        let long = String(repeating: "word ", count: 100) as NSString
        for c in SpellStepper.chunks(long, from: 0, to: long.length, chunkLength: 64).dropLast() {
            #expect(long.character(at: NSMaxRange(c) - 1) == 32)
            #expect(c.length <= 64)
        }
    }

    @Test func progressCountsAndKnowsWhenTheScanIsDone() {
        let text = "tpyo and tpyo and wrod" as NSString
        var s = SpellStepper(text: text, caret: 0, chunkLength: 16)
        if let c = s.nextChunk() { s.add(flagged(text, ["tpyo", "wrod"], in: c)) }
        s.advance()
        #expect(s.progress.index == 1)
        #expect(!s.progress.final)
        scanAll(&s, text, ["tpyo", "wrod"])
        #expect(s.progress == (1, 3, true))
        s.skip(); s.advance()
        #expect(s.progress == (2, 3, true))
    }

    @Test func ignoreAllPassesEveryOccurrenceIncludingLaterChunks() {
        let text = "tpyo wrod tpyo\nmore text here tpyo wrod" as NSString
        var s = SpellStepper(text: text, caret: 0, chunkLength: 16)
        if let c = s.nextChunk() { s.add(flagged(text, ["tpyo", "wrod"], in: c)) }
        #expect(s.advance()?.word == "tpyo")
        s.ignoreAll()
        scanAll(&s, text, ["tpyo", "wrod"]) // the later "tpyo" is never queued
        var seen: [String] = []
        while let w = s.advance() { seen.append(w.word); s.skip() }
        #expect(seen == ["wrod", "wrod"])
        #expect(s.visited == 4) // both early tpyos, then the two wrods
    }

    @Test func changeShiftsTheWordsAfterIt() {
        let text = NSMutableString(string: "a tpyo b wrod c")
        var s = SpellStepper(text: text, caret: 0)
        scanAll(&s, text, ["tpyo", "wrod"])
        s.advance()
        let e = s.change(to: "typo-fixed")!
        #expect(e == SpellStepEdit(range: NSRange(location: 2, length: 4), replacement: "typo-fixed"))
        apply([e], to: text)
        let next = s.advance()!
        #expect(text.substring(with: next.range) == "wrod")
        #expect(s.changed == 1)
    }

    @Test func changeAllGivesEditsLastFirstAndCorrectOffsets() {
        let text = NSMutableString(string: "teh cat, wrod, teh dog, teh end, wrod")
        var s = SpellStepper(text: text, caret: 0)
        scanAll(&s, text, ["teh", "wrod"])
        #expect(s.advance()?.word == "teh")
        let edits = s.changeAll(to: "the")
        #expect(edits.count == 3)
        #expect(edits.map(\.range.location) == edits.map(\.range.location).sorted(by: >))
        apply(edits, to: text)
        #expect(text as String == "the cat, wrod, the dog, the end, wrod")
        // The remaining words still point at "wrod" after the edits.
        while let w = s.advance() { #expect(text.substring(with: w.range) == "wrod"); s.skip() }
        #expect(s.changed == 3)
    }

    @Test func changeAllReachesWordsFoundLater() {
        let text = NSMutableString(string: "teh one\nteh two\nanother line\nteh three\n")
        var s = SpellStepper(text: text, caret: 0, chunkLength: 16)
        if let c = s.nextChunk() { s.add(flagged(text, ["teh"], in: c)) }
        s.advance()
        apply(s.changeAll(to: "the"), to: text)
        while let c = s.nextChunk() { apply(s.add(flagged(text, ["teh"], in: c)), to: text) }
        #expect(text as String == "the one\nthe two\nanother line\nthe three\n")
        #expect(s.isFinished)
        #expect(s.changed == 3)
    }

    @Test func userEditsMoveOrDropWordsAndChunks() {
        let text = NSMutableString(string: "tpyo one wrod two mispeled\nlast line tpyo")
        var s = SpellStepper(text: text, caret: 0, chunkLength: 16)
        if let c = s.nextChunk() { s.add(flagged(text, ["tpyo", "wrod", "mispeled"], in: c)) }
        s.advance() // tpyo at 0
        // The user types "XX" at the start: everything moves by 2, including chunks.
        let before = s.unscanned
        text.insert("XX", at: 0)
        s.textEdited(NSRange(location: 0, length: 0), newLength: 2)
        #expect(s.current?.range.location == 2)
        #expect(s.unscanned.map(\.location) == before.map { $0.location + 2 })
        // The user deletes "wrod": it is dropped, not shown.
        let w = text.range(of: "wrod")
        text.deleteCharacters(in: w)
        s.textEdited(w, newLength: 0)
        while let c = s.nextChunk() { s.add(flagged(text, ["tpyo", "wrod", "mispeled"], in: c)) }
        s.skip()
        var seen: [String] = []
        while let i = s.advance() { #expect(text.substring(with: i.range) == i.word); seen.append(i.word); s.skip() }
        #expect(seen == ["mispeled", "tpyo"])
    }

    @Test func editingTheCurrentWordDropsIt() {
        let text = NSMutableString(string: "tpyo wrod")
        var s = SpellStepper(text: text, caret: 0)
        scanAll(&s, text, ["tpyo", "wrod"])
        s.advance()
        text.replaceCharacters(in: NSRange(location: 0, length: 4), with: "typo")
        s.textEdited(NSRange(location: 0, length: 4), newLength: 4)
        #expect(s.current == nil)
        #expect(s.advance()?.word == "wrod")
    }

    @Test func emptyAndNoTypos() {
        var s = SpellStepper(text: "" as NSString, caret: 0)
        #expect(s.isFinished)
        #expect(s.advance() == nil)
        var t = SpellStepper(text: "all fine here" as NSString, caret: 5)
        scanAll(&t, "all fine here", [])
        #expect(t.isFinished)
        #expect(t.progress == (0, 0, true))
    }

    @Test func linksAndPathsAreRecognised() {
        let text = "see https://exmple.com/pth and /usr/lcal/bin or me@exmple.org but tpyo" as NSString
        #expect(SpellScope.isInLinkOrPath(text, at: text.range(of: "exmple")))
        #expect(SpellScope.isInLinkOrPath(text, at: text.range(of: "lcal")))
        #expect(SpellScope.isInLinkOrPath(text, at: text.range(of: "exmple.org")))
        #expect(!SpellScope.isInLinkOrPath(text, at: text.range(of: "tpyo")))
    }
}
