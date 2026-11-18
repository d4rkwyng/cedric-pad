import Foundation
import Testing
@testable import CedricAI
import CedricCore

@Suite struct DiscoveryTests {
    @Test func parameterCountFromIDs() {
        #expect(ModelPicker.parameterCount(fromID: "qwen2.5-coder-1.5b-instruct") == 1.5)
        #expect(ModelPicker.parameterCount(fromID: "qwen/qwen3.6-35b-a3b") == 35)
        #expect(ModelPicker.parameterCount(fromID: "qwen3:1.7b") == 1.7)
        #expect(ModelPicker.parameterCount(fromID: "Qwen3-4B-MLX-4bit") == 4)
        #expect(ModelPicker.parameterCount(fromID: "qwen2.5-coder-1.5b-instruct-mlx") == 1.5)
        #expect(ModelPicker.parameterCount(fromID: "text-embedding-nomic-embed-text-v1.5") == nil)
    }

    @Test func discoveryPicksTheSmallCoderQwen() async throws {
        let server = StubServer()
        server.json("/v1/models", ["data": [
            ["id": "qwen/qwen3.6-35b-a3b"], ["id": "qwen/qwen3.8-27b"],
            ["id": "qwen2.5-coder-7b-instruct"], ["id": "qwen3-1.7b"],
            ["id": "qwen2.5-coder-1.5b-instruct"], ["id": "text-embedding-nomic-embed-text-v1.5"],
        ]])
        server.json("/api/v0/models", ["data": [
            ["id": "qwen2.5-coder-1.5b-instruct", "type": "llm", "quantization": "4bit", "state": "not-loaded"],
            ["id": "text-embedding-nomic-embed-text-v1.5", "type": "embeddings"],
        ]])
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        let report = await client.testConnection()
        #expect(report.error == nil)
        #expect(report.models.count == 6)
        #expect(report.suggested?.id == "qwen2.5-coder-1.5b-instruct")
        #expect(report.suggested?.sizeLabel == "1.5B · 4bit")
        #expect(report.latency >= 0)
    }

