import Foundation
import CedricCore

// Ask Cedric: one conversation turn per engine, and the runner that loops
// over tool calls (at most `OwlTools.maxRounds`) until the model answers.
// Every engine streams its answer. Tools are adapted three ways: OpenAI
// `tools` for LM Studio / Ollama, a GBNF-constrained JSON envelope for the
// built-in llama.cpp engine, and FoundationModels' `Tool` protocol for
// Apple Intelligence (which runs its own tool loop).

/// The conversation as the runner keeps it; each engine renders it.
public enum OwlChatMessage: Sendable, Equatable {
    case system(String)
    case user(String)
    case assistant(String)
    case toolCalls([OwlToolCall])
    case toolResult(callID: String, name: String, content: String)
}

/// What one model turn produced.
public enum OwlTurn: Sendable, Equatable {
    case answer(String)
    case toolCalls([OwlToolCall])
}

/// What the panel hears while a question runs.
public enum OwlChatEvent: Sendable, Equatable {
    /// New answer text (a delta).
    case text(String)
    /// A tool ran: its name and a line for the transcript.
    case tool(OwlToolName?, String)
    case proposal(OwlEditProposal)
    case phase(OwlChatPhase)
}

public enum OwlChatPhase: String, Sendable { case thinking, searching, writing }

public protocol OwlChatEngine: Sendable {
    /// "Built-in · qwen2.5-coder-3b…", for the panel's footer.
    var title: String { get }
    /// Key in the tool-score file ("builtin:<id>", "lmstudio:<id>", "apple", "fake").
    var scoreKey: String { get }
    /// UTF-16 units of numbered document text that fit with the prompt.
    var contextBudget: Int { get }
    /// One turn. `tools` empty: the model must answer. `toolbox` is given
    /// only to engines that run tools themselves (Apple).
    func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
              onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn
}

/// Runs tool calls against the frozen snapshot: the allowed subset only,
/// a call budget, at most one proposal. Thread-safe (Apple calls tools
/// from its own tasks).
public final class OwlToolbox: @unchecked Sendable {
    public let snapshot: OwlDocumentSnapshot
    public let allowed: Set<OwlToolName>
    private let lock = NSLock()
    private var calls = 0
    private var _proposal: OwlEditProposal?
    private let onEvent: @Sendable (OwlChatEvent) -> Void
    public static let maxCalls = OwlTools.maxRounds * OwlTools.maxCallsPerRound

    public init(snapshot: OwlDocumentSnapshot, allowed: Set<OwlToolName>, onEvent: @escaping @Sendable (OwlChatEvent) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.allowed = allowed
        self.onEvent = onEvent
    }

    public var proposal: OwlEditProposal? { lock.withLock { _proposal } }
    public var callCount: Int { lock.withLock { calls } }
    /// Every call asked for, in order (the tool eval reads the first).
    public var log: [OwlToolCall] { lock.withLock { _log } }
    private var _log: [OwlToolCall] = []

    public func run(_ call: OwlToolCall) -> OwlToolResult {
        let n: Int = lock.withLock { calls += 1; _log.append(call); return calls }
        guard n <= Self.maxCalls else {
            return OwlToolResult(text: "error: tool limit reached; answer now with what you have", proposal: nil,
                                 summary: "tool limit reached", ok: false)
        }
        let name = OwlToolName(rawValue: call.name)
        if name == .searchDocument { onEvent(.phase(.searching)) }
        if name == .proposeEdit, proposal != nil {
            return OwlToolResult(text: "error: one edit per question; it is already proposed", proposal: nil, summary: "second edit refused", ok: false)
        }
        let r = OwlTools.run(call, on: snapshot, allowed: allowed)
        onEvent(.tool(name, r.ok ? r.summary : String(localized: "A tool call was refused: \(r.summary)")))
        if let p = r.proposal {
            lock.withLock { _proposal = p }
            onEvent(.proposal(p))
            onEvent(.phase(.writing))
        }
        return r
    }
}

/// A question for the runner.
public struct OwlChatRequest: Sendable {
    public var question: String
    public var action: OwlQuickAction?
    public var context: OwlChatContext
    public var snapshot: OwlDocumentSnapshot
    public var history: [OwlChatEntry]
    public var useTools: Bool
    public var prose: Bool
    public var maxTokens: Int

    public init(question: String, action: OwlQuickAction? = nil, context: OwlChatContext, snapshot: OwlDocumentSnapshot,
                history: [OwlChatEntry] = [], useTools: Bool, prose: Bool, maxTokens: Int = 700) {
        self.question = question; self.action = action; self.context = context; self.snapshot = snapshot
        self.history = history; self.useTools = useTools; self.prose = prose; self.maxTokens = maxTokens
    }

