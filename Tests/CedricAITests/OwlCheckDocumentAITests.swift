import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// check_document in Ask Cedric (0.4.0): the tool for a model trusted
/// with tools, the checks' list in the prompt for one without (Apple
/// Intelligence, TN3193's "run the tool before the call"), and the tool
/// eval offering each question only a few tools.
@Suite struct OwlCheckDocumentAITests {
    static let doc = "# Notes\n\nSee [setup](#setpu) for details.\n\n### Deep\n\nText here.\n\n## Setup\n\nMore text.\n"

    static func request(_ q: String, action: OwlQuickAction? = nil, useTools: Bool) -> OwlChatRequest {
        let s = OwlDocumentSnapshot(text: doc, generation: 1, fileName: "notes.md", language: "markdown")
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 5_000)!
        return OwlChatRequest(question: q, action: action, context: ctx, snapshot: s, useTools: useTools, prose: true)
    }

    @Test func withoutToolsAProblemQuestionGetsTheChecksInThePrompt() async throws {
        let probe = OwlAskScopeAITests.Probe(call: nil)
        _ = try await OwlChatRunner.run(Self.request("What problems does this file have?", useTools: false), engine: probe) { _ in }
        #expect(probe.offered == [[]])
        #expect(probe.user.contains("RESULTS OF OWLINK'S OFFLINE CHECKS"))
        #expect(probe.user.contains("3| md.broken-anchor: "))
        #expect(probe.system.contains("results of Owlink's offline checks"))
        // Not for other questions, nor for a quick action.
        let other = OwlAskScopeAITests.Probe(call: nil)
        _ = try await OwlChatRunner.run(Self.request("Summarise the notes", useTools: false), engine: other) { _ in }
        #expect(!other.user.contains("OFFLINE CHECKS") && !other.system.contains("offline checks"))
        #expect(Self.request("What problems?", action: .findProblems, useTools: false).checks(budget: 2_000) == nil)
        // No room left: no list (never over the budget).
        #expect(Self.request("Any errors?", useTools: false).checks(budget: 100) == nil)
    }

    @Test func withToolsTheModelCallsCheckDocument() async throws {
        let req = Self.request("What problems does this file have?", useTools: true)
        #expect(req.tools.contains(.checkDocument))
        #expect(req.checks(budget: 2_000) == nil)
        let probe = OwlAskScopeAITests.Probe(call: OwlToolCall(name: "check_document"))
        let events = EventLog()
        _ = try await OwlChatRunner.run(req, engine: probe) { events.add($0) }
        #expect(probe.offered.first?.contains("check_document") == true)
        #expect(events.tools.contains("Ran the document checks"))
        // The fake (keyword) engine picks it too.
        let call = FakeChatEngine.choose("What problems does this file have?", tools: Set(req.tools), first: 1, last: 12)
        #expect(call?.name == "check_document")
    }

    @Test func theEvalOffersEveryCaseItsToolAndFewTools() {
        for c in OwlToolEval.cases {
            let offered = OwlToolEval.offeredTools(c.question, OwlToolEval.snapshot(c))
            #expect(c.expect.isEmpty || !c.expect.isDisjoint(with: offered), "\(c.question): \(offered)")
            // Besides describe_image (every case, so a text document must leave it alone): 3 to 5.
            #expect((3...5).contains(offered.count - 1), "\(c.question): \(offered.count - 1) tools")
        }
        #expect(OwlToolEval.cases.contains { $0.expect == [.checkDocument] })
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _tools: [String] = []
        func add(_ e: OwlChatEvent) { if case .tool(_, let s) = e { lock.withLock { _tools.append(s) } } }
        var tools: [String] { lock.withLock { _tools } }
    }
}

/// read_section in Ask Cedric (0.4.0): offered to models trusted with
/// tools for a question about a section; Apple Intelligence keeps the
/// digest and gets no tools.
@Suite struct OwlReadSectionAITests {
    @Test func gatedModelsReadASectionAppleKeepsTheDigest() async throws {
        let s = OwlAskScopeAITests.snap()
        let ctx = OwlChatContext.build(s, scope: .visible, budget: 5_000)!
        let q = "What does the Genesis section list?"
        let gated = OwlChatRequest(question: q, context: ctx, snapshot: s, useTools: true, prose: true)
        #expect(gated.tools.contains(.readSection))
        let probe = OwlAskScopeAITests.Probe(call: OwlToolCall(name: "read_section", arguments: .object(["heading": .string("genesis")])))
        let out = try await OwlChatRunner.run(gated, engine: probe) { _ in }
        // The section's lines count as seen (Genesis starts at line 124; cut to what fit).
        let note = try #require(out.coverageNote)
        #expect(note.contains("1–20") && note.contains(" 124–"))
        // Apple: no tools, and the digest instead.
        let apple = OwlChatRequest(question: q, context: ctx, snapshot: s, useTools: false, prose: true)
        #expect(apple.tools.isEmpty)
        #expect(apple.digest(budget: 2_000) != nil)
        // The fake engine (the eval's CI mode) picks it with the heading.
        let call = FakeChatEngine.choose("What does the Pests section say?", tools: Set(gated.tools), first: 1, last: 12)
        #expect(call?.name == "read_section" && call?.arguments["heading"]?.string == "Pests")
    }
}