    @Test func prefersThreeToFourBThenOnePointFiveThenNothing() {
        let q3 = [LocalModelInfo(id: "qwen/qwen3.6-35b-a3b"), LocalModelInfo(id: "qwen3-4b"),
                  LocalModelInfo(id: "qwen3-1.7b"), LocalModelInfo(id: "qwen3-8b")]
        #expect(ModelPicker.pickSmallQwen(q3)?.id == "qwen3-4b")
        let mixed = [LocalModelInfo(id: "qwen3-4b"), LocalModelInfo(id: "qwen2.5-coder-3b-instruct"),
                     LocalModelInfo(id: "qwen2.5-coder-1.5b-instruct"), LocalModelInfo(id: "qwen2.5-coder-7b-instruct")]
        #expect(ModelPicker.pickSmallQwen(mixed)?.id == "qwen2.5-coder-3b-instruct")
        let small = [LocalModelInfo(id: "qwen2.5-coder-1.5b-instruct-mlx"), LocalModelInfo(id: "qwen2.5-coder-0.5b-instruct"),
                     LocalModelInfo(id: "qwen/qwen3.8-27b")]
        let pick = ModelPicker.pickSmallQwen(small)
        #expect(pick?.id == "qwen2.5-coder-1.5b-instruct-mlx")
        #expect(pick.map(ModelPicker.isWeak) == true)
        #expect(ModelPicker.isWeak(LocalModelInfo(id: "qwen3-4b")) == false)
        // Never a big one, whatever else is there.
        #expect(ModelPicker.pickSmallQwen([LocalModelInfo(id: "qwen2.5-coder-7b-instruct"),
                                           LocalModelInfo(id: "qwen2.5-coder-14b-instruct")]) == nil)
        let big = [LocalModelInfo(id: "qwen/qwen3.6-35b-a3b"), LocalModelInfo(id: "qwen/qwen3.8-27b"),
                   LocalModelInfo(id: "llama-3.2-1b")]
        #expect(ModelPicker.pickSmallQwen(big) == nil)
    }

    @Test func ollamaTagsGiveSizes() async throws {
        let server = StubServer()
        server.json("/v1/models", ["data": [["id": "qwen2.5-coder:1.5b"]]])
        server.json("/api/tags", ["models": [[
            "name": "qwen2.5-coder:1.5b", "model": "qwen2.5-coder:1.5b", "size": 986_000_000,
            "details": ["parameter_size": "1.5B", "quantization_level": "Q4_K_M"],
        ]]])
        let models = try await LocalModelClient(baseURL: server.baseURL, session: server.session).listModels()
        #expect(models.first?.sizeBytes == 986_000_000)
        #expect(models.first?.sizeLabel == "1.5B · Q4_K_M · 1.0 GB")
    }

    @Test func providerFactoryIsOffByDefaultAndLocalOnly() async {
        #expect(LocalAISettings().enabled == false)
        #expect(await LocalAIOwl.makeProvider(settings: LocalAISettings()) == nil)
        let cloud = LocalAISettings(enabled: true, backend: .custom, baseURL: URL(string: "https://api.openai.com/v1"), model: "x")
        #expect(await LocalAIOwl.makeProvider(settings: cloud) == nil)

        let server = StubServer()
        server.json("/v1/models", ["data": [["id": "qwen/qwen3.6-35b-a3b"], ["id": "qwen2.5-coder-1.5b-instruct"]]])
        let on = LocalAISettings(enabled: true, backend: .custom, baseURL: server.baseURL)
        let p = await LocalAIOwl.makeProvider(settings: on, session: server.session)
        #expect((p as? LocalModelHintProvider)?.model == "qwen2.5-coder-1.5b-instruct")
        #expect(p?.name == "local:qwen2.5-coder-1.5b-instruct")
    }

    @Test func endpointPolicy() {
        let ok = ["http://localhost:1234/v1", "http://127.0.0.1:11434/v1", "http://studio.local:1234/v1",
                  "http://192.168.2.50:1234/v1", "http://10.0.0.5/v1", "http://172.20.1.1/v1",
                  "http://100.64.0.1:1234/v1", "http://studio:1234/v1", "http://[::1]:1234/v1",
                  "http://mac.tail0000.ts.net:1234/v1"]
        let bad = ["https://api.openai.com/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1",
                   "http://example.com:1234/v1", "ftp://localhost/v1", "http://100.128.0.1/v1"]
        for s in ok { #expect(LocalEndpointPolicy.isAllowed(URL(string: s)!), "\(s)") }
        for s in bad { #expect(!LocalEndpointPolicy.isAllowed(URL(string: s)!), "\(s)") }
    }

    @Test func redirectsStayOnTheHost() {
        let base = URL(string: "http://studio.local:1234/v1/chat/completions")!
        #expect(LocalEndpointPolicy.allowsRedirect(from: base, to: URL(string: "http://studio.local:1234/v1/other")!))
        #expect(!LocalEndpointPolicy.allowsRedirect(from: base, to: URL(string: "https://evil.example.com/collect")!))
        #expect(!LocalEndpointPolicy.allowsRedirect(from: base, to: URL(string: "http://192.168.1.9:1234/v1")!), "another LAN host too")
        #expect(!LocalEndpointPolicy.allowsRedirect(from: base, to: URL(string: "http://studio.local:9999/v1")!), "another port")
    }

    @Test func privateAddresses() async {
        for a in ["127.0.0.1", "10.1.2.3", "192.168.0.1", "172.16.0.1", "172.31.255.255", "169.254.1.1", "100.64.0.1", "100.127.1.1",
                  "::1", "fd00::1", "fe80::1", "::ffff:192.168.1.1"] {
            #expect(LocalEndpointPolicy.isPrivateAddress(a), "\(a)")
        }
        for a in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "1.1.1.1", "2606:4700::1111", "::ffff:8.8.8.8", "not-an-ip"] {
            #expect(!LocalEndpointPolicy.isPrivateAddress(a), "\(a)")
        }
        #expect(await LocalEndpointPolicy.resolvesPrivately("localhost"))
        #expect(await LocalEndpointPolicy.resolvesPrivately("127.0.0.1"))
        #expect(await !LocalEndpointPolicy.resolvesPrivately("no-such-host.invalid"), "unresolvable: refused")
    }

    @Test func redirectToAnotherHostIsNotFollowed() async throws {
        let server = StubServer()
        server.json("/v1/models", ["data": [["id": "m"]]])
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        // The guard itself: a redirect elsewhere gets nil, same host goes on.
        let g = LocalModelClient.RedirectGuard()
        let task = server.session.dataTask(with: URLRequest(url: server.baseURL.appendingPathComponent("chat/completions")))
        let resp = HTTPURLResponse(url: server.baseURL, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let away = await g.urlSession(server.session, task: task, willPerformHTTPRedirection: resp,
                                      newRequest: URLRequest(url: URL(string: "https://evil.example.com/x")!))
        #expect(away == nil)
        let same = await g.urlSession(server.session, task: task, willPerformHTTPRedirection: resp,
                                      newRequest: URLRequest(url: server.baseURL.appendingPathComponent("models")))
        #expect(same != nil)
        task.cancel()
        _ = try await client.listModels()
    }

    @Test func responseSizeIsCapped() async {
        let server = StubServer()
        let big = String(repeating: "x", count: LocalModelClient.maxResponseBytes + 10)
        server.json("/v1/chat/completions", ["choices": [["message": ["content": big]]]])
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        await #expect(throws: LocalAIError.transport("response too large")) {
            _ = try await client.chat(model: "m", messages: [], maxTokens: 1)
        }
    }

    // Ask Cedric's streaming request goes through the same endpoint rules.

    @Test func chatStreamStreamsServerSentEvents() async throws {
        let server = StubServer()
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\r\n\r\n"
            + ": keep-alive\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: [DONE]\n"
        server.route("/v1/chat/completions") { _, _ in StubServer.Response(body: Data(sse.utf8)) }
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        let seen = Locked("")
        let acc = try await client.chatStream(model: "m", messages: [], tools: nil, maxTokens: 8) { t in seen.mutate { $0 += t } }
        #expect(acc.content == "Hello")
        #expect(seen.mutate { $0 } == "Hello")
    }

    @Test func chatStreamTotalIsCapped() async {
        let server = StubServer()
        // Many small events, no Content-Length: only the streamed total can catch it.
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"" + String(repeating: "x", count: 1000) + "\"}}]}\n\n"
        let body = Data(String(repeating: chunk, count: LocalModelClient.maxResponseBytes / chunk.utf8.count + 2).utf8)
        #expect(body.count > LocalModelClient.maxResponseBytes)
        server.route("/v1/chat/completions") { _, _ in StubServer.Response(body: body) }
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        await #expect(throws: LocalAIError.transport("response too large")) {
            _ = try await client.chatStream(model: "m", messages: [], tools: nil, maxTokens: 1) { _ in }
        }
    }

    @Test func chatStreamChecksTheNameResolvesPrivately() async {
        let server = StubServer()
        server.json("/v1/chat/completions", ["choices": [["message": ["content": "hi"]]]])
        // A bare name passes the name check but must still resolve to a
        // private address; this one doesn't resolve at all.
        let url = URL(string: "http://cedric-no-such-host-\(server.port):\(server.port)/v1")!
        #expect(LocalEndpointPolicy.isAllowed(url))
        let client = LocalModelClient(baseURL: url, session: server.session)
        await #expect(throws: LocalAIError.endpointNotLocal("cedric-no-such-host-\(server.port)")) {
            _ = try await client.chatStream(model: "m", messages: [], tools: nil, maxTokens: 1) { _ in }
        }
        #expect(server.recorded.isEmpty, "refused before any request")
    }

    @Test func settingsRoundTrip() throws {
        let (defaults, suite) = TestDefaults.make("cedric-ai-test-")
        defer { TestDefaults.remove(suite) }
        #expect(LocalAISettings.load(from: defaults, defaultBackend: .builtIn) == .default)
        var s = LocalAISettings(enabled: true, backend: .ollama, model: "qwen3:1.7b", minInterval: 120)
        s.save(to: defaults)
        #expect(LocalAISettings.load(from: defaults) == s)
        #expect(s.baseURL.absoluteString == "http://localhost:11434/v1")
        s.minInterval = 30
        #expect(s != LocalAISettings.load(from: defaults))
    }
}

