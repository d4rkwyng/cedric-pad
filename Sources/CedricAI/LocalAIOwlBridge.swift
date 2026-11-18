import Foundation
import CedricCore

/// What the AI registers in the owl's provider registry. The registry
/// entry only tells the owl an AI source exists ("Rules + AI" becomes
/// available); it answers the coordinator's own queries with nothing, so
/// the model is asked only when `OwlScheduler` decides, never on the
/// coordinator's 30-second rules cadence.
public struct ScheduledAIEntry: OwlHintProvider {
    public let name: String
    public init(name: String) { self.name = name }
    public func hints(for context: OwlContext) async -> [OwlHint] { [] }
}

/// Wires the local-AI provider into the owl: applies `LocalAISettings`
/// (register / unregister in the registry), owns the scheduler, takes the
/// editor's context changes and the app's active state, and reports
/// "thinking" and the hints that arrive. The app supplies the callbacks;
/// everything here runs on the main actor and never waits on the network
/// (the scheduler is an actor; requests run in its tasks).
@MainActor
public final class LocalAIOwlBridge {
    public typealias ProviderFactory = @MainActor (LocalAISettings) async -> (any OwlHintProvider)?

    public let registry: OwlProviderRegistry
    public private(set) var settings: LocalAISettings = .default
    /// The registered provider's name ("local:<model>"), nil while off.
    public private(set) var providerName: String?
    public private(set) var scheduler: OwlScheduler?
    /// Documents with a request in flight.
    public private(set) var thinking: Set<UUID> = []
    /// Why the last `apply` left the AI off (nil: on, or simply disabled).
    public private(set) var lastProblem: String?
    /// The active engine's name ("Apple Intelligence", "Built-in"), nil while off.
    public private(set) var engineTitle: String?
    /// The last finished check, for the owl's "Last checked … ago" line.
    public private(set) var lastCheck: (date: Date, outcome: OwlScheduler.Outcome)?
    /// After each finished check (delivered, timed out, cancelled, stale).
    public var onCheck: (() -> Void)?

    /// A request started (true) or ended, timed out or was cancelled (false).
    public var onThinking: ((UUID, Bool) -> Void)?
    /// Hints for a context; ranges are relative to `context.text`.
    public var onHints: ((OwlContext, [OwlHint]) -> Void)?
    /// After `apply` registered or unregistered the provider.
    public var onStateChange: (() -> Void)?

    private let makeProvider: ProviderFactory
    private let clock: any OwlClock
    private let power: any PowerSource
    private var applyToken = 0
    private var appActive = true
    private var paused = false

    public init(registry: OwlProviderRegistry,
                clock: any OwlClock = SystemClock(), power: any PowerSource = SystemPowerSource(),
                makeProvider: @escaping ProviderFactory = { await LocalAIOwl.makeProvider(settings: $0) }) {
        self.registry = registry
        self.clock = clock
        self.power = power
        self.makeProvider = makeProvider
    }

    public var isActive: Bool { scheduler != nil }

    /// Applies new settings: tears down the old provider and, when enabled
    /// with a local endpoint and a model (configured or auto-picked),
    /// registers the new one. A later `apply` wins over an earlier one
    /// still waiting on model discovery.
    public func apply(_ new: LocalAISettings) async {
        applyToken += 1
        let token = applyToken
        settings = new
        teardown()
        lastProblem = nil
        guard new.enabled else { onStateChange?(); return }
        let engine = AIEngines.engine(for: new)
        guard engine.isAvailable else {
            lastProblem = engine.unavailableReason ?? "That engine isn’t available on this Mac."
            onStateChange?(); return
        }
        guard !new.backend.usesServer || LocalEndpointPolicy.isAllowed(new.baseURL) else {
            lastProblem = "The address isn’t on this Mac or the local network."
            onStateChange?(); return
        }
        let provider = await makeProvider(new)
        guard token == applyToken else { return }
        guard let provider else {
            lastProblem = new.backend == .builtIn
                ? "No model downloaded yet: download one in Cedric AI settings."
                : "No model: pick one, or start the server and test the connection."
            onStateChange?(); return
        }
        let sched = OwlScheduler(
            provider: provider,
            config: .init(pauseDelay: new.pauseDelay, minInterval: new.minInterval, timeout: new.timeout),
            clock: clock, power: power,
            onOutcome: { [weak self] id, outcome in
                Task { @MainActor in
                    self?.setThinking(id, false, token: token)
                    self?.recordCheck(outcome, token: token)
                }
            },
            onStart: { [weak self] ctx in
                Task { @MainActor in self?.setThinking(ctx.documentID, true, token: token) }
            },
            deliver: { [weak self] ctx, hints in
                await MainActor.run {
                    guard let self, token == self.applyToken, !self.paused else { return }
                    self.onHints?(ctx, hints)
                }
            })
        scheduler = sched
        providerName = provider.name
        engineTitle = Self.shortTitle(new.backend)
        registry.register(ScheduledAIEntry(name: provider.name), isAI: true)
        let active = appActive && !paused
        if !active { Task { await sched.setAppActive(false) } }
        onStateChange?()
    }

