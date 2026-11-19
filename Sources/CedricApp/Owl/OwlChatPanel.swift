import AppKit
import CedricCore
import CedricAI

/// Ask Cedric: a small floating panel per window, opened from the owl's
/// popover or Edit › Ask Cedric… (⌥⌘/). Created on first use, so it costs
/// nothing at launch. Questions go to the AI engine chosen in Cedric AI
/// Settings (local or LAN only); answers stream in; an edit comes back as
/// a proposed diff with Apply / Discard, applied as one undo step only
/// while the document is unchanged since asking. History is per document,
/// in memory only.
@MainActor
final class OwlChatStore {
    static let shared = OwlChatStore()
    private(set) var histories: [UUID: [OwlChatEntry]] = [:]
    private var cached: (settings: LocalAISettings, engine: any OwlChatEngine)?
    let gate = OwlToolGate.bundled()

    func history(_ id: UUID) -> [OwlChatEntry] { histories[id] ?? [] }
    func append(_ e: OwlChatEntry, to id: UUID) { histories[id, default: []].append(e) }
    func replaceLast(_ e: OwlChatEntry, in id: UUID) {
        guard var h = histories[id], !h.isEmpty else { return }
        h[h.count - 1] = e
        histories[id] = h
    }
    func insertBeforeLast(_ e: OwlChatEntry, in id: UUID) {
        guard var h = histories[id], !h.isEmpty else { append(e, to: id); return }
        h.insert(e, at: h.count - 1)
        histories[id] = h
    }
    func clear(_ id: UUID) { histories[id] = nil }
    func closed(_ id: UUID) { histories[id] = nil }

    /// The engine for the saved AI settings (the fake under CEDRIC_AI_FAKE).
    func engine() async -> (any OwlChatEngine)? {
        if let d = AskCedricEngine.fakeDelay {
            let piece = ProcessInfo.processInfo.environment["CEDRIC_OWL_CHAT_FAKE_DELAY"].flatMap(Double.init) ?? min(0.08, max(0.01, d / 10))
            return FakeChatEngine(delay: piece)
        }
        guard let s = AskCedricEngine.settings() else { return nil }
        if let c = cached, c.settings == s { return c.engine }
        guard let e = await OwlChatEngines.make(settings: s) else { return nil }
        cached = (s, e)
        return e
    }

    /// Tools for this engine's model: it scored ≥ 80% on the tool set
    /// (CEDRIC_OWL_TOOLS=0/1 overrides for one run).
    func useTools(_ engine: any OwlChatEngine) -> Bool {
        if let v = ProcessInfo.processInfo.environment["CEDRIC_OWL_TOOLS"] { return v == "1" }
        return gate.allowsTools(engine.scoreKey)
    }
}

/// Is a local engine ready for Ask Cedric (`OwlChatSetup`)? Never on the
/// launch path: asked when a menu, the owl or a grammar pass needs it, and
/// kept for 30 s (a model download or an AI settings change resets it).
/// Debug builds only (the checks): CEDRIC_ASK_ENGINE=0/1 overrides it
/// for one run, and the fake engine (a numeric CEDRIC_AI_FAKE) counts as
/// ready. A release build ignores both, so nothing in the environment
/// can turn AI on past the user's opt-in.
@MainActor
enum AskCedricEngine {
    private static var cache: (at: Date, settings: LocalAISettings?)?