    /// The question text sent: a quick action's fixed instruction, else the user's words.
    public var prompt: String {
        if let action { return OwlPrompts.quickInstruction(action, prose: prose, toolsOn: useTools, context: context) }
        return question
    }

    public var tools: [OwlToolName] { useTools ? (action?.tools ?? OwlToolName.allCases) : [] }
}

public struct OwlChatOutcome: Sendable, Equatable {
    public var answer: String
    public var proposal: OwlEditProposal?
    public var toolCalls: Int
    public var rounds: Int
}

public enum OwlChatRunner {
    /// Asks `engine`, running tools until it answers (≤ `OwlTools.maxRounds`
    /// rounds; then it must answer without tools). A quick action that
    /// edits and got no `propose_edit` (no tools, or the model pasted the
    /// text instead) gets its proposal from the answer's ``` block.
    public static func run(_ req: OwlChatRequest, engine: any OwlChatEngine, model: String = "",
                           onEvent: @escaping @Sendable (OwlChatEvent) -> Void) async throws -> OwlChatOutcome {
        let specs = OwlTools.specs(req.tools)
        let toolbox = OwlToolbox(snapshot: req.snapshot, allowed: Set(req.tools), onEvent: onEvent)
        var messages = OwlPrompts.chatMessages(question: req.prompt, context: req.context,
                                               language: Language(rawValue: req.snapshot.language)?.displayName ?? req.snapshot.language,
                                               fileName: req.snapshot.fileName, history: req.history,
                                               toolsOn: !specs.isEmpty, model: model)
        onEvent(.phase(.thinking))
        let wrote = Flag()
        let onText: @Sendable (String) -> Void = { t in
            if !wrote.value { wrote.value = true; onEvent(.phase(.writing)) }
            onEvent(.text(t))
        }
        var rounds = 0
        var answer = ""
        while true {
            try Task.checkCancellation()
            let offer = rounds < OwlTools.maxRounds ? specs : []
            if offer.isEmpty, rounds > 0 { messages.append(.user("Answer now, without tools.")) }
            let turn = try await engine.turn(messages, tools: offer, toolbox: offer.isEmpty ? nil : toolbox,
                                             maxTokens: req.maxTokens, onText: onText)
            switch turn {
            case .answer(let a):
                answer = a
            case .toolCalls(let calls):
                guard !offer.isEmpty, !calls.isEmpty else { answer = ""; break }
                rounds += 1
                var calls = Array(calls.prefix(OwlTools.maxCallsPerRound))
                for i in calls.indices where calls[i].id.isEmpty { calls[i].id = "call_\(rounds)_\(i)" }
                messages.append(.toolCalls(calls))
                for c in calls {
                    let r = toolbox.run(c)
                    messages.append(.toolResult(callID: c.id, name: c.name, content: r.text))
                }
                continue
            }
            break
        }
        var proposal = toolbox.proposal
        if proposal == nil, req.action?.proposesEdit == true, let block = fencedBlock(answer) {
            proposal = OwlEditProposal.lines(req.context.firstLine, req.context.lastLine, with: stripLineNumbers(block),
                                             reason: "", in: req.snapshot)
            if let proposal { onEvent(.proposal(proposal)) }
        }
        return OwlChatOutcome(answer: stripThinking(answer), proposal: proposal, toolCalls: toolbox.callCount, rounds: rounds)
    }

