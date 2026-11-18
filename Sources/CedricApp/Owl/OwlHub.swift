import AppKit
import CedricCore

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

    private init() {
        coordinator = OwlCoordinator(registry: registry)
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
            MainActor.assumeIsolated { OwlHub.shared.schedule() }
        }
    }

    var enabled: Bool { Settings.shared.showOwl }

    /// "Rules + AI" only counts once an AI provider has registered.
    private func applySource() {
        coordinator.source = registry.hasAIProvider ? Settings.shared.owlHintSource : .rules
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
        let slow = coordinator.source == .rulesAndAI
        if slow { owl.setThinking(true) }
        querying = true
        Task { @MainActor in
            let hint = await coordinator.queryIfDue(window, facts: facts) { [weak tab] in
                (tab?.textView.textStorage?.length ?? -1, tab?.doc.changeCount ?? -1)
            }
            querying = false
            if slow { owl.setThinking(false) }
            if let hint, tab.owl === owl {
                owl.present(hint, window: window)
                onPresent?(tab, hint)
            }
            schedule()
        }
    }
}
