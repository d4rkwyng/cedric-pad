import AppKit
import CedricCore
import CedricAI

/// App-wide owl state: the provider registry, the coordinator (dedupe,
/// snooze, throttle) and the one timer that asks for hints. Each tab has
/// its own `OwlController` for the views.
@MainActor
final class OwlHub {
    static let shared = OwlHub()

    let registry = OwlProviderRegistry()
    let coordinator: OwlCoordinator
    private var queryTimer: Timer?
    private weak var activeTab: EditorWindowController?
    private var querying = false
    private let env = ProcessInfo.processInfo.environment
    /// Called after a hint is shown (the in-process check).
    var onPresent: ((EditorWindowController, OwlHint) -> Void)?
    /// The local-AI provider (Cedric AI…), off by default.
    let ai: LocalAIOwlBridge
    /// Tabs whose context the AI scheduler should see, sent together on a
    /// short trailing timer so typing and scrolling never pay for it.
    private var aiPending: [UUID: WeakTab] = [:]
    private var aiFeedTimer: Timer?
    static let aiFeedDelay: TimeInterval = 0.3

    private init() {
        coordinator = OwlCoordinator(registry: registry)
        ai = LocalAIOwlBridge(registry: registry, makeProvider: AIStore.makeProvider)
        // Dev/test knobs, not saved.
        if let v = env["CEDRIC_OWL_INTERVAL"].flatMap(Double.init) { coordinator.queryInterval = v }
        if let v = env["CEDRIC_OWL_PAUSE"].flatMap(Double.init) { coordinator.typingPause = v }
        if env["CEDRIC_OWL_RESET"] == "1" { coordinator.resetNeverShown() }
        registry.register(RulesHintProvider())
        registry.onChange = { [weak self] in self?.applySource() }
        applySource()
        NotificationCenter.default.addObserver(forName: .cedricOwlSettingsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OwlHub.shared.settingsChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OwlHub.shared.schedule(); OwlHub.shared.appActiveChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OwlHub.shared.appActiveChanged() }
        }
        ai.onThinking = { [weak self] id, on in self?.tab(for: id)?.owl?.setThinking(on) }
        ai.onHints = { [weak self] ctx, hints in self?.presentAI(hints, context: ctx) }
        ai.onStateChange = { [weak self] in self?.applySource() }
        OwlView.statusProvider = { OwlHub.shared.ai.statusLine() }
        appActiveChanged()
        let saved = AIStore.load()
        if saved.enabled { Task { @MainActor in await self.ai.apply(saved) } }
    }

    // MARK: Local AI

    /// Saves new AI settings and applies them; turning the AI on also
    /// selects "Rules + AI".
    func applyAISettings(_ s: LocalAISettings) async {
        AIStore.save(s)
        await ai.apply(s)
        if ai.isActive, Settings.shared.owlHintSource != .rulesAndAI { Settings.shared.owlHintSource = .rulesAndAI }
    }

    func appActiveChanged() {
        ai.setAppActive(NSApp.isActive || OwlController.assumeVisible)
    }

    private func tab(for id: UUID) -> EditorWindowController? { tabs.first { $0.doc.id == id } }

    /// The editor scrolled: the AI sees the new visible text (same generation).
    func visibleChanged(in tab: EditorWindowController) { feedAI(tab) }

    func closed(_ tab: EditorWindowController) {
        aiPending[tab.doc.id] = nil
        ai.documentClosed(tab.doc.id)
    }

    private func feedAI(_ tab: EditorWindowController) {
        guard ai.isActive, !ai.isPaused, enabled, tab.owl != nil else { return }
        aiPending[tab.doc.id] = WeakTab(tab: tab)
        guard aiFeedTimer?.isValid != true else { return }
        let t = Timer(timeInterval: Self.aiFeedDelay, repeats: false) { _ in
            MainActor.assumeIsolated { OwlHub.shared.flushAIFeed() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        aiFeedTimer = t
    }

    private func flushAIFeed() {
        aiFeedTimer = nil
        let pending = aiPending.values.compactMap(\.tab)
        aiPending = [:]
        for tab in pending where tab.owl != nil { ai.contextChanged(tab.owlContextWindow().context) }
    }

    /// Hints from the AI scheduler: same dedupe/snooze/range checks as the
    /// rules, then the same bubble. Dropped while a bubble or the popover
    /// is up, or when the source isn't "Rules + AI".
    private func presentAI(_ hints: [OwlHint], context: OwlContext) {
        guard enabled, let tab = tab(for: context.documentID), let owl = tab.owl,
              owl.bubble == nil, !owl.popoverShown else { return }
        let length = tab.textView.textStorage?.length ?? -1
        guard let hint = coordinator.acceptAI(hints, context: context, length: length, generation: tab.doc.changeCount) else { return }
        owl.present(hint, context: context)
        onPresent?(tab, hint)
    }

    var enabled: Bool { Settings.shared.showOwl }

    /// "Rules + AI" only counts once an AI provider has registered.
    private func applySource() {
        coordinator.source = registry.hasAIProvider ? Settings.shared.owlHintSource : .rules
        ai.setPaused(!(enabled && coordinator.source == .rulesAndAI))
    }

    private var tabs: [EditorWindowController] { (NSApp.delegate as? AppDelegate)?.tabs ?? [] }

    private func settingsChanged() {
        applySource()
        for t in tabs { t.setOwlVisible(enabled) }
        if !enabled { queryTimer?.invalidate(); queryTimer = nil }
    }

    // MARK: Asking

    /// An edit, an open, a save or a file change in `tab`.
    func activity(in tab: EditorWindowController) {
        guard enabled else { return }
        activeTab = tab
        coordinator.noteActivity()
        schedule()
        feedAI(tab)
    }

    func endQuiet() {
        coordinator.endQuiet()
        queryTimer?.invalidate()
        queryTimer = nil
        schedule()
    }

    /// One timer at the coordinator's due date. Typing doesn't move it: when
    /// it fires early it sets itself again for the new due date.
    func schedule() {
        guard enabled, !querying, queryTimer?.isValid != true, let due = coordinator.nextDueDate else { return }
        let t = Timer(fire: max(due, Date().addingTimeInterval(0.05)), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { OwlHub.shared.fire() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        queryTimer = t
    }

    private func fire() {
        queryTimer = nil
        guard enabled, let tab = activeTab, let owl = tab.owl, owl.canAnimate else { return } // resumes on activation
        guard coordinator.isDue else { schedule(); return }
        guard owl.bubble == nil, !owl.popoverShown else { return } // one bubble at a time; the next edit asks again
        let window = tab.owlContextWindow()
        let facts = tab.owlFacts(wholeDocument: window.isWholeDocument)
        // Fast: the AI's registry entry answers nothing here; the AI
        // scheduler asks the model on its own and shows "thinking" then.
        querying = true
        Task { @MainActor in
            let hint = await coordinator.queryIfDue(window, facts: facts) { [weak tab] in
                (tab?.textView.textStorage?.length ?? -1, tab?.doc.changeCount ?? -1)
            }
            querying = false
            if let hint, tab.owl === owl, owl.bubble == nil {
                owl.present(hint, context: window.context)
                onPresent?(tab, hint)
            }
            schedule()
        }
    }
}

struct WeakTab { weak var tab: EditorWindowController? }
