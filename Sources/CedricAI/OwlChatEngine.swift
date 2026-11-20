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
    /// The text goes to a server the user set up (LM Studio, Ollama,
    /// another Mac), not a model running in Cedric or macOS.
    var usesServer: Bool { get }
}

extension OwlChatEngine {
    public var usesServer: Bool { false }
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
    /// The offline script scan's findings (`ScriptSafety.summary`), for
    /// "Check Script for Risks…".
    public var scan: String?
    /// The scan found a high-risk line, or read only part of the script:
    /// the verdict is forced to "Don't run it" (`ScriptVerdict`).
    public var scanHasHigh: Bool
    public var scanTruncated: Bool

    public init(question: String, action: OwlQuickAction? = nil, context: OwlChatContext, snapshot: OwlDocumentSnapshot,
                history: [OwlChatEntry] = [], useTools: Bool, prose: Bool, maxTokens: Int = 700, scan: String? = nil,
                scanHasHigh: Bool = false, scanTruncated: Bool = false) {
        self.question = question; self.action = action; self.context = context; self.snapshot = snapshot
        self.history = history; self.useTools = useTools; self.prose = prose; self.maxTokens = maxTokens
        self.scan = scan; self.scanHasHigh = scanHasHigh; self.scanTruncated = scanTruncated
    }

    /// The model saw only part of the document (trimmed to fit, or not
    /// from line 1 to the end).
    public var contextIsPartial: Bool {
        context.truncated || context.firstLine > 1 || context.lastLine < snapshot.lineCount
    }

    /// Why the script check's verdict is forced, if it is.
    public var forcedVerdict: ScriptVerdict.Reason? {
        guard action == .scriptSafety else { return nil }
        return ScriptVerdict.forcedReason(scanHasHigh: scanHasHigh, truncated: scanTruncated || contextIsPartial)
    }

    /// The question text sent: a quick action's fixed instruction, else the user's words.
    public var prompt: String {
        if let action { return OwlPrompts.quickInstruction(action, prose: prose, toolsOn: useTools, context: context, scan: scan) }
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
                                               toolsOn: !specs.isEmpty, model: model, server: engine.usesServer)
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
        var shown = stripThinking(answer)
        // The script check never says "safe" (`ScriptVerdict`), whatever the model wrote.
        if req.action == .scriptSafety { shown = ScriptVerdict.clamp(shown, forced: req.forcedVerdict) }
        return OwlChatOutcome(answer: shown, proposal: proposal, toolCalls: toolbox.callCount, rounds: rounds)
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
    public var usesServer: Bool { true }

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
    /// Same rules as every other request: the name must resolve to private
    /// addresses only (`checkLocal`), redirects stay on the host and port
    /// (`RedirectGuard`), and the streamed total is capped at
    /// `maxResponseBytes`.
    public func chatStream(model: String, messages: [Any], tools: [Any]?, maxTokens: Int, temperature: Double = 0,
                           onText: @escaping @Sendable (String) -> Void) async throws -> OpenAIStreamAccumulator {
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": maxTokens,
                                   "temperature": temperature, "stream": true]
        if let tools { body["tools"] = tools }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        // `timeout` covers the name check and the wait for the first byte
        // of the answer (a slow model reads a long prompt first); after
        // that, at most `streamIdleLimit` between bytes, and `streamCap`
        // over the whole answer. A long answer that keeps coming is fine.
        let watch = StreamWatch(firstByte: timeout, idle: streamIdleLimit, cap: streamCap)
        do {
            return try await withThrowingTaskGroup(of: OpenAIStreamAccumulator?.self) { group in
                group.addTask { [request] in
                    let pin = try await checkLocal()
                    return try await stream(pin.apply(request), watch: watch, onText: onText)
                }
                // Wakes at least every quarter of the idle limit, so a stall
                // soon after the first byte isn't left to the first-byte wait.
                let step = max(0.01, streamIdleLimit / 4)
                group.addTask {
                    while true {
                        let left = watch.remaining()
                        if left <= 0 { return nil }
                        try await Task.sleep(nanoseconds: UInt64(min(left, step) * 1_000_000_000) + 1_000_000)
                    }
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let value = first else { throw LocalAIError.timedOut }
                return value
            }
        } catch is CancellationError {
            throw LocalAIError.cancelled
        }
    }