    /// The first ``` block's body.
    public static func fencedBlock(_ text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        guard let nl = text[open.upperBound...].firstIndex(of: "\n") else { return nil }
        let body = text[text.index(after: nl)...]
        guard let close = body.range(of: "```") else { return nil }
        var s = String(body[..<close.lowerBound])
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    /// "12| text" lines → "text", only when every non-empty line has a number.
    public static func stripLineNumbers(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        let re = try! NSRegularExpression(pattern: #"^\s*\d+\| ?"#)
        let numbered = lines.allSatisfy { $0.isEmpty || re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        guard numbered, lines.contains(where: { !$0.isEmpty }) else { return s }
        return lines.map { re.stringByReplacingMatches(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length), withTemplate: "") }
            .joined(separator: "\n")
    }

    /// Qwen3's "<think>…</think>" scratchpad, if a model sent one anyway.
    public static func stripThinking(_ s: String) -> String {
        guard let r = s.range(of: "</think>") else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

// MARK: - LM Studio / Ollama / another Mac (OpenAI-compatible)

public struct ServerChatEngine: OwlChatEngine {
    public let client: LocalModelClient
    public let model: String
    public let kind: LocalAISettings.Backend

    public init(client: LocalModelClient, model: String, kind: LocalAISettings.Backend) {
        self.client = client; self.model = model; self.kind = kind
    }

    public var title: String { "\(LocalAIOwlBridge.shortTitle(kind)) · \(model)" }
    public var scoreKey: String { "\(kind.rawValue):\(model)" }
    /// Servers have their own (usually larger) context; keep requests modest.
    public var contextBudget: Int { 12_000 }

    public func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                     onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        let wire = Self.render(messages)
        let toolJSON: [Any]? = tools.isEmpty ? nil : tools.map(Self.toolJSON)
        let acc: OpenAIStreamAccumulator
        do {
            acc = try await client.chatStream(model: model, messages: wire, tools: toolJSON, maxTokens: maxTokens, onText: onText)
        } catch LocalAIError.http(400) where toolJSON != nil {
            // A server or model without tool support: ask without tools.
            acc = try await client.chatStream(model: model, messages: wire, tools: nil, maxTokens: maxTokens, onText: onText)
        }
        if !acc.toolCalls.isEmpty, !tools.isEmpty { return .toolCalls(acc.toolCalls) }
        // Small models sometimes write the call as text: accept our envelope.
        if !tools.isEmpty, case .toolCalls(let c)? = EnvelopeStreamParser.parse(acc.content),
           acc.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return .toolCalls(c) }
        return .answer(acc.content)
    }

    static func render(_ messages: [OwlChatMessage]) -> [Any] {
        messages.map { m -> Any in
            switch m {
            case .system(let s): return ["role": "system", "content": s]
            case .user(let s): return ["role": "user", "content": s]
            case .assistant(let s): return ["role": "assistant", "content": s]
            case .toolCalls(let calls):
                return ["role": "assistant", "content": "",
                        "tool_calls": calls.map { ["id": $0.id, "type": "function",
                                                   "function": ["name": $0.name, "arguments": $0.arguments.jsonString]] }]
            case .toolResult(let id, let name, let content):
                return ["role": "tool", "tool_call_id": id, "name": name, "content": content]
            }
        }
    }

    static func toolJSON(_ t: OwlToolSpec) -> Any {
        ["type": "function", "function": ["name": t.name.rawValue, "description": t.description, "parameters": t.parameters.any]]
    }
}

extension LocalModelClient {
    /// A streamed chat completion (`"stream": true`, Server-Sent Events),
    /// with OpenAI `tools` when given. `onText` gets each text delta. A
    /// server that ignores `stream` and returns one JSON body still works.
    public func chatStream(model: String, messages: [Any], tools: [Any]?, maxTokens: Int, temperature: Double = 0,
                           onText: @escaping @Sendable (String) -> Void) async throws -> OpenAIStreamAccumulator {
        guard LocalEndpointPolicy.isAllowed(baseURL) else { throw LocalAIError.endpointNotLocal(baseURL.host ?? baseURL.absoluteString) }
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": maxTokens,
                                   "temperature": temperature, "stream": true]
        if let tools { body["tools"] = tools }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        var acc = OpenAIStreamAccumulator()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LocalAIError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw LocalAIError.http(http.statusCode) }
            var plain = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let p = SSEParser.payload(line) {
                    let t = acc.add(p)
                    if !t.isEmpty { onText(t) }
                    if p == "[DONE]" { break }
                } else if !line.isEmpty, !line.hasPrefix(":"), !line.hasPrefix("event:") {
                    plain += line + "\n"
                }
            }
            if acc.content.isEmpty, acc.toolCalls.isEmpty, !plain.isEmpty {
                let t = acc.add(plain)
                if !t.isEmpty { onText(t) }
            }
            return acc
        } catch let e as LocalAIError {
            throw e
        } catch is CancellationError {
            throw LocalAIError.cancelled
        } catch let e as URLError {
            switch e.code {
            case .cancelled: throw LocalAIError.cancelled
            case .timedOut: throw LocalAIError.timedOut
            default: throw LocalAIError.transport(e.localizedDescription)
            }
        }
    }
}

// MARK: - Built-in (llama.cpp)

public struct BuiltInChatEngine: OwlChatEngine {
    public let model: BuiltInModel
    public let path: URL
    public let host: BuiltInModelHost

    public init(model: BuiltInModel, path: URL, host: BuiltInModelHost = .shared) {
        self.model = model; self.path = path; self.host = host
    }

    public var title: String { "Built-in · \(model.name)" }
    public var scoreKey: String { "builtIn:\(model.id)" }
    /// n_ctx 4096 tokens: ≈ 2000 tokens of document (≈ 6 KB).
    public var contextBudget: Int { 6_000 }

