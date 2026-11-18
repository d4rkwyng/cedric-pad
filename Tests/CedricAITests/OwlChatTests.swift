import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Ask Cedric: streaming parsers, the runner with the fake engine, and
/// proposals going stale.
@Suite struct OwlChatStreamingTests {
    @Test func utf8DecoderHoldsHalfCharacters() {
        var d = UTF8StreamDecoder()
        let bytes = Array("é€😀".utf8)   // 2 + 3 + 4 bytes
        var out = ""
        for b in bytes { out += d.append([b]) }
        out += d.flush()
        #expect(out == "é€😀")
        var d2 = UTF8StreamDecoder()
        #expect(d2.append([0xE2, 0x82]) == "")
        #expect(d2.append([0xAC, 0x41]) == "€A")
    }

    @Test func sseAndOpenAIDeltasAccumulateTextAndToolCalls() {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
            ": keep-alive",
            #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_lines","arguments":"{\"sta"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"rt\":3,\"end\":5}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
        var acc = OpenAIStreamAccumulator()
        var text = ""
        for l in lines { if let p = SSEParser.payload(l) { text += acc.add(p) } }
        #expect(text == "Hello")
        #expect(acc.content == "Hello")
        #expect(acc.finished)
        #expect(acc.toolCalls == [OwlToolCall(id: "c1", name: "get_lines", arguments: .object(["start": .number(3), "end": .number(5)]))])
    }

    @Test func nonStreamedBodyStillParses() {
        var acc = OpenAIStreamAccumulator()
        let t = acc.add(#"{"choices":[{"message":{"role":"assistant","content":"Whole answer"}}]}"#)
        #expect(t == "Whole answer")
    }

    @Test func envelopeStreamsTheAnswerString() {
        var p = EnvelopeStreamParser()
        var shown = ""
        for piece in ["{\"ans", "wer\": \"Line 3 ", "says \\\"hi\\\"", "\\nok\\u00e9", "\"}"] { shown += p.add(piece) }
        #expect(shown == "Line 3 says \"hi\"\noké")
        #expect(EnvelopeStreamParser.parse(p.raw) == .answer("Line 3 says \"hi\"\noké"))
        // A tool call streams no text.
        var q = EnvelopeStreamParser()
        #expect(q.add(#"{"tool":"get_outline","args":{}}"#) == "")
        #expect(EnvelopeStreamParser.parse(q.raw) == .toolCalls([OwlToolCall(id: "call_0", name: "get_outline")]))
    }

    @Test func envelopeGrammarListsOnlyTheOfferedTools() {
        let g = EnvelopeStreamParser.grammar(tools: [.getLines, .proposeEdit])
        #expect(g.contains(#"toolname ::= "\"get_lines\"" | "\"propose_edit\"""#))
        #expect(!g.contains("search_document"))
        #expect(g.hasPrefix("root ::= answer | call"))
    }

    @Test func fencedBlockAndLineNumbers() {
        #expect(OwlChatRunner.fencedBlock("Here:\n```swift\na\nb\n```\ndone") == "a\nb")
        #expect(OwlChatRunner.stripLineNumbers("3| a\n4| b") == "a\nb")
        #expect(OwlChatRunner.stripLineNumbers("a| b\nc") == "a| b\nc")
        #expect(OwlChatRunner.stripThinking("<think>hmm</think>\nYes") == "Yes")
    }
}

@Suite struct OwlChatRunnerTests {
    static let doc = "func total(_ items: [Int]) -> Int {\n    var t = 0\n    for i in items { t += i }\n    return t\n}\n"