    private func recordCheck(_ outcome: OwlScheduler.Outcome, token: Int) {
        guard token == applyToken, scheduler != nil, outcome != .cancelled else { return }
        lastCheck = (Date(), outcome)
        onCheck?()
    }

    /// One line for the owl's tooltip and popover, e.g. "Last checked 12 s
    /// ago · Apple Intelligence · no suggestions"; nil while the AI is off.
    public func statusLine(now: Date = Date()) -> String? {
        guard let engine = engineTitle, scheduler != nil else { return nil }
        if paused { return "\(engine) · paused" }
        guard let last = lastCheck else { return "\(engine) · waiting for a pause in typing" }
        return Self.statusLine(engine: engine, outcome: last.outcome, age: now.timeIntervalSince(last.date))
    }

    nonisolated public static func statusLine(engine: String, outcome: OwlScheduler.Outcome, age: TimeInterval) -> String {
        let s = max(0, Int(age))
        let ago = s < 60 ? "\(s) s" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h"
        let result: String
        switch outcome {
        case .delivered(let n): result = n == 0 ? "no suggestions" : n == 1 ? "1 suggestion" : "\(n) suggestions"
        case .timedOut: result = "timed out"
        case .cancelled, .stale: result = "interrupted by an edit"
        }
        return "Last checked \(ago) ago · \(engine) · \(result)"
    }

    private func teardown() {
        lastCheck = nil
        engineTitle = nil
        if let s = scheduler { Task { await s.shutdown() } }
        scheduler = nil
        if let name = providerName { registry.unregister(name: name) }
        providerName = nil
        for id in thinking { onThinking?(id, false) }
        thinking = []
    }

    /// The engine's name without the picker's parenthetical.
    static func shortTitle(_ b: LocalAISettings.Backend) -> String {
        switch b {
        case .builtIn: return "Built-in"
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        case .custom: return "another Mac"
        case .apple: return "Apple Intelligence"
        }
    }

    private func setThinking(_ id: UUID, _ on: Bool, token: Int) {
        guard token == applyToken, scheduler != nil else { return }
        if on { guard thinking.insert(id).inserted else { return } } else { guard thinking.remove(id) != nil else { return } }
        onThinking?(id, on)
    }

    // MARK: Inputs from the editor and the app

    /// An edit (new generation) or a scroll (new visible text). No-op while off or paused.
    public func contextChanged(_ context: OwlContext) {
        guard let s = scheduler, !paused else { return }
        Task { await s.contextChanged(context) }
    }

    public func setAppActive(_ active: Bool) {
        appActive = active
        push()
    }

    /// The hint source went back to Rules, or the owl was hidden: stop
    /// asking (cancels anything in flight) until resumed.
    public func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        push()
    }

    public var isPaused: Bool { paused }

    public func documentClosed(_ id: UUID) {
        guard let s = scheduler else { return }
        Task { await s.documentClosed(id) }
    }

    private func push() {
        guard let s = scheduler else { return }
        let a = appActive && !paused
        Task { await s.setAppActive(a) }
    }
}
