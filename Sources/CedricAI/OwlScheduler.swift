import Foundation
import CedricCore

/// "Only checks so often." Decides when a provider is asked, per document:
///
/// - only after typing pauses for `pauseDelay` (5 s);
/// - at most once per `minInterval` (90 s) per document;
/// - never while the app is inactive, in Low Power Mode, or on battery
///   below `minimumBattery` (20 %);
/// - never twice for the same `editGeneration`;
/// - each request is hard-capped at `timeout` (20 s) and cancelled as soon
///   as the document is edited again.
///
/// Results for a generation that is no longer current are dropped.
public actor OwlScheduler {
    public struct Config: Sendable, Equatable {
        public var pauseDelay: TimeInterval
        public var minInterval: TimeInterval
        public var timeout: TimeInterval
        public var minimumBattery: Int

        public init(pauseDelay: TimeInterval = 5, minInterval: TimeInterval = 90,
                    timeout: TimeInterval = 20, minimumBattery: Int = 20) {
            self.pauseDelay = pauseDelay
            self.minInterval = minInterval
            self.timeout = timeout
            self.minimumBattery = minimumBattery
        }
    }

    public enum Gate: Sendable, Equatable {
        case fire
        case typing(remaining: TimeInterval)
        case throttled(remaining: TimeInterval)
        case inactive
        case power
        case alreadyAsked
        case busy
        case unknownDocument
    }

    public enum Outcome: Sendable, Equatable {
        case delivered(count: Int)
        case timedOut
        case cancelled
        case stale
    }

    struct Doc {
        var context: OwlContext
        var lastEdit: TimeInterval
        var lastFire: TimeInterval?
        var askedGeneration: Int?
        var timer: Task<Void, Never>?
        var inflight: Task<Void, Never>?
    }

    let provider: any OwlHintProvider
    public private(set) var config: Config
    let clock: any OwlClock
    let power: any PowerSource
    let deliver: @Sendable (OwlContext, [OwlHint]) async -> Void
    let onOutcome: (@Sendable (UUID, Outcome) -> Void)?
    /// Called when a request starts (the owl's "thinking" pose); every
    /// start is followed by exactly one `onOutcome`.
    let onStart: (@Sendable (OwlContext) -> Void)?

    var docs: [UUID: Doc] = [:]
    public private(set) var appActive = true
    /// How many requests were started, for tests and the budget log.
    public private(set) var requestCount = 0

    public init(provider: any OwlHintProvider, config: Config = Config(),
                clock: any OwlClock = SystemClock(), power: any PowerSource = SystemPowerSource(),
                onOutcome: (@Sendable (UUID, Outcome) -> Void)? = nil,
                onStart: (@Sendable (OwlContext) -> Void)? = nil,
                deliver: @escaping @Sendable (OwlContext, [OwlHint]) async -> Void) {
        self.provider = provider
        self.config = config
        self.clock = clock
        self.power = power
        self.onOutcome = onOutcome
        self.onStart = onStart
        self.deliver = deliver
    }

    // MARK: Inputs from the app

    /// Call on every edit (new generation) and on scroll (same generation,
    /// new visible text). An edit cancels the document's in-flight request
    /// and restarts the pause timer; a scroll only refreshes the context.
    public func contextChanged(_ context: OwlContext) {
        let now = clock.now
        let id = context.documentID
        if var doc = docs[id] {
            let isEdit = context.editGeneration != doc.context.editGeneration
            doc.context = context
            if isEdit {
                doc.lastEdit = now
                doc.inflight?.cancel()
                doc.inflight = nil
            }
            docs[id] = doc
            if isEdit || doc.timer == nil { arm(id, after: isEdit ? config.pauseDelay : remainingWait(doc, now)) }
        } else {
            docs[id] = Doc(context: context, lastEdit: now)
            arm(id, after: config.pauseDelay)
        }
    }

    /// From NSApplication didBecomeActive / didResignActive. Going inactive
    /// cancels everything in flight; coming back re-arms the timers.
    public func setAppActive(_ active: Bool) {
        appActive = active
        for id in docs.keys {
            if active {
                if docs[id]?.askedGeneration != docs[id]?.context.editGeneration {
                    arm(id, after: config.pauseDelay)
                }
            } else {
                docs[id]?.timer?.cancel(); docs[id]?.timer = nil
                if let task = docs[id]?.inflight {
                    // Interrupted before an answer: that generation may be asked again.
                    task.cancel()
                    docs[id]?.inflight = nil
                    docs[id]?.askedGeneration = nil
                }
            }
        }
    }

    public func documentClosed(_ id: UUID) {
        docs[id]?.timer?.cancel()
        docs[id]?.inflight?.cancel()
        docs[id] = nil
    }

    public func updateConfig(_ config: Config) { self.config = config }

    /// The provider is going away (AI switched off, settings changed):
    /// cancel every timer and request and forget the documents.
    public func shutdown() {
        for id in Array(docs.keys) { documentClosed(id) }
    }

    // MARK: Decisions

    /// The gate for `id` right now. Pure apart from reading the clock and
    /// the power source, so tests drive it with fakes.
    public func gate(for id: UUID) -> Gate {
        guard let doc = docs[id] else { return .unknownDocument }
        let now = clock.now
        if !appActive { return .inactive }
        if doc.askedGeneration == doc.context.editGeneration { return .alreadyAsked }
        if doc.inflight != nil { return .busy }
        let sinceEdit = now - doc.lastEdit
        if sinceEdit < config.pauseDelay { return .typing(remaining: config.pauseDelay - sinceEdit) }
        if let last = doc.lastFire, now - last < config.minInterval {
            return .throttled(remaining: config.minInterval - (now - last))
        }
        if !power.current().allowsChecks(minimumBattery: config.minimumBattery) { return .power }
        return .fire
    }

    private func remainingWait(_ doc: Doc, _ now: TimeInterval) -> TimeInterval {
        var wait = max(0, config.pauseDelay - (now - doc.lastEdit))
        if let last = doc.lastFire { wait = max(wait, config.minInterval - (now - last)) }
        return wait
    }

    private func arm(_ id: UUID, after delay: TimeInterval) {
        docs[id]?.timer?.cancel()
        let clock = self.clock
        docs[id]?.timer = Task { [weak self] in
            do { try await clock.sleep(seconds: delay) } catch { return }
            await self?.timerFired(id)
        }
    }

    /// Evaluate the gate and act on it. The timer calls this; tests may too.
    @discardableResult
    public func timerFired(_ id: UUID) -> Gate {
        docs[id]?.timer = nil
        let g = gate(for: id)
        switch g {
        case .fire: start(id)
        case .typing(let r), .throttled(let r): arm(id, after: r)
        case .power: arm(id, after: config.minInterval)   // re-check the battery later
        case .inactive, .alreadyAsked, .busy, .unknownDocument: break
        }
        return g
    }

    private func start(_ id: UUID) {
        guard var doc = docs[id] else { return }
        let context = doc.context
        doc.lastFire = clock.now
        doc.askedGeneration = context.editGeneration
        requestCount += 1
        onStart?(context)
        let provider = self.provider, clock = self.clock, timeout = config.timeout
        doc.inflight = Task { [weak self] in
            let result = await Self.race(provider: provider, context: context, clock: clock, timeout: timeout)
            await self?.finish(context, result)
        }
        docs[id] = doc
    }

    /// nil = timed out or cancelled.
    static func race(provider: any OwlHintProvider, context: OwlContext,
                     clock: any OwlClock, timeout: TimeInterval) async -> [OwlHint]? {
        await withTaskGroup(of: [OwlHint]?.self) { group in
            group.addTask { await provider.hints(for: context) }
            group.addTask {
                try? await clock.sleep(seconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func finish(_ context: OwlContext, _ result: [OwlHint]?) async {
        let id = context.documentID
        guard var doc = docs[id] else { onOutcome?(id, .cancelled); return }   // closed meanwhile
        let current = doc.context.editGeneration == context.editGeneration
        if current { doc.inflight = nil; docs[id] = doc }
        let outcome: Outcome
        if Task.isCancelled || (!current && result == nil) {
            outcome = .cancelled
        } else if !current {
            outcome = .stale
        } else if let hints = result {
            outcome = .delivered(count: hints.count)
            await deliver(context, hints)
        } else {
            outcome = .timedOut
        }
        onOutcome?(id, outcome)
    }
}
