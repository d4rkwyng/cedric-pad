import Foundation
import Testing
@testable import CedricCore

/// Ask Cedric's pure parts: the frozen snapshot, the context chip and
/// proposals going stale.
@Suite struct OwlChatContextTests {
    static let doc = "one\ntwo\nthree\nfour\nfive"

    @Test func snapshotLinesAreOneBasedAndClamped() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1)
        #expect(s.lineCount == 5)
        #expect(s.range(lines: 2, 3) == NSRange(location: 4, length: 9))
        #expect(s.substring(s.range(lines: 4, 99)!) == "four\nfive")
        #expect(s.range(lines: 6, 7) == nil)
        #expect(s.numbered(lines: 2, 3) == "2| two\n3| three")
        #expect(s.lineNumber(at: 0) == 1 && s.lineNumber(at: 4) == 2)
    }

    @Test func selectionEndingAfterANewlineDoesNotTakeTheNextLine() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 4, length: 4))  // "two\n"
        let span = s.lineSpan(s.selection)
        #expect(span.first == 2 && span.last == 2)
    }

    @Test func scopesOfferSelectionOnlyWithOneAndWholeOnlyIfItFits() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1)
        #expect(OwlChatContext.scopes(for: s, budget: 1000) == [.visible, .wholeDocument])
        #expect(OwlChatContext.scopes(for: s, budget: 10) == [.visible])
        let sel = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 4, length: 3))
        #expect(OwlChatContext.scopes(for: sel, budget: 1000) == [.selection, .visible, .wholeDocument])
        #expect(OwlChatContext.defaultScope(for: sel) == .selection)
        #expect(OwlChatContext.build(s, scope: .selection, budget: 1000) == nil)
    }

    @Test func contextIsNumberedWholeLinesTrimmedToTheBudget() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 5, length: 6), visible: NSRange(location: 0, length: 23))
        let sel = OwlChatContext.build(s, scope: .selection, budget: 1000)!
        #expect(sel.numbered == "2| two\n3| three")
        #expect(sel.label == "Selection (2 lines)")
        let vis = OwlChatContext.build(s, scope: .visible, budget: 20)!
        #expect(vis.firstLine == 1 && vis.truncated)
        #expect(vis.numbered.hasPrefix("1| one"))
        #expect(!vis.numbered.contains("five"))
    }

    @Test func proposalAppliesOnlyToTheUnchangedDocument() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 4)
        let p = OwlEditProposal.lines(2, 3, with: "TWO\nTHREE\n", in: s)!
        #expect(p.original == "two\nthree" && p.replacement == "TWO\nTHREE")   // trailing newline dropped
        #expect(p.isCurrent(text: Self.doc as NSString, generation: 4))
        #expect(!p.isCurrent(text: Self.doc as NSString, generation: 5))                              // edited (and maybe undone)
        #expect(!p.isCurrent(text: "one\ntwo!\nthree\nfour\nfive" as NSString, generation: 4))       // text moved under it
        #expect(!p.isCurrent(text: "one" as NSString, generation: 4))                                 // shorter
        #expect(OwlEditProposal.lines(2, 2, with: "two", in: s) == nil)                               // no change
        #expect(OwlEditProposal.lines(9, 9, with: "x", in: s) == nil)
    }

    @Test func proposalDiffAndMarkdown() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1)
        let p = OwlEditProposal.lines(2, 3, with: "two\nTHREE", in: s)!
        #expect(p.unifiedText == "  two\n- three\n+ THREE")
        let md = OwlChatEntry.markdown([OwlChatEntry(role: .user, text: "Fix"), OwlChatEntry(role: .owl, text: "Done", proposal: p)], fileName: "a.txt")
        #expect(md.hasPrefix("# Ask Cedric — a.txt\n"))
        #expect(md.contains("**You:** Fix") && md.contains("```diff\n  two\n- three\n+ THREE\n```"))
    }
}