    private func stream(_ request: URLRequest, watch: StreamWatch,
                        onText: @escaping @Sendable (String) -> Void) async throws -> OpenAIStreamAccumulator {
        var acc = OpenAIStreamAccumulator()
        do {
            let guardian = RedirectGuard()
            let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
            guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw LocalAIError.badResponse }
            guard (200..<300).contains(http.statusCode) else { bytes.task.cancel(); throw LocalAIError.http(http.statusCode) }
            if response.expectedContentLength > Int64(Self.maxResponseBytes) {
                bytes.task.cancel()
                throw LocalAIError.transport("response too large")
            }
            var plain = ""
            var total = 0
            // The watch is touched on every chunk that arrives: a byte read
            // after a gap of more than `touchGap` (a commpage clock read per
            // byte, no lock), so a slow dribble with no newline stays alive.
            var lastTouch: UInt64 = 0
            var pending: [UInt8] = []
            var done = false
            // One line (SSE `data:` or a plain JSON body); true at "[DONE]".
            func take(_ raw: [UInt8]) -> Bool {
                var line = String(decoding: raw, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                if let p = SSEParser.payload(line) {
                    let t = acc.add(p)
                    if !t.isEmpty { onText(t) }
                    return p == "[DONE]"
                } else if !line.isEmpty, !line.hasPrefix(":"), !line.hasPrefix("event:") {
                    plain += line + "\n"
                }
                return false
            }
            // Bytes, not `bytes.lines`: the cap counts everything received,
            // including one endless line that would never reach a newline.
            for try await b in bytes {
                total += 1
                // Not a lock per byte (a 2 MB answer adds up): bytes of one
                // chunk arrive together, a new chunk comes after a gap.
                let tick = mach_absolute_time()
                if tick &- lastTouch > StreamWatch.touchGapTicks { lastTouch = tick; watch.touch() }
                if total > Self.maxResponseBytes {
                    bytes.task.cancel()
                    throw LocalAIError.transport("response too large")
                }
                guard b == 0x0A else { pending.append(b); continue }
                try Task.checkCancellation()
                done = take(pending)
                pending.removeAll(keepingCapacity: true)
                if done { bytes.task.cancel(); break }
            }
            if !done, !pending.isEmpty { _ = take(pending) }
            if acc.content.isEmpty, acc.toolCalls.isEmpty, !plain.isEmpty {
                let t = acc.add(plain)
                if !t.isEmpty { onText(t) }
            }
            // The answer has streamed by now; a public peer still fails the
            // request, so nothing from it is kept or applied.
            try await guardian.checkPeers()
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

/// The clock on a streamed answer: `firstByte` seconds for the name
/// check and the first byte, then `idle` seconds after each byte, never
/// past `cap` from the start. Monotonic time.
final class StreamWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let start: TimeInterval
    private let firstByte: TimeInterval
    private let idle: TimeInterval
    private let cap: TimeInterval
    private var last: TimeInterval?
    private let now: @Sendable () -> TimeInterval

    init(firstByte: TimeInterval, idle: TimeInterval, cap: TimeInterval,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        start = now()
        self.firstByte = firstByte; self.idle = idle; self.cap = cap
    }

    /// Bytes this close together (10 ms) are one chunk: one touch.
    static let touchGapTicks: UInt64 = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return 10_000_000 * UInt64(tb.denom) / UInt64(max(1, tb.numer))
    }()

    /// Data arrived.
    func touch() {
        let t = now()
        lock.withLock { last = t }
    }

    /// Seconds until the stream is given up (≤ 0: now).
    func remaining() -> TimeInterval {
        let t = now()
        let deadline = lock.withLock { last.map { $0 + idle } ?? start + firstByte }
        return min(deadline, start + cap) - t
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
            // A slow model may read a long prompt before its first token:
            // a longer wait for the first byte than a hint check gets.
            let client = LocalModelClient(baseURL: settings.baseURL, timeout: max(settings.timeout, 120), session: session)
            if let m = settings.model, !m.isEmpty { return ServerChatEngine(client: client, model: m, kind: settings.backend) }
            guard let models = try? await client.listModels(), let pick = ModelPicker.pickSmallQwen(models) else { return nil }
            return ServerChatEngine(client: client, model: pick.id, kind: settings.backend)
        }
    }
}

// MARK: - Which engine Ask Cedric uses

/// Ask Cedric is on by default only when a local engine is ready, and it
/// doesn't need the owl's background hints (`enabled`) to be on: a
/// question is something the user asked for.
public enum OwlChatSetup {
    /// The settings Ask Cedric runs on, nil when nothing is ready:
    ///
    /// - an LM Studio / Ollama / other-Mac server the user set up and
    ///   turned on (a server is never used while Cedric AI is off: the
    ///   text would leave this Mac);
    /// - else the saved engine, if it is Apple Intelligence (available
    ///   here) or the built-in engine with a model downloaded;
    /// - else Apple Intelligence, else the built-in engine (downloaded).
    public static func chatSettings(_ saved: LocalAISettings, appleAvailable: Bool,
                                    builtInInstalled: Bool) -> LocalAISettings? {
        var s = saved
        s.enabled = true
        switch saved.backend {
        case .lmStudio, .ollama, .custom:
            if saved.enabled, LocalEndpointPolicy.isAllowed(saved.baseURL) { return s }
        case .apple:
            if appleAvailable { return s }
        case .builtIn:
            if builtInInstalled { return s }
        }
        for (b, ready) in [(LocalAISettings.Backend.apple, appleAvailable), (.builtIn, builtInInstalled)] where ready {
            s = saved
            s.enabled = true
            s.selectBackend(b)
            return s
        }
        return nil
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
