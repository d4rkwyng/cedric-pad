import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// propose_edit in Ask Cedric (0.4.1): find/replace proposals, up to five
/// per answer, offered only to tool-trusted models and only for a change
/// request; the eval's cases for using it and for leaving it alone.
@Suite struct OwlProposeEditAITests {
    static let doc = (1...8).map { "Line \($0) says hello number \($0)." }.joined(separator: "\n") + "\n"
    static func snap() -> OwlDocumentSnapshot { OwlDocumentSnapshot(text: doc, generation: 2, fileName: "a.txt", language: "plain") }
    static func edit(_ find: String, _ replace: String) -> OwlToolCall {
        OwlToolCall(name: "propose_edit", arguments: .object(["find": .string(find), "replace": .string(replace), "reason": .string("r")]))
    }

    @Test func toolboxTakesFiveSeparateEditsAndRefusesMoreOrOverlaps() {
        let box = OwlToolbox(snapshot: Self.snap(), allowed: [.proposeEdit, .getLines])
        #expect(box.run(Self.edit("number 1.", "number one.")).ok)
        // Overlaps the first: refused, with a reason the model can act on.
        let overlap = box.run(Self.edit("hello number 1", "hi number 1"))
        #expect(!overlap.ok && overlap.text.contains("overlaps"))
        for i in 2...5 { #expect(box.run(Self.edit("number \(i).", "number \(i)!")).ok) }
        let sixth = box.run(Self.edit("number 6.", "number 6!"))
        #expect(!sixth.ok && sixth.text.contains("at most \(OwlTools.maxProposals)"))
        #expect(box.proposals.map(\.firstLine) == [1, 2, 3, 4, 5])
        // Not offered: refused like any tool that isn't.
        let off = OwlToolbox(snapshot: Self.snap(), allowed: [.getLines])
        #expect(!off.run(Self.edit("number 1.", "x")).ok && off.proposals.isEmpty)
    }

    /// Two edits in one round, then the answer.
    struct TwoEdits: OwlChatEngine {
        var title: String { "two" }
        var scoreKey: String { "two" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            let ran = messages.contains { if case .toolResult = $0 { return true }; return false }
            if !ran, tools.contains(where: { $0.name == .proposeEdit }) {
                return .toolCalls([OwlProposeEditAITests.edit("Line 2 says hello", "Line 2 says hi"),
                                   OwlProposeEditAITests.edit("number 7.", "number seven.")])
            }
            onText("Changed two lines.")
            return .answer("Changed two lines.")
        }
    }

    final class Proposals: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [OwlEditProposal] = []
        func add(_ e: OwlChatEvent) { if case .proposal(let p) = e { lock.withLock { all.append(p) } } }
        var value: [OwlEditProposal] { lock.withLock { all } }
    }

    @Test func runnerKeepsEveryProposalInOrderAndNeverEdits() async throws {
        let s = Self.snap()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        let req = OwlChatRequest(question: "Rewrite lines 2 and 7 to be friendlier.", context: ctx, snapshot: s, useTools: true, prose: true)
        #expect(req.tools.contains(.proposeEdit))
        let seen = Proposals()
        let o = try await OwlChatRunner.run(req, engine: TwoEdits()) { seen.add($0) }
        #expect(o.proposals.map(\.firstLine) == [2, 7])
        #expect(seen.value == o.proposals)
        #expect(o.proposals.allSatisfy { $0.anchor == .text && $0.isCurrent(text: Self.doc as NSString, generation: 9) })
        #expect(req.snapshot.text == Self.doc)
        // A question gets no propose_edit, so the same engine just answers.
        let ask = OwlChatRequest(question: "Is line 2 friendly enough?", context: ctx, snapshot: s, useTools: true, prose: true)
        #expect(!ask.tools.contains(.proposeEdit))
        let q = try await OwlChatRunner.run(ask, engine: TwoEdits()) { _ in }
        #expect(q.proposals.isEmpty)
    }

