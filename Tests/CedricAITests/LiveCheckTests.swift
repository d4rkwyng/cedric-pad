import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// A real check against a running LM Studio / Ollama. Skipped unless
/// CEDRIC_AI_LIVE=1 (CI never sets it). CEDRIC_AI_URL overrides the endpoint.
/// Prints each snippet's hints and latency; asserts only that the provider
/// answered in time and that every hint is well-formed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_AI_LIVE"] == "1"))
struct LiveCheckTests {
    static let snippets: [(String, String, String)] = [
        ("swift", "Sum.swift", """
        func total(_ items: [Int]) -> Int {
            var sum = 0
            for i in 0...items.count {
                sum += items[i]
            }
            return sum
        }
        """),
        ("python", "cart.py", """
        def add_item(item, cart=[]):
            cart.append(item)
            return cart

        print(add_item("apple"))
        print(add_item("pear"))
        """),
        ("javascript", "check.js", """
        function isZero(value) {
          if (value == 0) {
            return true;
          }
          return false;
        }
        console.log(isZero(""), isZero("0"), isZero([]));
        """),
    ]

    @Test func liveHints() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = env["CEDRIC_AI_URL"].flatMap(URL.init(string:)) ?? URL(string: "http://localhost:1234/v1")!
        let client = LocalModelClient(baseURL: url)
        let report = await client.testConnection()
        print("LIVE test-connection latency=\(Int(report.latency * 1000))ms models=\(report.models.map { "\($0.id) [\($0.sizeLabel)]" })")
        let model = try #require(env["CEDRIC_AI_MODEL"] ?? report.suggested?.id, "no small model found")
        print("LIVE model=\(model)")
        let provider = LocalModelHintProvider(client: client, model: model)
        for (lang, file, code) in Self.snippets {
            let ctx = OwlContext(fileName: file, language: lang, text: code,
                                 visibleRange: NSRange(location: 0, length: (code as NSString).length),
                                 selection: nil, documentID: UUID(), editGeneration: 1)
            if env["CEDRIC_AI_RAW"] == "1" {   // sample snippets only, never user text
                let raw = try await client.chat(model: model, messages: HintPrompt.messages(for: ctx, text: code, model: model),
                                                maxTokens: provider.maxTokens, jsonSchema: HintPrompt.schema)
                print("LIVE   raw=\(raw.content.replacingOccurrences(of: "\n", with: " "))")
            }
            let start = Date()
            let hints = try await provider.requestHints(for: ctx)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("LIVE [\(file)] \(ms)ms hints=\(hints.count)")
            for h in hints {
                let anchored = h.range.map { (code as NSString).substring(with: $0) } ?? "-"
                print("LIVE   \(h.kind.rawValue): \(h.title) | detail=\(h.detail ?? "-") | at=\(anchored) | replacement=\(h.replacement ?? "-")")
                #expect(h.title.count <= 60)
                if let r = h.range { #expect(NSMaxRange(r) <= (code as NSString).length) }
            }
            #expect(ms < 20_000)
        }
    }

    /// The scheduler end to end with the real clock, power source and model:
    /// a burst of edits produces exactly one request, after the pause, for
    /// the last generation only.
    @Test func liveSchedulerBurst() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = env["CEDRIC_AI_URL"].flatMap(URL.init(string:)) ?? URL(string: "http://localhost:1234/v1")!
        let client = LocalModelClient(baseURL: url)
        let suggested = await client.testConnection().suggested?.id
        let model = try #require(env["CEDRIC_AI_MODEL"] ?? suggested)
        let provider = LocalModelHintProvider(client: client, model: model)
        let delivered = Box<[(Int, Int)]>([])
        let scheduler = OwlScheduler(provider: provider,
                                     config: .init(pauseDelay: 0.5, minInterval: 3, timeout: 20),
                                     deliver: { ctx, hints in delivered.mutate { $0.append((ctx.editGeneration, hints.count)) } })
        let doc = UUID()
        let (lang, file, code) = Self.snippets[0]
        let start = Date()
        for gen in 1...5 {
            await scheduler.contextChanged(OwlContext(fileName: file, language: lang, text: code,
                                                      visibleRange: NSRange(location: 0, length: 10),
                                                      selection: nil, documentID: doc, editGeneration: gen))
            try await Task.sleep(nanoseconds: 100_000_000)   // typing
        }
        for _ in 0..<200 where delivered.value.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("LIVE scheduler delivered=\(delivered.value) requests=\(await scheduler.requestCount) after \(ms)ms power=\(SystemPowerSource().current())")
        #expect(delivered.value.map(\.0) == [5])
        #expect(await scheduler.requestCount == 1)
    }
}
