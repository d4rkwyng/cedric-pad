import Foundation
import Testing
@testable import CedricCore

/// propose_edit anchored by text (0.4.1): the model gives the exact text
/// to find and its replacement; it applies only while that text occurs
/// exactly once in the live document, never in a read-only one, and is
/// offered only for questions that ask for a change.
@Suite struct OwlProposeEditTests {
    static let doc = "# Notes\n\nSeeds cost 40 euros.\nCompost cost 25 euros.\n\nWater every 2 days.\nWater every 3 days.\n"
    func snap(_ text: String = doc, generation: Int = 4) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: text, generation: generation, fileName: "notes.md", language: "markdown")
    }

    @Test func appliesWhereTheTextIsNowWhileItOccursOnce() throws {
        let p = try OwlEditProposal.anchored(find: "Seeds cost 40 euros.", replace: "Seeds cost 45 euros.", reason: "new price", in: snap()).get()
        #expect(p.anchor == .text && p.firstLine == 3 && p.lastLine == 3 && p.reason == "new price" && p.generation == 4)
        let at = (Self.doc as NSString).range(of: "Seeds cost 40 euros.")
        #expect(p.range == at)
        #expect(p.state(text: Self.doc as NSString, generation: 4) == .ready(at))
        // Typing elsewhere (a later generation, the text moved) doesn't matter.
        let moved = "Intro.\n" + Self.doc
        #expect(p.state(text: moved as NSString, generation: 9) == .ready(NSRange(location: at.location + 7, length: at.length)))
        // An edit inside it, or a second copy, makes it stale.
        #expect(p.state(text: Self.doc.replacingOccurrences(of: "40", with: "41") as NSString, generation: 5) == .stale)
        #expect(p.state(text: (Self.doc + "Seeds cost 40 euros.\n") as NSString, generation: 5) == .stale)
        #expect(!p.isCurrent(text: "" as NSString, generation: 4))
    }

    @Test func aReadOnlyDocumentNeverApplies() throws {
        let p = try OwlEditProposal.anchored(find: "Compost cost 25 euros.", replace: "Compost cost 30 euros.", in: snap()).get()
        #expect(p.state(text: Self.doc as NSString, generation: 4, readOnly: true) == .readOnly)
        // A quick action's line edit too.
        let lines = try #require(OwlEditProposal.lines(3, 3, with: "x", in: snap()))
        #expect(lines.state(text: Self.doc as NSString, generation: 4, readOnly: true) == .readOnly)
        #expect(lines.state(text: Self.doc as NSString, generation: 4) == .ready(lines.range))
    }

    @Test func forgivesCopiedLineNumbersAndAFinalNewline() throws {
        let numbered = try OwlEditProposal.anchored(find: "3| Seeds cost 40 euros.\n4| Compost cost 25 euros.",
                                                    replace: "3| Seeds cost 45 euros.\n4| Compost cost 25 euros.", in: snap()).get()
        #expect(numbered.original == "Seeds cost 40 euros.\nCompost cost 25 euros.")
        #expect(numbered.replacement == "Seeds cost 45 euros.\nCompost cost 25 euros.")
        #expect(numbered.firstLine == 3 && numbered.lastLine == 4)
        let newline = try OwlEditProposal.anchored(find: "# Notes", replace: "# Garden notes\n", in: snap()).get()
        #expect(newline.replacement == "# Garden notes")
    }

    @Test func refusesWhatCanNotBeAnchored() {
        func refusal(_ find: String, _ replace: String = "x") -> OwlEditProposal.Refusal? {
            if case .failure(let r) = OwlEditProposal.anchored(find: find, replace: replace, in: snap()) { return r }
            return nil
        }
        #expect(refusal("  \n") == .empty)
        #expect(refusal("Seeds cost 50 euros.") == .notFound)
        #expect(refusal("Water every") == .notUnique)
        #expect(refusal("Seeds cost 40 euros.", "Seeds cost 40 euros.") == .noChange)
        #expect(refusal(String(repeating: "a", count: OwlTools.maxFindLength + 1)) == .tooLong)
        #expect(refusal("# Notes", String(repeating: "b", count: OwlTools.maxReplaceLength + 1)) == .tooLong)
        // Overlapping matches count: "aa" is twice in "aaa".
        #expect(OwlEditProposal.occurrences(of: "aa", in: "aaa").count == 2)
        // A long reason is cut, not refused.
        let long = try? OwlEditProposal.anchored(find: "# Notes", replace: "# N", reason: String(repeating: "r", count: 500), in: snap()).get()
        #expect(long?.reason.count == OwlTools.maxReasonLength)
    }

    @Test func toolTakesATypedFindReplaceReason() {
        let spec = OwlTools.spec(.proposeEdit)
        #expect(spec.parameters["required"] == .array([.string("find"), .string("replace"), .string("reason")]))
        #expect(spec.parameters["properties"]?["reason"]?["maxLength"]?.int == OwlTools.maxReasonLength)
        let r = OwlTools.run(OwlToolCall(name: "propose_edit", arguments: .object([
            "find": .string("Compost cost 25 euros."), "replace": .string("Compost cost 30 euros."), "reason": .string("price")])), on: snap())
        #expect(r.ok && r.proposal?.firstLine == 4 && r.summary == "Proposed a change to line 4")
        // It only proposes: the snapshot's text is what it was.
        #expect(snap().text == Self.doc)
        // Line ranges (the 0.4.0 form) are refused.
        #expect(!OwlTools.run(OwlToolCall(name: "propose_edit", arguments: .object([
            "start": .number(3), "end": .number(3), "new_text": .string("x")])), on: snap()).ok)
    }

    @Test func onlyAChangeRequestIsOfferedTheEdit() {
        for q in ["Rewrite line 3 to be more formal.", "Please fix the typo in the title", "Can you shorten the intro?",
                  "Could you rephrase the second sentence?", "Correct the spelling on line 2", "I want you to rename Config to AppConfig",
                  "In helper10, change the multiplier to 100 by proposing an edit.", "Propose an edit that changes line 3",
                  "Update the version to 0.2.0"] {
            #expect(OwlTools.asksForChange(q), "\(q)")
        }
        for q in ["Is the sentence on line 3 correct?", "What would you change on line 9?", "How do I fix this error?",
                  "What does the comment on line 3 mean?", "Summarise it", "Translate 'good morning' into French.",
                  "Does line 3 need fixing?", "Which edits did I make yesterday?", "Why is this wrong?", ""] {
            #expect(!OwlTools.asksForChange(q), "\(q)")
        }
    }

    @Test func anEditRequestStaysWithinFiveTools() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 0, length: 7),
                                    fileName: "notes.md", language: "markdown")
        // Selection, problems, stats and a heading word: everything asks to be offered.
        let t = OwlTools.typedTools(question: "Fix the problems and the word count in the Notes section", snapshot: s)
        #expect(t.contains(.proposeEdit) && t.contains(.checkDocument) && t.contains(.getSelection))
        #expect((3...5).contains(t.count), "\(t)")
        #expect(!OwlTools.typedTools(question: "Is line 3 correct?", snapshot: s).contains(.proposeEdit))
    }

    @Test func markdownCopyListsEveryProposalWithItsReason() throws {
        let a = try OwlEditProposal.anchored(find: "Seeds cost 40 euros.", replace: "Seeds cost 45 euros.", reason: "new price", in: snap()).get()
        let b = try OwlEditProposal.anchored(find: "Compost cost 25 euros.", replace: "Compost cost 30 euros.", in: snap()).get()
        let e = OwlChatEntry(role: .owl, text: "Two changes.", proposals: [a, b])
        #expect(e.proposal == a)
        let md = OwlChatEntry.markdown([e], fileName: "notes.md")
        #expect(md.contains("_new price_"))
        #expect(md.contains("- Seeds cost 40 euros.\n+ Seeds cost 45 euros.") && md.contains("- Compost cost 25 euros.\n+ Compost cost 30 euros."))
        #expect(!a.overlaps(b) && a.overlaps(a))
    }
}
