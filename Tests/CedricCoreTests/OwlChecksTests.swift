import Foundation
import Testing
@testable import CedricCore

/// check_document (0.4.0): the offline checks' findings as a short list
/// (line, rule, message) for Ask Cedric, and which tools a typed question
/// is offered.
@Suite struct OwlChecksTests {
    static let doc = "# Notes\n\nSee [setup](#setpu) for details.\n\n### Deep\n\nText here.\n\n## Setup\n\nMore text.\n"

    func snap(_ text: String = Self.doc, visible: NSRange? = nil, facts: OwlDocumentFacts = OwlDocumentFacts(),
              grammar: [GrammarIssue] = [], sel: NSRange = NSRange(location: 0, length: 0)) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: text, generation: 1, selection: sel, visible: visible, fileName: "notes.md", language: "markdown",
                            facts: facts, grammar: grammar)
    }

    @Test func listsTheWritingChecksWithLineNumbers() {
        let r = OwlChecks.run(snap())
        #expect(r.whole)
        #expect(r.findings.contains { $0.line == 3 && $0.rule == "md.broken-anchor" })
        #expect(r.findings.contains { $0.line == 5 && $0.rule == "md.heading-skip" })
        let out = OwlTools.run(OwlToolCall(name: "check_document"), on: snap())
        #expect(out.ok)
        #expect(out.text.hasPrefix("Offline checks of the whole document: "))
        #expect(out.text.contains("3| md.broken-anchor: "))
        #expect(out.text.contains("5| md.heading-skip: "))
    }

    @Test func grammarFindingsJoinAndTheFileStateIsLeftOut() {
        let at = (Self.doc as NSString).range(of: "Text here")
        let g = GrammarIssue(range: at, original: "Text here", description: "Use a verb.", corrections: ["The text is here"])
        let facts = OwlDocumentFacts(changedOnDisk: true, unsavedSince: Date(timeIntervalSince1970: 0))
        let r = OwlChecks.run(snap(facts: facts, grammar: [g]))
        #expect(r.findings.contains { $0.line == 7 && $0.rule == "grammar" && $0.message.contains("“The text is here”") })
        #expect(!r.findings.contains { $0.rule == "changed-on-disk" || $0.rule == "unsaved-long" })
        // A clean document says so.
        let clean = OwlChecks.listing(OwlChecks.run(snap("# Fine\n\nAll good.\n")))
        #expect(clean == "Offline checks of the whole document: no problems found.")
    }

    @Test func aLongDocumentIsCheckedAroundTheVisibleTextAndTheListIsCapped() {
        var text = ""
        for i in 1...6_000 { text += "Line \(i) links to [nowhere](#missing-\(i)) and more words.\n" }
        let ns = text as NSString
        let visible = ns.lineRange(for: NSRange(location: ns.length / 2, length: 0))
        let s = snap(text, visible: visible)
        let r = OwlChecks.run(s)
        #expect(!r.whole)
        #expect(r.firstLine > 1 && r.lastLine < s.lineCount)
        #expect(r.findings.allSatisfy { $0.line >= r.firstLine && $0.line <= r.lastLine })
        let many = (1...200).map { OwlChecks.Finding(line: $0, rule: "x", message: String(repeating: "word ", count: 10)) }
        let listed = OwlChecks.listing(OwlChecks.Report(findings: many, firstLine: 1, lastLine: 200, whole: true))
        #expect(listed.utf8.count <= OwlTools.maxOutputBytes)
        #expect(OwlChecks.listing(r).hasPrefix("Offline checks of lines \(r.firstLine)-\(r.lastLine) (the file is too long"))
    }

    @Test func questionsAboutProblemsAreRecognised() {
        for q in ["What problems does this file have?", "Any broken links?", "check my grammar", "What's wrong with it?", "Are there typos?"] {
            #expect(OwlChecks.asksAboutProblems(q), "\(q)")
        }
        for q in ["Summarise this", "How many games per system?", "What does line 3 say?", "Who wrote this letter?"] {
            #expect(!OwlChecks.asksAboutProblems(q), "\(q)")
        }
    }

    @Test func aTypedQuestionIsOfferedOnlyTheToolsItNeeds() {
        let s = snap()
        #expect(OwlTools.typedTools(question: "What does the intro say?", snapshot: s) == [.getLines, .searchDocument, .getOutline])
        #expect(OwlTools.typedTools(question: "What problems does this file have?", snapshot: s).contains(.checkDocument))
        #expect(!OwlTools.typedTools(question: "Summarise it", snapshot: s).contains(.proposeEdit))
        #expect(OwlTools.typedTools(question: "Rename the heading on line 1", snapshot: s).contains(.proposeEdit))
        #expect(OwlTools.typedTools(question: "How many words?", snapshot: s).contains(.documentStats))
        let sel = snap(sel: NSRange(location: 0, length: 7))
        #expect(OwlTools.typedTools(question: "Explain this", snapshot: sel).first == .getSelection)
        // Find Problems (the quick action) has the checks too.
        #expect(OwlQuickAction.findProblems.tools.contains(.checkDocument))
    }
}

extension OwlChecksTests {
    @Test func eachPlaceOfARuleIsListedOnItsOwnLine() {
        let text = "# A\n\nSee [one](#nowhere).\n\nAnd [two](#missing).\n\n## B\n\nThen [three](#gone).\n"
        let r = OwlChecks.run(snap(text))
        #expect(r.findings.filter { $0.rule == "md.broken-anchor" }.map(\.line) == [3, 5, 9])
        #expect(!OwlChecks.listing(r).contains("more like it"))
    }
}