    public func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                     onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        let chat = Self.render(messages, tools: tools)
        if tools.isEmpty {
            let r = try await host.generate(modelAt: path, GenerationRequest(messages: chat, maxTokens: maxTokens), onText: onText)
            return .answer(r.text)
        }
        let grammar = EnvelopeStreamParser.grammar(tools: tools.map(\.name))
        let parser = Locked(EnvelopeStreamParser())
        let r = try await host.generate(modelAt: path, GenerationRequest(messages: chat, maxTokens: maxTokens, grammar: grammar)) { piece in
            let new = parser.mutate { $0.add(piece) }
            if !new.isEmpty { onText(new) }
        }
        return EnvelopeStreamParser.parse(r.text) ?? .answer(r.text)
    }

    /// The envelope protocol in plain chat messages.
    static func render(_ messages: [OwlChatMessage], tools: [OwlToolSpec]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for m in messages {
            switch m {
            case .system(let s): out.append(ChatMessage(role: "system", content: tools.isEmpty ? s : s + OwlPrompts.envelopeInstructions(tools)))
            case .user(let s): out.append(ChatMessage(role: "user", content: s))
            case .assistant(let s): out.append(ChatMessage(role: "assistant", content: tools.isEmpty ? s : OwlJSON.object(["answer": .string(s)]).jsonString))
            case .toolCalls(let calls):
                for c in calls {
                    out.append(ChatMessage(role: "assistant", content: OwlJSON.object(["tool": .string(c.name), "args": c.arguments]).jsonString))
                }
            case .toolResult(_, let name, let content):
                out.append(ChatMessage(role: "user", content: "Result of \(name):\n\(content)"))
            }
        }
        return out
    }
}

/// A value behind a lock, for streaming callbacks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func mutate<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

// MARK: - Choosing the engine

public enum OwlChatEngines {
    /// The chat engine for the AI settings (nil: off, unavailable, no model).
    public static func make(settings: LocalAISettings, session: URLSession? = nil) async -> (any OwlChatEngine)? {
        guard settings.enabled else { return nil }
        switch settings.backend {
        case .builtIn:
            let engine = BuiltInEngine()
            guard let catalog = engine.catalog else { return nil }
            let installed = engine.installedModels
            let chosen = settings.model.flatMap { id in installed.first { $0.id == id } }
                ?? engine.suggestedModel(in: installed.map(\.info)).flatMap { catalog.model(id: $0.id) }
            guard let chosen else { return nil }
            return BuiltInChatEngine(model: chosen, path: engine.store.fileURL(for: chosen), host: engine.host)
        case .apple:
            return AppleChatEngine.isAvailable ? AppleChatEngine() : nil
        case .lmStudio, .ollama, .custom:
            guard LocalEndpointPolicy.isAllowed(settings.baseURL) else { return nil }
            // Answers stream for a while: a longer timeout than a hint check.
            let client = LocalModelClient(baseURL: settings.baseURL, timeout: max(settings.timeout, 120), session: session)
            if let m = settings.model, !m.isEmpty { return ServerChatEngine(client: client, model: m, kind: settings.backend) }
            guard let models = try? await client.listModels(), let pick = ModelPicker.pickSmallQwen(models) else { return nil }
            return ServerChatEngine(client: client, model: pick.id, kind: settings.backend)
        }
    }
}

// MARK: - Model gating

/// Tools only for models that scored ≥ `threshold` on the fixed tool-prompt
/// set (Scripts/owl-tools-eval.sh writes Resources/AI/owl-tool-scores.json).
/// Unmeasured and weaker models get the quick actions without tools.
public struct OwlToolGate: Sendable {
    public var threshold: Double
    public var scores: [String: Double]

    public init(threshold: Double = 0.8, scores: [String: Double] = [:]) {
        self.threshold = threshold; self.scores = scores
    }

    public func allowsTools(_ key: String) -> Bool { (scores[key] ?? 0) >= threshold }

    public static func decode(_ data: Data) -> OwlToolGate? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var g = OwlToolGate()
        if let t = obj["threshold"] as? Double { g.threshold = t }
        for (k, v) in (obj["models"] as? [String: Any]) ?? [:] {
            if let d = v as? [String: Any], let s = d["score"] as? Double { g.scores[k] = s }
        }
        return g
    }

    public static func bundledURL(bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: "owl-tool-scores", withExtension: "json", subdirectory: "AI") { return url }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AI/owl-tool-scores.json")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    public static func bundled() -> OwlToolGate {
        bundledURL().flatMap { try? Data(contentsOf: $0) }.flatMap(decode) ?? OwlToolGate()
    }
}
