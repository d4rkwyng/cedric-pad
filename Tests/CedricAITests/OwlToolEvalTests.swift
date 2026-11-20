import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The tool eval (Scripts/owl-tools-eval.sh). CI mode: the fake engine,
/// which proves the harness and the scorer end to end. Live mode
/// (CEDRIC_OWL_EVAL=builtIn[:model] | lmStudio:model | ollama:model | apple)
/// runs a real engine; CEDRIC_OWL_EVAL_RECORD=1 writes its score to
/// Resources/AI/owl-tool-scores.json.
@Suite struct OwlToolEvalTests {
    @Test func theSetHasFortySixCasesOverSevenDocuments() {
        #expect(OwlToolEval.cases.count == 46)
        #expect(Set(OwlToolEval.cases.map(\.doc)) == ["md", "swift", "json", "csv", "prose", "html", "svg"])
        #expect(OwlToolEval.cases.filter { $0.expect.isEmpty }.count >= 8)   // abstain cases
        for t in OwlToolName.allCases { #expect(OwlToolEval.cases.contains { $0.expect.contains(t) }, "\(t) is covered") }
        // Every get_lines case points past what the model is shown.
        for c in OwlToolEval.cases where c.expect == [.getLines] {
            #expect(Int(c.arg!.value)! > OwlToolEval.shown)
        }
    }

    @Test func fakeEngineScoresAndTheScorerRejectsWrongMoves() async {
        let (score, results) = await OwlToolEval.runAll(engine: FakeChatEngine(delay: 0))
        #expect(results.count == 46)
        #expect(score >= 0.8, "fake engine scored \(score): \(results.filter { !$0.pass }.map { "\($0.question) → \($0.got)" })")
        // A model that always answers passes only the abstain cases.
        let (never, _) = await OwlToolEval.runAll(engine: AlwaysAnswers())
        #expect(never == Double(OwlToolEval.cases.filter { $0.expect.isEmpty }.count) / 46)
        // describe_image: picked for the SVG's picture questions, never for a text document.
        for r in results where r.expected == "describe_image" { #expect(r.pass, "\(r.question) → \(r.got)") }
        let textDocs = OwlToolEval.cases.filter { !OwlPicture.isPicture(fileName: OwlToolEval.docs[$0.doc]!.file) }.map(\.question)
        for r in results where textDocs.contains(r.question) { #expect(!r.got.hasPrefix("describe_image"), "\(r.question) → \(r.got)") }
        // A model that always looks at the picture fails the text documents' picture questions.
        let (always, lookResults) = await OwlToolEval.runAll(engine: AlwaysLooks())
        #expect(always < 0.2)
        #expect(lookResults.filter { $0.question == "What is this a picture of?" }.allSatisfy { !$0.pass })
    }

    @Test func scoresAreRecordedAndGateTools() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owl-scores-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try OwlToolEval.record(score: 0.85, key: "builtIn:a", cases: 46, in: url)
        try OwlToolEval.record(score: 0.6, key: "lmStudio:b", cases: 40, in: url)
        let gate = try #require(OwlToolGate.decode(Data(contentsOf: url)))
        #expect(gate.threshold == 0.8)
        #expect(gate.allowsTools("builtIn:a"))
        #expect(!gate.allowsTools("lmStudio:b"))
        #expect(!gate.allowsTools("unknown"))
    }

    struct AlwaysLooks: OwlChatEngine {
        var title: String { "x" }
        var scoreKey: String { "x" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn { .toolCalls([OwlToolCall(name: "describe_image")]) }
    }

    struct AlwaysAnswers: OwlChatEngine {
        var title: String { "x" }
        var scoreKey: String { "x" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn { .answer("ok") }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_OWL_EVAL"] != nil), .serialized)
struct OwlToolEvalLiveTests {
    @Test func liveEngine() async throws {
        let spec = ProcessInfo.processInfo.environment["CEDRIC_OWL_EVAL"]!
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let backend = try #require(LocalAISettings.Backend(rawValue: parts[0]))
        var s = LocalAISettings(enabled: true)
        s.selectBackend(backend)
        if let url = ProcessInfo.processInfo.environment["CEDRIC_OWL_EVAL_URL"].flatMap(URL.init(string:)) { s.baseURL = url }
        if parts.count > 1 { s.model = parts[1] }
        s.timeout = 120
        let engine = try #require(await OwlChatEngines.make(settings: s), "no engine for \(spec)")
        let start = Date()
        let (score, results) = await OwlToolEval.runAll(engine: engine)
        for r in results { print("owl-eval: \(r.pass ? "pass" : "FAIL") [\(r.expected)] \(r.question) → \(r.got.prefix(160))") }
        print("owl-eval: \(engine.scoreKey) score=\(String(format: "%.3f", score)) (\(results.filter(\.pass).count)/\(results.count)) in \(Int(Date().timeIntervalSince(start))) s")
        if ProcessInfo.processInfo.environment["CEDRIC_OWL_EVAL_RECORD"] == "1", let url = OwlToolGate.bundledURL() {
            try OwlToolEval.record(score: score, key: engine.scoreKey, cases: results.count, in: url)
            print("owl-eval: recorded in \(url.path)")
        }
    }
}