    @Test func modelsBelowTheGateGetNoTools() {
        let gate = OwlToolGate.bundled()
        #expect(!gate.allowsTools("apple:apple-on-device"))
        #expect(gate.allowsTools("builtIn:qwen3-4b-instruct-2507-q4_k_m"))
        let s = Self.snap()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        // Apple Intelligence (useTools false): no tools at all, not even for an edit request.
        #expect(OwlChatRequest(question: "Rewrite line 2.", context: ctx, snapshot: s, useTools: false, prose: true).tools.isEmpty)
    }

    @Test func promptsTeachFindReplaceOnlyWhenItIsOffered() {
        let s = Self.snap()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        func system(_ canEdit: Bool) -> String {
            guard case .system(let t)? = OwlPrompts.chatMessages(question: "Q", context: ctx, language: "Plain", fileName: nil, history: [],
                                                                  toolsOn: true, model: "x", canEdit: canEdit).first else { return "" }
            return t
        }
        #expect(system(true).contains("propose_edit with find"))
        #expect(!system(false).contains("propose_edit"))
        let with = OwlPrompts.envelopeInstructions(OwlTools.specs([.getLines, .proposeEdit]))
        #expect(with.contains(#"{"tool":"propose_edit","args":{"find":"#))
        #expect(!OwlPrompts.envelopeInstructions(OwlTools.specs([.getLines])).contains(#""tool":"propose_edit""#))
        // The quick actions ask for find/replace with tools, a ``` block without.
        let tools = OwlPrompts.quickInstruction(.rewrite, prose: true, toolsOn: true, context: ctx)
        #expect(tools.contains("find") && tools.contains("replace") && !tools.contains("start"))
        #expect(OwlPrompts.quickInstruction(.rewrite, prose: true, toolsOn: false, context: ctx).contains("``` block"))
    }

    /// Calls one fixed tool, whatever it is asked.
    struct Fixed: OwlChatEngine {
        let call: OwlToolCall
        var title: String { "fixed" }
        var scoreKey: String { "fixed" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn { .toolCalls([call]) }
    }

    @Test func evalCasesUseItWhenAskedAndScoreItStrictly() async {
        let editCases = OwlToolEval.cases.filter { $0.expect.contains(.proposeEdit) }
        #expect(editCases.count == 10)
        for c in editCases {
            #expect(OwlToolEval.offeredTools(c.question, OwlToolEval.snapshot(c)).contains(.proposeEdit), "\(c.question)")
        }
        // Questions with an edit word: the right move is to answer.
        let questions = ["Is the sentence on line 3 correct English?", "What would you change on line 9 to make it safer? Just tell me.",
                         "Change of plan: what is the greeting on line 1?", "Does the version on line 3 need fixing?"]
        for q in questions { #expect(OwlToolEval.cases.contains { $0.question == q && $0.expect.isEmpty }, "\(q)") }
        let md = OwlToolEval.cases.first { $0.question.hasPrefix("Shorten line 3") }!
        let right = await OwlToolEval.run(md, engine: Fixed(call: Self.edit("Notes on the vegetable garden for this year.", "Garden notes for this year.")))
        #expect(right.pass, "\(right.got)")
        // Text that isn't in the document, or the wrong line, fails.
        let missing = await OwlToolEval.run(md, engine: Fixed(call: Self.edit("Notes on the garden.", "Garden notes for this year.")))
        #expect(!missing.pass)
        let wrongLine = await OwlToolEval.run(md, engine: Fixed(call: Self.edit("# Garden notes", "# Notes")))
        #expect(!wrongLine.pass)
        // Calling it for a question fails.
        let plan = OwlToolEval.cases.first { $0.question.hasPrefix("Change of plan") }!
        #expect(OwlToolEval.offeredTools(plan.question, OwlToolEval.snapshot(plan)).contains(.proposeEdit))
        let eager = await OwlToolEval.run(plan, engine: Fixed(call: Self.edit("Dear Ms. Lane,", "Dear Ms Lane,")))
        #expect(!eager.pass)
    }
}
