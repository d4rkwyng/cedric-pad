import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Ask Cedric on a document shown in part (0.4.0): the digest (outline
/// with counts, matching lines) for a model without the tool gate's
/// trust, get_outline's counts for one with tools, the coverage note
/// before the answer, and none of it when the model saw everything.
@Suite struct OwlAskScopeAITests {
    static let doc: String = {
        var s = "# Games\n"
        for sys in ["NES", "SNES", "Genesis"] {
            s += "## \(sys)\n"
            for i in 1...60 { s += "- \(sys) game \(i)\n" }
        }
        return s
    }()   // 184 lines
    static func snap(visibleLines: Int = 20) -> OwlDocumentSnapshot {
        let ns = doc as NSString
        var end = 0
        for _ in 0..<visibleLines { end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0))) }
        return OwlDocumentSnapshot(text: doc, generation: 1, visible: NSRange(location: 0, length: end),
                                   fileName: "games.md", language: "markdown")
    }
    static func request(_ q: String = "How many games per system?", action: OwlQuickAction? = nil, scope: OwlChatScope = .visible,
                        useTools: Bool = false, budget: Int = 5_000) -> OwlChatRequest {
        let s = snap()
        let ctx = OwlChatContext.build(s, scope: scope, budget: budget)!
        return OwlChatRequest(question: q, action: action, context: ctx, snapshot: s, useTools: useTools, prose: true)
    }

    /// Records what it was offered and its prompt, makes `call` once if offered tools, then answers.
    final class Probe: OwlChatEngine, @unchecked Sendable {
        var title: String { "probe" }; var scoreKey: String { "probe" }; var contextBudget: Int { 5_000 }
        var offered: [[String]] = []
        var system = ""
        var user = ""
        let call: OwlToolCall?
        init(call: OwlToolCall? = OwlToolCall(name: "get_outline")) { self.call = call }
        func turn(_ m: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            offered.append(tools.map(\.name.rawValue))
            if case .system(let s)? = m.first { system = s }
            if offered.count == 1, case .user(let u)? = m.last { user = u }
            if let call, !tools.isEmpty, offered.count == 1 { return .toolCalls([call]) }
            onText("Each has 60.")
            return .answer("Each has 60.")
        }
    }

    @Test func toolsAreUnchangedTheDigestIsTheUngatedPath() {
        // No tools without the gate's trust (the digest instead); the full set with it.
        #expect(Self.request().tools.isEmpty)
        #expect(Self.request(useTools: true).tools.contains(.getOutline))
        let sys = OwlPrompts.chatSystem(toolsOn: false, digest: true)
        #expect(sys.contains("count from the outline") && sys.contains("Never answer as if you had seen lines you haven't"))
        // Without a digest the prompts are what the tool eval measured.
        #expect(!OwlPrompts.chatSystem(toolsOn: false).contains("outline"))
        #expect(OwlPrompts.chatSystem(toolsOn: true, digest: true) == OwlPrompts.chatSystem(toolsOn: true))
    }

    @Test func coverageNoteSaysWhatWasSeen() {
        let r = Self.request()
        #expect(r.coverageNote() == "I can see lines 1–20 of 184.")
        #expect(r.coverageNote(linesRead: IndexSet(integersIn: 100...120), looks: [.getOutline])
                == "I can see lines 1–20 and 100–120 of 184, plus the outline and counts of the whole file.")
        #expect(r.coverageNote(linesRead: IndexSet(integersIn: 21...184)) == nil)
        #expect(Self.request(scope: .wholeDocument, budget: 50_000).coverageNote() == nil)
        #expect(Self.request("Explain", action: .explain).coverageNote() == nil)
        // The whole document asked for but trimmed to the budget: said too.
        let trimmed = Self.request(scope: .visible, budget: 200)
        #expect(trimmed.coverageNote()?.hasPrefix("I can see lines 1–") == true)
    }

    @Test func ungatedRunnerSendsTheDigestAndSaysCoverageFirst() async throws {
        let probe = Probe()
        let events = TextBuffer()
        let o = try await OwlChatRunner.run(Self.request("How many games for Genesis?"), engine: probe) { e in if case .text(let t) = e { events.append(t) } }
        #expect(probe.offered == [[]])
        #expect(probe.system.contains("count from the outline"))
        #expect(probe.user.contains("OUTLINE OF THE WHOLE DOCUMENT") && probe.user.contains("124| ## Genesis"))
        #expect(probe.user.hasSuffix("How many games for Genesis?"))
        // Shown 1-20; the digest showed 119-129 and the outline.
        let note = "I can see lines 1–20 and 119–129 of 184, plus the outline and counts of the whole file."
        #expect(o.answer == note + "\n\nEach has 60.")
        #expect(events.value == o.answer)
        #expect(o.coverageNote == note && o.modelAnswer == "Each has 60.")
    }

    @Test func gatedRunnerCountsTheToolsItUsed() async throws {
        let probe = Probe(call: OwlToolCall(name: "get_lines", arguments: .object(["start": .number(21), "end": .number(40)])))
        let o = try await OwlChatRunner.run(Self.request(useTools: true), engine: probe) { _ in }
        #expect(probe.offered.first?.contains("get_outline") == true)
        #expect(!probe.user.contains("OUTLINE OF THE WHOLE DOCUMENT"))
        #expect(o.coverageNote == "I can see lines 1–40 of 184.")
        let outlined = try await OwlChatRunner.run(Self.request(useTools: true), engine: Probe()) { _ in }
        #expect(outlined.coverageNote == "I can see lines 1–20 of 184, plus the outline and counts of the whole file.")
    }

    /// The small model's digest: the outline with counts, and the
    /// section matching the question's words, inside the budget.
    @Test func digestGivesTheOutlineAndTheMatchingSection() {
        let d = Self.request("What is in the Genesis section?").digest(budget: 2_000)!
        #expect(d.hasOutline)
        #expect(d.text.contains("OUTLINE OF THE WHOLE DOCUMENT (184 lines"))
        #expect(d.text.contains("Total in all 184 lines: 180 list items, 0 table rows"))
        #expect(d.text.contains("63| ## SNES [60 list items]"))
        // "genesis" matches line 124's heading: its section is 61 lines, too long, so lines around it.
        #expect(d.lines == IndexSet(integersIn: 119...129))
        #expect(d.text.contains("124| ## Genesis"))
        #expect((d.text as NSString).length <= 2_000)
        // Tight budget: no room, no digest parts that don't fit.
        #expect(Self.request().digest(budget: 100) == nil)
        // A gated model and a quick action get none (tools / their scope).
        #expect(Self.request(useTools: true).digest(budget: 2_000) == nil)
        #expect(Self.request("Explain", action: .explain).digest(budget: 2_000) == nil)
    }

    @Test func wholeDocumentAnswerHasNoNote() async throws {
        let probe = Probe()
        let o = try await OwlChatRunner.run(Self.request(scope: .wholeDocument, budget: 50_000), engine: probe) { _ in }
        #expect(o.answer == "Each has 60." && o.coverageNote == nil && o.modelAnswer == o.answer)
        #expect(probe.offered == [[]])
    }
}