    /// The fake engine's delay (CEDRIC_AI_FAKE=0.3); always nil in a release build.
    static var fakeDelay: Double? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CEDRIC_AI_FAKE"].flatMap(Double.init)
        #else
        return nil
        #endif
    }

    static func settings() -> LocalAISettings? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CEDRIC_ASK_ENGINE"] == "0" { return nil }
        if fakeDelay != nil || env["CEDRIC_ASK_ENGINE"] == "1" {
            var s = AIStore.load()
            s.enabled = true
            return s
        }
        #endif
        if let c = cache, Date().timeIntervalSince(c.at) < 30 { return c.settings }
        let built = BuiltInEngine()
        let s = OwlChatSetup.chatSettings(AIStore.load(), appleAvailable: AppleChatEngine.isAvailable,
                                          builtInInstalled: !built.installedModels.isEmpty)
        cache = (Date(), s)
        return s
    }

    static var isAvailable: Bool { settings() != nil }

    /// Where Ask Cedric's text goes, for the wording that says so.
    static func privacy(autoGrammar: Bool) -> AIPrivacyWording {
        let engine: AIPrivacyWording.Engine
        if let s = settings() {
            engine = s.backend.usesServer && fakeDelay == nil ? .server(host: s.baseURL.host) : .local
        } else {
            engine = .none
        }
        return AIPrivacyWording(engine: engine, autoGrammar: autoGrammar)
    }

    static func invalidate() { cache = nil }
}