    func snapshot(selection: NSRange = NSRange(location: 0, length: 0)) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: Self.doc, generation: 7, selection: selection, fileName: "Sum.swift", language: "swift")
    }

    final class Events: @unchecked Sendable {
        let lock = NSLock()
        var all: [OwlChatEvent] = []
        func add(_ e: OwlChatEvent) { lock.withLock { all.append(e) } }
        var text: String { lock.withLock { all.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined() } }
        var textCount: Int { lock.withLock { all.filter { if case .text = $0 { return true }; return false }.count } }
    }

    @Test func streamedTextAccumulatesToTheAnswer() async throws {
        let s = snapshot()
        let ctx = OwlChatContext.build(s, scope: .visible, budget: 6000)!
        let ev = Events()
        let o = try await OwlChatRunner.run(OwlChatRequest(question: "What is this?", context: ctx, snapshot: s, useTools: false, prose: false),
                                            engine: FakeChatEngine(delay: 0.001, pieces: 8)) { ev.add($0) }
        #expect(ev.textCount >= 8)
        #expect(ev.text == o.answer)
        #expect(o.proposal == nil)
        #expect(ev.all.first == .phase(.thinking))
        #expect(ev.all.contains(.phase(.writing)))
    }

    @Test func addCommentsWithToolsBecomesAProposal() async throws {
        let s = snapshot(selection: NSRange(location: 37, length: 13))   // "    var t = 0"
        let ctx = OwlChatContext.build(s, scope: .selection, budget: 6000)!
        #expect(ctx.firstLine == 2 && ctx.lastLine == 2)
        let ev = Events()
        let o = try await OwlChatRunner.run(OwlChatRequest(question: "Add Comments", action: .addComments, context: ctx, snapshot: s,
                                                           useTools: true, prose: false),
                                            engine: FakeChatEngine(delay: 0.001)) { ev.add($0) }
        #expect(o.toolCalls == 2)
        #expect(o.rounds == 2)
        let p = try #require(o.proposal)
        #expect(p.firstLine == 2 && p.lastLine == 2)
        #expect(p.original == "    var t = 0")
        #expect(p.replacement == "    // Cedric: checked\n    var t = 0")
        #expect(p.generation == 7)
        #expect(ev.all.contains(.proposal(p)))
        #expect(ev.all.contains { if case .tool(.getLines, _) = $0 { return true }; return false })
    }

    @Test func addCommentsWithoutToolsUsesTheReplyBlock() async throws {
        let s = snapshot(selection: NSRange(location: 37, length: 13))
        let ctx = OwlChatContext.build(s, scope: .selection, budget: 6000)!
        let o = try await OwlChatRunner.run(OwlChatRequest(question: "Add Comments", action: .addComments, context: ctx, snapshot: s,
                                                           useTools: false, prose: false),
                                            engine: FakeChatEngine(delay: 0.001)) { _ in }
        #expect(o.toolCalls == 0)
        #expect(o.proposal?.replacement == "    // Cedric: checked\n    var t = 0")
    }

    @Test func cancelStopsTheStream() async throws {
        let s = snapshot()
        let ctx = OwlChatContext.build(s, scope: .visible, budget: 6000)!
        let ev = Events()
        let t = Task {
            try await OwlChatRunner.run(OwlChatRequest(question: "Explain", context: ctx, snapshot: s, useTools: false, prose: false),
                                        engine: FakeChatEngine(delay: 0.05, pieces: 20)) { ev.add($0) }
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        t.cancel()
        let r = await t.result
        #expect(throws: (any Error).self) { try r.get() }
        let n = ev.textCount
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(ev.textCount == n)
        #expect(n < 20)
    }

    @Test func historyKeepsOnlyTheLastTwoTurns() {
        let s = snapshot()
        let ctx = OwlChatContext.build(s, scope: .visible, budget: 6000)!
        var h: [OwlChatEntry] = []
        for i in 1...4 { h.append(OwlChatEntry(role: .user, text: "q\(i)")); h.append(OwlChatEntry(role: .owl, text: "a\(i)")) }
        h.append(OwlChatEntry(role: .tool, text: "· Looked at lines 1–2"))
        let m = OwlPrompts.chatMessages(question: "now", context: ctx, language: "Swift", fileName: "Sum.swift", history: h, toolsOn: false, model: "x")
        #expect(m.count == 6)
        #expect(m[1] == .user("q3") && m[4] == .assistant("a4"))
        if case .user(let last) = m[5] { #expect(last.contains("1| func total") && last.hasSuffix("now")) } else { Issue.record("no user turn") }
    }

    @Test func serverRenderingUsesOpenAIToolMessages() throws {
        let call = OwlToolCall(id: "c1", name: "get_lines", arguments: .object(["start": .number(1), "end": .number(2)]))
        let wire = ServerChatEngine.render([.system("s"), .user("u"), .toolCalls([call]), .toolResult(callID: "c1", name: "get_lines", content: "1| a")])
        let data = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""tool_calls":[{"function":{"arguments":"{\"end\":2,\"start\":1}","name":"get_lines"},"id":"c1","type":"function"}]"#))
        #expect(json.contains(#"{"content":"1| a","name":"get_lines","role":"tool","tool_call_id":"c1"}"#))
    }

    @Test func builtInRenderingUsesTheEnvelope() {
        let call = OwlToolCall(id: "c1", name: "get_outline")
        let tools = OwlTools.specs([.getOutline])
        let m = BuiltInChatEngine.render([.system("S"), .user("U"), .toolCalls([call]), .toolResult(callID: "c1", name: "get_outline", content: "1| # A")], tools: tools)
        #expect(m.count == 4)
        #expect(m[0].content.hasPrefix("S\n\nTools:\n- get_outline(): "))
        #expect(m[2] == ChatMessage(role: "assistant", content: #"{"args":{},"tool":"get_outline"}"#))
        #expect(m[3] == ChatMessage(role: "user", content: "Result of get_outline:\n1| # A"))
    }
}