@Suite struct RequestTests {
    @Test func sendsOnlyCappedContextLanguageAndFileName() async throws {
        let server = StubServer()
        server.json("/v1/chat/completions", chatCompletion(#"{"hints":[]}"#))
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        let provider = LocalModelHintProvider(client: client, model: "qwen2.5-coder-1.5b-instruct")
        let head = "// HEAD-MARKER\n"
        let big = head + String(repeating: "let value = compute(input) // é\n", count: 1_000) + "// TAIL-MARKER"
        #expect(big.utf8.count > 30_000)
        _ = try await provider.requestHints(for: context(big, file: "Big.swift"))

        let body = try #require(server.recorded.first { $0.path == "/v1/chat/completions" }?.body)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(obj["messages"] as? [[String: String]])
        let user = try #require(messages.last?["content"])
        #expect(user.contains("HEAD-MARKER"))
        #expect(!user.contains("TAIL-MARKER"))
        #expect(user.contains("Language: swift"))
        #expect(user.contains("File: Big.swift"))
        let code = try #require(user.components(separatedBy: "```\n").dropFirst().first)
        #expect(code.hasSuffix("\n```"))
        // The code itself (without the "12| " line numbers the prompt adds) is capped.
        let bare = code.replacingOccurrences(of: "(?m)^\\d+\\| ", with: "", options: .regularExpression)
        #expect(bare.utf8.count - 4 <= HintPrompt.maxContextBytes)
        #expect(obj["model"] as? String == "qwen2.5-coder-1.5b-instruct")
        #expect((obj["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func capIsUTF8SafeAndExact() {
        let s = String(repeating: "é", count: 5_000)       // 2 bytes each
        let c = HintPrompt.capped(s)
        #expect(c.utf8.count == 8 * 1024)
        #expect(HintPrompt.capped("short") == "short")
        let emoji = String(repeating: "🦉", count: 3_000)   // 4 bytes each
        #expect(HintPrompt.capped(emoji).utf8.count == 8 * 1024)
    }

    @Test func qwen3GetsNoThink() {
        let m = HintPrompt.messages(for: context(), text: "x", model: "qwen3-1.7b")
        #expect(m.last?.content.hasSuffix("/no_think") == true)
        let c = HintPrompt.messages(for: context(), text: "x", model: "qwen2.5-coder-1.5b-instruct")
        #expect(c.last?.content.contains("/no_think") == false)
    }

    @Test func retriesWithoutSchemaOn400() async throws {
        let server = StubServer()
        let count = Box(0)
        server.route("/v1/chat/completions") { _, body in
            count.mutate { $0 += 1 }
            let obj = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            if obj?["response_format"] != nil { return .init(status: 400, body: Data()) }
            return .init(body: try! JSONSerialization.data(withJSONObject: chatCompletion("ok")))
        }
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        let r = try await client.chat(model: "m", messages: [], maxTokens: 10, jsonSchema: HintPrompt.schema)
        #expect(r.content == "ok")
        #expect(count.value == 2)
        #expect(r.promptTokens == 100)
    }

    @Test func refusesNonLocalEndpointBeforeAnyRequest() async {
        let client = LocalModelClient(baseURL: URL(string: "https://api.example.com/v1")!)
        await #expect(throws: LocalAIError.endpointNotLocal("api.example.com")) {
            _ = try await client.chat(model: "m", messages: [], maxTokens: 1)
        }
    }

    @Test func clientTimesOut() async {
        let server = StubServer()
        server.json("/v1/chat/completions", chatCompletion("late"), delay: 5)
        let client = LocalModelClient(baseURL: server.baseURL, timeout: 0.3, session: server.session)
        let start = Date()
        do {
            _ = try await client.chat(model: "m", messages: [], maxTokens: 1)
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? LocalAIError == .timedOut)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func clientCancelsPromptly() async {
        let server = StubServer()
        server.json("/v1/chat/completions", chatCompletion("late"), delay: 5)
        let client = LocalModelClient(baseURL: server.baseURL, session: server.session)
        let task = Task { try await client.chat(model: "m", messages: [], maxTokens: 1) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(start) < 1)
        if case .failure(let e) = result { #expect(e as? LocalAIError == .cancelled) } else { Issue.record("not cancelled") }
    }
}

@Suite struct ParseTests {
    let code = """
    for i in 0...items.count {
        print(items[i])
    }
    """

    @Test func goodHintWithReplacement() throws {
        let raw = #"""
        {"hints":[{"kind":"fix","title":"Off-by-one: 0...count reads past the end","detail":"Use a half-open range.",
        "find":"0...items.count","replacement":"0..<items.count","confidence":0.9}]}
        """#
        let hints = HintPrompt.parse(raw, text: code, source: "local:m")
        let h = try #require(hints.first)
        #expect(hints.count == 1)
        #expect(h.kind == .fix)
        #expect(h.replacement == "0..<items.count")
        #expect(h.range == (code as NSString).range(of: "0...items.count"))
        #expect(h.source == "local:m")
        #expect(h.id == HintPrompt.parse(raw, text: "// moved\n" + code, source: "local:m").first?.id)
    }

    @Test func fencedThinkingAndBareArray() {
        let fenced = "<think>hmm</think>\n```json\n{\"hints\":[{\"kind\":\"warning\",\"title\":\"Index out of range\",\"detail\":\"d\",\"find\":\"items[i]\",\"replacement\":\"\",\"confidence\":0.8}]}\n```"
        let a = HintPrompt.parse(fenced, text: code, source: "s")
        #expect(a.count == 1)
        #expect(a.first?.replacement == nil)
        #expect(a.first?.range != nil)
        let bare = #"[{"kind":"explain","title":"Loop prints every item","detail":"d"}]"#
        #expect(HintPrompt.parse(bare, text: code, source: "s").count == 1)
    }

    @Test func malformedOutputGivesNothing() {
        for raw in ["", "I think the code is fine.", "{\"hints\": [", "{\"hints\": 3}", "{\"other\":[]}",
                    #"{"hints":[{"kind":"rant","title":"x"}]}"#, #"{"hints":[{"kind":"fix"}]}"#,
                    #"{"hints":[{"kind":"fix","title":"   "}]}"#] {
            #expect(HintPrompt.parse(raw, text: code, source: "s").isEmpty, "\(raw)")
        }
    }

    @Test func outOfContextReplacementIsDropped() {
        let raw = #"{"hints":[{"kind":"fix","title":"Fix the helper","detail":"d","find":"func helper()","replacement":"func helper() throws","confidence":0.9}]}"#
        #expect(HintPrompt.parse(raw, text: code, source: "s").isEmpty)
        // A replacement with no anchor loses the replacement, keeps the advice.
        let noFind = #"{"hints":[{"kind":"fix","title":"Use a half-open range","detail":"d","find":"","replacement":"0..<n","confidence":0.9}]}"#
        let h = HintPrompt.parse(noFind, text: code, source: "s")
        #expect(h.count == 1 && h[0].replacement == nil && h[0].range == nil)
    }

    @Test func unrelatedReplacementLosesApplyButKeepsAdvice() {
        let js = "if (value == 0) {\n  return true;\n}\nreturn false;"
        let wild = #"{"hints":[{"kind":"fix","title":"Use strict equality","detail":"d","find":"if (value == 0)","replacement":"return value === 0","confidence":0.9}]}"#
        let h = HintPrompt.parse(wild, text: js, source: "s")
        #expect(h.count == 1 && h[0].replacement == nil && h[0].range != nil)
        let good = #"{"hints":[{"kind":"fix","title":"Use strict equality","detail":"d","find":"if (value == 0)","replacement":"if (value === 0)","confidence":0.9}]}"#
        #expect(HintPrompt.parse(good, text: js, source: "s").first?.replacement == "if (value === 0)")
        let spacing = #"{"hints":[{"kind":"fix","title":"Spacing","detail":"d","find":"value == 0","replacement":"value==0","confidence":0.9}]}"#
        #expect(HintPrompt.parse(spacing, text: js, source: "s").first?.replacement == nil)
    }

    @Test func lowValueIsDropped() {
        let raw = #"""
        {"hints":[
          {"kind":"tip","title":"No issues found","detail":"Looks fine","find":"","replacement":"","confidence":0.9},
          {"kind":"fix","title":"Maybe wrong","detail":"d","find":"items[i]","replacement":"items[i]!","confidence":0.3},
          {"kind":"fix","title":"No-op","detail":"d","find":"items[i]","replacement":"items[i]","confidence":0.9}
        ]}
        """#
        let h = HintPrompt.parse(raw, text: code, source: "s")
        #expect(h.count == 1)
        #expect(h.first?.title == "No-op")
        #expect(h.first?.replacement == nil)
    }

    @Test func atMostTwoAndTitleCapped() {
        let long = String(repeating: "x", count: 100)
        let raw = "{\"hints\":[" + (1...4).map {
            "{\"kind\":\"warning\",\"title\":\"\($0) \(long)\",\"detail\":\"d\",\"find\":\"\",\"replacement\":\"\",\"confidence\":0.9}"
        }.joined(separator: ",") + "]}"
        let h = HintPrompt.parse(raw, text: code, source: "s")
        #expect(h.count == 2)
        #expect(h.allSatisfy { $0.title.count <= 60 })
    }

    @Test func providerReturnsEmptyOnServerError() async {
        let server = StubServer()
        server.json("/v1/chat/completions", ["error": "boom"], status: 500)
        let p = LocalModelHintProvider(client: LocalModelClient(baseURL: server.baseURL, session: server.session), model: "m")
        #expect(await p.hints(for: context(code)).isEmpty)
    }
}