@MainActor
final class OwlChatPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private weak var tab: EditorWindowController?
    let panel: NSPanel
    let scopePopup = NSPopUpButton()
    let transcript = NSTextView()
    let input = NSTextField()
    private(set) var sendButton: NSButton!
    private(set) var stopButton: NSButton!
    private(set) var actionButtons: [OwlQuickAction: NSButton] = [:]
    let footer = NSTextField(labelWithString: "")
    // The diff card.
    let card = NSStackView()
    let cardTitle = NSTextField(labelWithString: "")
    let diffView = NSTextView()
    private(set) var applyButton: NSButton!
    private(set) var discardButton: NSButton!
    private(set) var askAgainButton: NSButton!
    let staleLabel = NSTextField(wrappingLabelWithString: String(localized: "The text changed since you asked, so this can’t be applied safely."))

    private var task: Task<Void, Never>?
    private(set) var running = false
    private(set) var pending: OwlEditProposal?
    private var lastRequest: (question: String, action: OwlQuickAction?)?
    /// Streamed text not yet shown (flushed at ~30 Hz).
    private var pendingText = ""
    private var flushTimer: Timer?
    private var streamed = ""
    private var scopes: [OwlChatScope] = []
    /// Requests asked (checks).
    private(set) var asks = 0
    private(set) var lastOutcome: OwlChatOutcome?
    /// The last request used tools (checks).
    private(set) var lastUsedTools = false
    var onFinish: ((OwlChatOutcome?) -> Void)?

    init(tab: EditorWindowController) {
        self.tab = tab
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.tabbingMode = .disallowed
        super.init()
        build()
    }

    var docID: UUID? { tab?.doc.id }

    // MARK: Building

    private func small(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.bezelStyle = .rounded
        return b
    }

    private func build() {
        panel.title = String(localized: "Ask Cedric")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 340, height: 320)
        panel.delegate = self

        let about = NSTextField(labelWithString: String(localized: "Asking about:"))
        about.font = .systemFont(ofSize: 11)
        about.textColor = .secondaryLabelColor
        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        let head = NSStackView(views: [about, scopePopup])
        head.spacing = 6

        // Two rows: what it does (and the script check), then the rest.
        let firstRow = NSStackView()
        let secondRow = NSStackView()
        for row in [firstRow, secondRow] { row.spacing = 4 }
        for a in OwlQuickAction.allCases {
            let b = small(a.title(prose: false), #selector(quickAction(_:)))
            b.tag = OwlQuickAction.allCases.firstIndex(of: a)!
            actionButtons[a] = b
            ([.explain, .explainLine, .scriptSafety].contains(a) ? firstRow : secondRow).addArrangedSubview(b)
        }
        let actions = NSStackView(views: [firstRow, secondRow])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 4

        transcript.isEditable = false
        transcript.isRichText = true
        transcript.font = .systemFont(ofSize: 12)
        transcript.textContainerInset = NSSize(width: 4, height: 6)
        transcript.drawsBackground = true
        transcript.backgroundColor = .textBackgroundColor
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityLabel(String(localized: "Conversation"))
        let tScroll = NSScrollView()
        tScroll.documentView = transcript
        tScroll.hasVerticalScroller = true
        tScroll.borderType = .bezelBorder
        tScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        tScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        // Diff card.
        cardTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        diffView.isEditable = false
        diffView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diffView.isVerticallyResizable = true
        diffView.autoresizingMask = [.width]
        diffView.textContainer?.widthTracksTextView = true
        let dScroll = NSScrollView()
        dScroll.documentView = diffView
        dScroll.hasVerticalScroller = true
        dScroll.borderType = .bezelBorder
        dScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        applyButton = small(String(localized: "Apply"), #selector(applyProposal(_:)))
        applyButton.keyEquivalent = ""
        discardButton = small(String(localized: "Discard"), #selector(discardProposal(_:)))
        askAgainButton = small(String(localized: "Ask Again"), #selector(askAgain(_:)))
        staleLabel.font = .systemFont(ofSize: 11)
        staleLabel.textColor = .systemOrange
        let cardButtons = NSStackView(views: [applyButton, discardButton, askAgainButton])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        for v in [cardTitle, dScroll, staleLabel, cardButtons] as [NSView] { card.addArrangedSubview(v) }
        dScroll.translatesAutoresizingMaskIntoConstraints = false
        dScroll.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        card.isHidden = true

        input.placeholderString = String(localized: "Ask about this text…")
        input.font = .systemFont(ofSize: 12)
        input.target = self
        input.action = #selector(send(_:))
        input.delegate = self
        sendButton = small(String(localized: "Ask"), #selector(send(_:)))
        stopButton = small(String(localized: "Stop"), #selector(stop(_:)))
        stopButton.isHidden = true
        let inputRow = NSStackView(views: [input, sendButton, stopButton])
        inputRow.spacing = 6
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = small(String(localized: "Copy as Markdown"), #selector(copyMarkdown(_:)))
        let clear = small(String(localized: "Clear"), #selector(clearHistory(_:)))
        let foot = NSStackView(views: [footer, NSView(), clear, copy])
        foot.spacing = 6

        let stack = NSStackView(views: [head, actions, tScroll, card, inputRow, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for v in [tScroll, card, inputRow, foot, actions] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 10).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -10).isActive = true
        }
        panel.contentView = stack
    }

    // MARK: Showing

    func show() {
        guard let tab, let w = tab.window else { return }
        if panel.parent == nil { w.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { position(in: w) }
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }

    /// Near the owl: the window's bottom-right corner, inside the screen.
    private func position(in w: NSWindow) {
        let size = panel.frame.size
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
        var o = NSPoint(x: w.frame.maxX - size.width - 24, y: w.frame.minY + 100)
        o.x = min(max(o.x, screen.minX + 4), screen.maxX - size.width - 4)
        o.y = min(max(o.y, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrameOrigin(o)
    }

    var isShown: Bool { panel.isVisible }

    func close() {
        stop(nil)
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stop(nil)
        panel.parent?.removeChildWindow(panel)
    }

    /// The scope chip, the action titles (prose or code), the footer and the transcript.
    func refresh() {
        guard let tab else { return }
        let s = snapshot()
        let budget = 6_000
        scopes = OwlChatContext.scopes(for: s, budget: budget)
        let current = scopes.first { $0.rawValue == scopePopup.selectedItem?.representedObject as? String }
        scopePopup.removeAllItems()
        for sc in scopes {
            let label = OwlChatContext.build(s, scope: sc, budget: budget)?.label ?? sc.title
            scopePopup.addItem(withTitle: label)
            scopePopup.lastItem?.representedObject = sc.rawValue
        }
        let pick = current ?? OwlChatContext.defaultScope(for: s)
        if let i = scopes.firstIndex(of: pick) { scopePopup.selectItem(at: i) }
        let prose = isProse
        let script = !prose && ScriptSafety.isScript(tab.doc.language)
        for (a, b) in actionButtons {
            b.title = a.title(prose: prose)
            b.isHidden = !a.isOffered(prose: prose, language: tab.doc.language)
        }
        if script { actionButtons[.explain]?.title = String(localized: "What Does It Do?") }
        if tab.textView.selectedRange().length > 0 { actionButtons[.explainLine]?.title = String(localized: "Explain Selection") }
        if AskCedricEngine.fakeDelay != nil {
            footer.stringValue = String(localized: "On this Mac · test engine")
        } else if let chat = AskCedricEngine.settings() {
            let place = chat.backend.usesServer ? (chat.baseURL.host ?? "this Mac") : String(localized: "this Mac")
            footer.stringValue = String(localized: "On \(place) · \(LocalAIOwlBridge.shortTitle(chat.backend))")
        } else {
            footer.stringValue = String(localized: "No AI engine yet: set one up in Cedric AI Settings.")
        }
        panel.title = String(localized: "Ask Cedric — \(tab.doc.displayName)")
        render()
        updateButtons()
    }

    private var isProse: Bool {
        guard let tab else { return false }
        if let p = tab.grammar.lastSawProse { return p }
        return tab.doc.language == .plain || tab.doc.language == .markdown
    }

    private func updateButtons() {
        sendButton.isHidden = running
        stopButton.isHidden = !running
        for b in actionButtons.values { b.isEnabled = !running }
        input.isEnabled = !running
    }

    var selectedScope: OwlChatScope {
        (scopePopup.selectedItem?.representedObject as? String).flatMap(OwlChatScope.init(rawValue:)) ?? .visible
    }

    func selectScope(_ s: OwlChatScope) {
        if let i = scopes.firstIndex(of: s) { scopePopup.selectItem(at: i) }
    }

    @objc private func scopeChanged(_ sender: Any?) {}

    // MARK: Transcript

    private func attributed(_ e: OwlChatEntry) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        switch e.role {
        case .user:
            out.append(NSAttributedString(string: String(localized: "You") + "\n", attributes: label))
            out.append(NSAttributedString(string: e.text + "\n\n", attributes: body))
        case .owl:
            out.append(NSAttributedString(string: String(localized: "Cedric") + "\n", attributes: label))
            out.append(NSAttributedString(string: e.text, attributes: body))
            out.append(NSAttributedString(string: "\n\n", attributes: body))
        case .tool, .note:
            out.append(NSAttributedString(string: e.text + "\n", attributes: quiet))
        case .scan:
            out.append(NSAttributedString(string: String(localized: "Offline scan (no AI)") + "\n", attributes: label))
            let mono: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
            out.append(NSAttributedString(string: e.text + "\n\n", attributes: mono))
        }
        return out
    }

    private func render() {
        guard let id = docID, let storage = transcript.textStorage else { return }
        let all = NSMutableAttributedString()
        let h = OwlChatStore.shared.history(id)
        if h.isEmpty {
            all.append(NSAttributedString(string: String(localized: "Ask a question, or pick a quick action. Cedric sees only what the chip above says, and nothing leaves this Mac or your network.") + "\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for e in h { all.append(attributed(e)) }
        storage.setAttributedString(all)
        transcript.scrollToEndOfDocument(nil)
    }

    /// The transcript's text (checks).
    var transcriptText: String { transcript.string }

    // MARK: Asking

    @objc func quickAction(_ sender: NSButton) {
        guard sender.tag < OwlQuickAction.allCases.count else { return }
        let a = OwlQuickAction.allCases[sender.tag]
        switch a {
        case .scriptSafety: checkScriptSafety()
        case .explainLine: explainLine()
        default: ask(question: sender.title, action: a)
        }
    }

    /// Explain Line: the selection, or the caret's whole line.
    func explainLine() {
        guard let tab else { return }
        let tv = tab.textView
        var sel = tv.selectedRange()
        let ns = tv.string as NSString
        if sel.length == 0 {
            let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            var len = line.length
            while len > 0, [10, 13].contains(Int(ns.character(at: line.location + len - 1))) { len -= 1 }
            guard len > 0 else { NSSound.beep(); return }
            sel = NSRange(location: line.location, length: len)
        }
        let title = actionButtons[.explainLine]?.title ?? OwlQuickAction.explainLine.title(prose: false)
        ask(question: title, action: .explainLine, selection: sel, scope: .selection)
    }

    /// The offline findings of the last script check (checks).
    private(set) var lastScan: [ScriptSafety.Finding]?
    /// The last script check's scan stopped at `ScriptSafety.maxLines` (checks).
    private(set) var lastScanTruncated = false
    /// The running script check's forced verdict, for an answer cut short.
    private var forcedVerdict: ScriptVerdict.Reason?
    /// The running script check's answer, clamped as it streams in.
    private var verdictStream: ScriptVerdictStream?
    /// What of the streamed answer the transcript shows now (script check).
    private var shownAnswer = ""
    /// Every text the script check's answer showed while streaming (checks).
    private(set) var streamedRenders: [String] = []

    /// Check for Risks: the offline scan first (no AI; works on any Mac),
    /// then, with Ask Cedric on and an engine ready, the model's review of
    /// the whole script (or what's in view) with the findings attached.
    /// The verdict is never "safe" (`ScriptVerdict`), and is "Don't run
    /// it" after a high finding or a partial review.
    func checkScriptSafety() {
        guard !running, let tab, let id = docID else { return }
        let text = tab.textView.string
        let language = tab.doc.language
        discardProposal(nil)
        let question = String(localized: "Check this script for risks.")
        OwlChatStore.shared.append(OwlChatEntry(role: .user, text: question), to: id)
        render()
        running = true
        updateButtons()
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .userInitiated) { ScriptSafety.check(text, language: language) }.value
            guard let self, let id = self.docID else { return }
            self.running = false
            self.lastScan = report.findings
            self.lastScanTruncated = report.truncated
            let summary = ScriptSafety.summary(report)
            OwlChatStore.shared.append(OwlChatEntry(role: .scan, text: summary), to: id)
            if Settings.shared.owlChat, AskCedricEngine.isAvailable {
                self.selectScope(.wholeDocument)
                self.ask(question: question, action: .scriptSafety, scope: .wholeDocument,
                         scan: report.findings.isEmpty && !report.truncated ? nil : summary,
                         scanHasHigh: report.hasHigh, scanTruncated: report.truncated, showQuestion: false)
            } else {
                var note = String(localized: "No AI engine is set up, so this is the offline scan only: it flags risky patterns, it can’t prove a script is harmless.")
                if let reason = ScriptVerdict.forcedReason(scanHasHigh: report.hasHigh, truncated: report.truncated) {
                    note += "\n" + reason.note + "\nVerdict: " + ScriptVerdict.forcedDontRun + "."
                }
                OwlChatStore.shared.append(OwlChatEntry(role: .note, text: note), to: id)
                self.render()
                self.updateButtons()
                self.onFinish?(nil)
            }
        }
    }

    @objc func send(_ sender: Any?) {
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        input.stringValue = ""
        ask(question: q, action: nil)
    }

    func snapshot() -> OwlDocumentSnapshot {
        guard let tab else { return OwlDocumentSnapshot(text: "", generation: 0) }
        let tv = tab.textView
        return OwlDocumentSnapshot(text: tv.string, generation: tab.doc.changeCount, selection: tv.selectedRange(),
                                   visible: tv.visibleCharacterRange, fileName: tab.doc.fileURL?.lastPathComponent,
                                   language: tab.doc.language.rawValue)
    }

    /// `selection` and `scope` override the document's and the chip's;
    /// `scan` is the script check's findings.
    func ask(question: String, action: OwlQuickAction?, selection: NSRange? = nil, scope forced: OwlChatScope? = nil,
             scan: String? = nil, scanHasHigh: Bool = false, scanTruncated: Bool = false, showQuestion: Bool = true) {
        guard !running, let tab, let id = docID else { return }
        discardProposal(nil)
        lastRequest = (question, action)
        forcedVerdict = nil
        verdictStream = nil
        shownAnswer = ""
        streamedRenders = []
        var snap = snapshot()
        if let selection {
            snap = OwlDocumentSnapshot(text: snap.text, generation: snap.generation, selection: selection, visible: snap.visible,
                                       fileName: snap.fileName, language: snap.language)
        }
        let scope = forced ?? selectedScope
        let prose = isProse
        var history = OwlChatStore.shared.history(id)
        if !showQuestion, history.last?.role == .scan { history.removeLast() }
        if !showQuestion, history.last?.role == .user { history.removeLast() }
        if showQuestion { OwlChatStore.shared.append(OwlChatEntry(role: .user, text: question), to: id) }
        OwlChatStore.shared.append(OwlChatEntry(role: .owl, text: ""), to: id)
        render()
        running = true
        asks += 1
        streamed = ""
        flushes = 0
        updateButtons()
        tab.owl?.chatPhase(.thinking)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let engine = await OwlChatStore.shared.engine() else {
                self.finish(nil, error: String(localized: "No AI engine is ready. Set one up in View › Cedric AI Settings…"))
                return
            }
            let ctx = OwlChatContext.build(snap, scope: scope, budget: engine.contextBudget)
                ?? OwlChatContext.build(snap, scope: .visible, budget: engine.contextBudget)!
            let tools = OwlChatStore.shared.useTools(engine)
            self.lastUsedTools = tools
            let req = OwlChatRequest(question: question, action: action, context: ctx, snapshot: snap,
                                     history: history, useTools: tools, prose: prose, scan: scan,
                                     scanHasHigh: scanHasHigh, scanTruncated: scanTruncated)
            self.forcedVerdict = req.forcedVerdict
            if action == .scriptSafety { self.verdictStream = ScriptVerdictStream(forced: req.forcedVerdict) }
            do {
                let outcome = try await OwlChatRunner.run(req, engine: engine, model: engine.scoreKey) { [weak self] ev in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(ev) } }
                }
                // Events queued before this point are delivered first.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(outcome, error: nil) } }
            } catch is CancellationError {
                self.finish(nil, error: String(localized: "Stopped."))
            } catch LocalAIError.cancelled {
                self.finish(nil, error: String(localized: "Stopped."))
            } catch BuiltInError.cancelled {
                self.finish(nil, error: String(localized: "Stopped."))
            } catch {
                self.finish(nil, error: Self.describe(error))
            }
        }
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case LocalAIError.timedOut: return String(localized: "The model took too long to answer.")
        case LocalAIError.endpointNotLocal: return String(localized: "The AI address isn’t on this Mac or the local network.")
        case LocalAIError.http(let c): return String(localized: "The AI server answered with an error (\(c)).")
        case BuiltInError.promptTooLong: return String(localized: "Too much text for this model: select less and ask again.")
        case BuiltInError.notInstalled: return String(localized: "No model downloaded yet: download one in Cedric AI Settings.")
        default: return String(localized: "Something went wrong: \(String(String(describing: e).prefix(160)))")
        }
    }

    private func handle(_ ev: OwlChatEvent) {
        guard running, let id = docID else { return }
        switch ev {
        case .text(let t):
            pendingText += t
            if flushTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.flush() }
                }
                RunLoop.main.add(timer, forMode: .common)
                flushTimer = timer
            }
        case .tool(let name, let summary):
            flush()
            // Above the answer being written.
            OwlChatStore.shared.insertBeforeLast(OwlChatEntry(role: .tool, text: "· " + summary), in: id)
            render()
            if name == .searchDocument { tab?.owl?.chatPhase(.searching) }
        case .proposal:
            tab?.owl?.chatPhase(.writing)
        case .phase(let p):
            tab?.owl?.chatPhase(p)
        }
    }

    /// Streamed text into the last (Cedric) entry and the transcript's end.
    private func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !pendingText.isEmpty, let id = docID else { return }
        let t = pendingText
        pendingText = ""
        streamed += t
        flushes += 1
        if var vs = verdictStream {
            // The script check: clamped before it shows (ScriptVerdictStream).
            let shown = vs.append(t)
            verdictStream = vs
            streamedRenders.append(shown)
            OwlChatStore.shared.replaceLast(OwlChatEntry(role: .owl, text: shown), in: id)
            if let storage = transcript.textStorage, storage.length >= 2 + (shownAnswer as NSString).length {
                let old = (shownAnswer as NSString).length
                storage.replaceCharacters(in: NSRange(location: storage.length - 2 - old, length: old),
                                          with: NSAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
                transcript.scrollToEndOfDocument(nil)
            }
            shownAnswer = shown
            return
        }
        OwlChatStore.shared.replaceLast(OwlChatEntry(role: .owl, text: streamed), in: id)
        // Before the trailing "\n\n" of the last entry.
        if let storage = transcript.textStorage, storage.length >= 2 {
            storage.insert(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]),
                           at: storage.length - 2)
            transcript.scrollToEndOfDocument(nil)
        }
    }

    /// Times streamed text reached the transcript during this answer (checks).
    private(set) var flushes = 0
    /// Characters of answer shown so far (checks: streaming arrives in steps).
    var streamedCount: Int { streamed.count }

    private func finish(_ outcome: OwlChatOutcome?, error: String?) {
        guard running else { return }
        flush()
        running = false
        task = nil
        lastOutcome = outcome
        if let id = docID {
            if let outcome {
                OwlChatStore.shared.replaceLast(OwlChatEntry(role: .owl, text: outcome.answer.isEmpty ? streamed : outcome.answer,
                                                             proposal: outcome.proposal), in: id)
            } else if let error {
                // A script check cut short still never reads as "safe".
                let partial = lastRequest?.action == .scriptSafety && !streamed.isEmpty
                    ? ScriptVerdict.clamp(streamed, forced: forcedVerdict) : streamed
                let text = partial.isEmpty ? error : partial + " (" + error + ")"
                OwlChatStore.shared.replaceLast(OwlChatEntry(role: .note, text: text), in: id)
            }
        }
        render()
        updateButtons()
        tab?.owl?.chatPhase(nil)
        if let p = outcome?.proposal { showProposal(p) }
        panel.makeFirstResponder(input)
        onFinish?(outcome)
    }

    @objc func stop(_ sender: Any?) {
        guard running else { return }
        task?.cancel()
        finish(nil, error: String(localized: "Stopped."))
    }

    // MARK: The proposed edit

    private func showProposal(_ p: OwlEditProposal) {
        pending = p
        cardTitle.stringValue = p.firstLine == p.lastLine
            ? String(localized: "Proposed change to line \(p.firstLine)")
            : String(localized: "Proposed change to lines \(p.firstLine)–\(p.lastLine)")
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for row in p.diffLines {
            let (prefix, bg): (String, NSColor) = row.kind == .removed ? ("- ", NSColor.systemRed.withAlphaComponent(0.18))
                : row.kind == .added ? ("+ ", NSColor.systemGreen.withAlphaComponent(0.18)) : ("  ", .clear)
            out.append(NSAttributedString(string: prefix + row.text + "\n",
                                          attributes: [.font: font, .foregroundColor: NSColor.labelColor, .backgroundColor: bg]))
        }
        diffView.textStorage?.setAttributedString(out)
        let current = isProposalCurrent
        staleLabel.isHidden = current
        applyButton.isEnabled = current && tab?.textView.isEditable == true
        askAgainButton.isHidden = current
        card.isHidden = false
    }

    var isProposalCurrent: Bool {
        guard let p = pending, let tab else { return false }
        return p.isCurrent(text: tab.textView.string as NSString, generation: tab.doc.changeCount)
    }

    /// Apply: one undo step, only if the document is what the model saw;
    /// otherwise the card says so and offers Ask Again.
    @discardableResult
    @objc func applyProposal(_ sender: Any?) -> Bool {
        guard let p = pending, let tab else { return false }
        guard isProposalCurrent else {
            staleLabel.isHidden = false
            askAgainButton.isHidden = false
            applyButton.isEnabled = false
            NSSound.beep()
            return false
        }
        guard tab.replaceAsOneStep(p.range, with: p.replacement, actionName: String(localized: "Cedric’s Edit")) else { return false }
        let r = NSRange(location: p.range.location, length: (p.replacement as NSString).length)
        tab.textView.setSelectedRange(r)
        tab.reveal(r)
        pending = nil
        card.isHidden = true
        if let id = docID { OwlChatStore.shared.append(OwlChatEntry(role: .note, text: String(localized: "Applied. ⌘Z undoes it.")), to: id) }
        render()
        tab.owl?.nod()
        return true
    }

    @objc func discardProposal(_ sender: Any?) {
        guard pending != nil || !card.isHidden else { return }
        pending = nil
        card.isHidden = true
        if sender != nil, let id = docID {
            OwlChatStore.shared.append(OwlChatEntry(role: .note, text: String(localized: "Discarded.")), to: id)
            render()
        }
    }

    @objc func askAgain(_ sender: Any?) {
        guard let r = lastRequest else { return }
        discardProposal(nil)
        ask(question: r.question, action: r.action)
    }

    /// The document changed: a pending proposal may have gone stale.
    func documentEdited() {
        guard pending != nil, !card.isHidden else { return }
        let current = isProposalCurrent
        staleLabel.isHidden = current
        askAgainButton.isHidden = current
        applyButton.isEnabled = current
    }

    // MARK: History

    @objc func copyMarkdown(_ sender: Any?) {
        guard let id = docID else { return }
        let md = OwlChatEntry.markdown(OwlChatStore.shared.history(id), fileName: tab?.doc.fileURL?.lastPathComponent)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    @objc func clearHistory(_ sender: Any?) {
        guard !running, let id = docID else { return }
        OwlChatStore.shared.clear(id)
        discardProposal(nil)
        render()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if running { stop(nil) } else { panel.performClose(nil) }
            return true
        }
        return false
    }
}

extension EditorWindowController {
    /// Edit › Ask Cedric… is available: the setting is on, not in large mode.
    var canAskCedric: Bool { Settings.shared.owlChat && !extrasPaused }

    func openAskCedric() {
        guard canAskCedric else { NSSound.beep(); return }
        chatPanel().show()
    }

    /// Edit › Check Script for Risks…: a script (shell, PowerShell,
    /// batch, .reg, Python, Ruby), not in large mode. Needs no AI: the
    /// offline scan always runs; the model's review follows when Ask
    /// Cedric is on with an engine ready.
    var canCheckScriptSafety: Bool { ScriptSafety.isScript(doc.language) && !extrasPaused }

    func checkScriptSafety() {
        guard canCheckScriptSafety else { NSSound.beep(); return }
        let p = chatPanel()
        p.show()
        p.checkScriptSafety()
    }
}

extension EditorWindowController {
    /// Edit › Spelling and Grammar › Check Grammar with AI, and the owl's button.
    var canCheckGrammarWithAI: Bool { grammar.mayCheckWithAI }
    func checkGrammarWithAI() {
        guard canCheckGrammarWithAI else { NSSound.beep(); return }
        grammar.checkWithAI(userAsked: true)
    }
}
