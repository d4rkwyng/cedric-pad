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
        guard LocalEndpointPolicy.isAllowed(new.baseURL) else {
            lastProblem = "The address isn’t on this Mac or the local network."
            onStateChange?(); return
        }
        let provider = await makeProvider(new)
        guard token == applyToken else { return }
        guard let provider else {
            lastProblem = "No model: pick one, or start the server and test the connection."
            onStateChange?(); return
        }
        let sched = OwlScheduler(
            provider: provider,
            config: .init(pauseDelay: new.pauseDelay, minInterval: new.minInterval, timeout: new.timeout),
            clock: clock, power: power,
            onOutcome: { [weak self] id, _ in
                Task { @MainActor in self?.setThinking(id, false, token: token) }
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
        registry.register(ScheduledAIEntry(name: provider.name), isAI: true)
        let active = appActive && !paused
        if !active { Task { await sched.setAppActive(false) } }
        onStateChange?()
    }

    private func teardown() {
        if let s = scheduler { Task { await s.shutdown() } }
        scheduler = nil
        if let name = providerName { registry.unregister(name: name) }
        providerName = nil
        for id in thinking { onThinking?(id, false) }
        thinking = []
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
