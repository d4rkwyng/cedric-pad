import AppKit
import CedricCore
import CedricAI

/// Where the Cedric AI settings live, plus the run-only overrides the
/// checks use (none of them is saved):
///
///   CEDRIC_AI=1 / 0           enable / disable for this run
///   CEDRIC_AI_BACKEND=builtIn engine (builtIn, lmStudio, ollama, custom, apple)
///   CEDRIC_AI_URL=…           endpoint (Custom)
///   CEDRIC_AI_MODEL=…         model id
///   CEDRIC_AI_PAUSE=5         typing pause before a check, seconds
///   CEDRIC_AI_INTERVAL=90     at most one check per this many seconds
///   CEDRIC_AI_TIMEOUT=20      request cap, seconds
///   CEDRIC_AI_FAKE=1.5        use a fake provider that answers after this many seconds
///   CEDRIC_AI_DEFAULTS=suite  keep the settings in this UserDefaults suite
@MainActor
enum AIStore {
    static let env = ProcessInfo.processInfo.environment
    static var defaults: UserDefaults { env["CEDRIC_AI_DEFAULTS"].flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    static func load() -> LocalAISettings {
        var s = LocalAISettings.load(from: defaults)
        if let v = env["CEDRIC_AI"] { s.enabled = v == "1" }
        if let v = env["CEDRIC_AI_BACKEND"].flatMap(LocalAISettings.Backend.init(rawValue:)) { s.selectBackend(v) }
        if let v = env["CEDRIC_AI_URL"].flatMap(LocalAISettings.parseEndpoint) { s.backend = .custom; s.baseURL = v }
        if let v = env["CEDRIC_AI_MODEL"], !v.isEmpty { s.model = v }
        if let v = env["CEDRIC_AI_PAUSE"].flatMap(Double.init) { s.pauseDelay = v }
        if let v = env["CEDRIC_AI_INTERVAL"].flatMap(Double.init) { s.minInterval = v }
        if let v = env["CEDRIC_AI_TIMEOUT"].flatMap(Double.init) { s.timeout = v }
        return s
    }

    static func save(_ s: LocalAISettings) { s.save(to: defaults) }

    /// The real provider, or the fake one under CEDRIC_AI_FAKE.
    static func makeProvider(_ s: LocalAISettings) async -> (any OwlHintProvider)? {
        if let d = env["CEDRIC_AI_FAKE"].flatMap(Double.init) {
            FakeAIProvider.delay.set(d)
            return FakeAIProvider()
        }
        return await LocalAIOwl.makeProvider(settings: s)
    }
}

/// CEDRIC_AI_FAKE: answers after `delay` seconds with one "fix" for the
/// first `0...items.count` in the context (a Swift off-by-one), its range
/// relative to `context.text` like a real provider's. No network.
struct FakeAIProvider: OwlHintProvider {
    final class Delay: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Double = 1.5
        func set(_ x: Double) { lock.withLock { v = x } }
        var value: Double { lock.withLock { v } }
    }
    static let delay = Delay()
    static let needle = "0...items.count"
    let name = "local:fake-qwen"

    func hints(for context: OwlContext) async -> [OwlHint] {
        try? await Task.sleep(nanoseconds: UInt64(Self.delay.value * 1_000_000_000))
        guard !Task.isCancelled else { return [] }
        let r = (context.text as NSString).range(of: Self.needle)
        guard r.location != NSNotFound else { return [] }
        return [OwlHint(id: "fake-off-by-one", kind: .fix, title: "Off by one: the loop runs past the last item",
                        detail: "0...items.count includes items.count; use 0..<items.count.",
                        range: r, replacement: "0..<items.count", source: name)]
    }
}

/// View › Cedric AI Settings…: a sheet over the current tab.
@MainActor
final class AISettingsSheet: NSObject {
    static var current: AISettingsSheet?

    let panel: NSPanel
    let enabledBox = NSButton(checkboxWithTitle: String(localized: "Ask a local model for hints"), target: nil, action: nil)
    let presetPopup = NSPopUpButton()
    let urlField = NSTextField()
    let testButton = NSButton(title: String(localized: "Test Connection"), target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let modelsLabel = NSTextField(wrappingLabelWithString: "")
    let modelPopup = NSPopUpButton()
    let weakLabel = NSTextField(labelWithString: LocalAISettings.weakModelNote)
    let intervalPopup = NSPopUpButton()
    let saveButton = NSButton(title: String(localized: "Save"), target: nil, action: nil)
    let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)

    private var settings: LocalAISettings
    private var grid: NSGridView?
    let privacyLabel = NSTextField(wrappingLabelWithString: LocalAISettings.privacyNote)
    /// Built-in only: the catalog with Download / Pause / Delete per model.
    let modelsView = BuiltInModelsView()
    /// The engine's caveat ("Slow on Intel Macs…"), hidden when it has none.
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    /// The selected engine (the sheet only talks to `AIEngine`).
    var engine: any AIEngine {
        settings.backend == .builtIn ? BuiltInDownloads.shared.engine : AIEngines.engine(for: settings)
    }
    /// The menu's intervals, plus the saved one if it isn't a menu value.
    private lazy var intervals: [TimeInterval] = Array(Set(LocalAISettings.intervalChoices + [settings.minInterval])).sorted()
    private(set) var report: ConnectionReport?
    private(set) var testing = false
    /// Called when the sheet closes (saved or not), for the checks.
    var onClose: ((Bool) -> Void)?

    init(settings: LocalAISettings) {
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = String(localized: "Cedric AI")
        build()
        load()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        for (b, a) in [(enabledBox, #selector(changed)), (testButton, #selector(test)), (saveButton, #selector(save)), (cancelButton, #selector(cancel))] {
            b.target = self; b.action = a
        }
        for p in [presetPopup, modelPopup, intervalPopup] { p.target = self; p.action = #selector(changed) }
        // "Where the AI runs": every engine, unavailable ones disabled.
        presetPopup.autoenablesItems = false
        for kind in LocalAISettings.Backend.allCases {
            var probe = settings
            probe.backend = kind
            let engine = AIEngines.engine(for: probe)
            presetPopup.addItem(withTitle: engine.title)
            presetPopup.lastItem?.isEnabled = engine.isAvailable
            presetPopup.lastItem?.toolTip = engine.unavailableReason
        }
        for v in intervals {
            intervalPopup.addItem(withTitle: v == 1 ? String(localized: "1 second")
                                  : v < 120 ? String(localized: "\(Int(v)) seconds") : String(localized: "\(Int(v) / 60) minutes"))
        }
        urlField.target = self
        urlField.action = #selector(changed)
        urlField.placeholderString = "http://studio.local:1234/v1"
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let privacy = privacyLabel
        privacy.font = small
        privacy.textColor = .secondaryLabelColor
        for l in [statusLabel, modelsLabel, weakLabel, noteLabel] { l.font = small }
        noteLabel.textColor = .systemOrange
        modelsView.onChange = { [weak self] in self?.refresh() }
        weakLabel.textColor = .systemOrange
        modelsLabel.textColor = .secondaryLabelColor
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        let testRow = NSStackView(views: [testButton, statusLabel])
        testRow.alignment = .firstBaseline
        let grid = NSGridView(views: [
            [NSGridCell.emptyContentView, enabledBox],
            [label(String(localized: "Where the AI runs:")), presetPopup],
            [label(String(localized: "Address:")), urlField],
            [NSGridCell.emptyContentView, privacy],
            [NSGridCell.emptyContentView, noteLabel],
            [label(String(localized: "Download:")), modelsView],
            [NSGridCell.emptyContentView, testRow],
            [NSGridCell.emptyContentView, modelsLabel],
            [label(String(localized: "Model:")), modelPopup],
            [NSGridCell.emptyContentView, weakLabel],
            [label(String(localized: "Check at most every:")), intervalPopup],
        ])
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        urlField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        for l in [privacy, modelsLabel, statusLabel, noteLabel] { l.preferredMaxLayoutWidth = 380 }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        panel.contentView = content
    }

    /// Settings → controls.
    private func load() {
        enabledBox.state = settings.enabled ? .on : .off
        presetPopup.selectItem(at: LocalAISettings.Backend.allCases.firstIndex(of: settings.backend) ?? 0)
        urlField.stringValue = settings.baseURL.absoluteString
        intervalPopup.selectItem(at: intervals.firstIndex(of: settings.minInterval) ?? 0)
        refresh()
    }

    /// The models the popup offers: the tested list (no embedding models),
    /// plus the saved model if the list doesn't have it.
    private var offered: [LocalModelInfo] {
        // Built-in: the downloaded models, known without a test.
        var list = settings.backend == .builtIn ? BuiltInDownloads.shared.engine.installedModels.map(\.info)
            : (report?.models ?? []).filter { !$0.isEmbedding }
        if let m = settings.model, !list.contains(where: { $0.id == m }) { list.insert(LocalModelInfo(id: m), at: 0) }
        return list
    }

    /// The model hints would use: the chosen one, or the suggestion.
    var effectiveModel: LocalModelInfo? {
        if let m = settings.model { return offered.first { $0.id == m } ?? LocalModelInfo(id: m) }
        return suggested
    }

    /// The automatic choice: built-in knows it from the downloads.
    private var suggested: LocalModelInfo? {
        settings.backend == .builtIn ? BuiltInDownloads.shared.engine.suggestedModel(in: offered) : report?.suggested
    }

    private func refresh() {
        let custom = settings.backend == .custom
        let needsAddress = engine.needsAddress
        grid?.cell(for: urlField)?.row?.isHidden = !needsAddress
        privacyLabel.stringValue = needsAddress ? LocalAISettings.privacyNote : LocalAISettings.privacyNoteOnDevice
        urlField.isEditable = custom
        urlField.isSelectable = true
        urlField.textColor = custom ? .labelColor : .secondaryLabelColor
        if !custom { urlField.stringValue = settings.baseURL.absoluteString }

        let builtIn = settings.backend == .builtIn
        grid?.cell(for: modelsView)?.row?.isHidden = !builtIn
        noteLabel.stringValue = engine.note ?? ""
        grid?.cell(for: noteLabel)?.row?.isHidden = engine.note == nil

        modelPopup.removeAllItems()
        let auto: String
        if let s = suggested { auto = String(localized: "Automatic (\(s.id))") }
        else if builtIn { auto = String(localized: "Automatic (download a model below)") }
        else if report != nil { auto = String(localized: "Automatic (no small Qwen found)") }
        else { auto = String(localized: "Automatic (small Qwen)") }
        modelPopup.addItem(withTitle: auto)
        modelPopup.lastItem?.representedObject = nil
        for m in offered {
            modelPopup.addItem(withTitle: m.sizeLabel.isEmpty ? m.id : "\(m.id)  (\(m.sizeLabel))")
            modelPopup.lastItem?.representedObject = m.id
        }
        if let m = settings.model, let i = modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == m }) {
            modelPopup.selectItem(at: i)
        } else {
            modelPopup.selectItem(at: 0)
        }
        let weak = effectiveModel.map(ModelPicker.isWeak) ?? false
        weakLabel.isHidden = !weak
        grid?.cell(for: weakLabel)?.row?.isHidden = !weak

        if let r = report {
            let list = r.models.filter { !$0.isEmbedding }.map { m -> String in
                let tag = m.id == r.suggested?.id ? String(localized: "  ← suggested") : ""
                return "• \(m.id)\(m.sizeLabel.isEmpty ? "" : "  \(m.sizeLabel)")\(tag)"
            }
            modelsLabel.stringValue = list.joined(separator: "\n")
            modelsLabel.isHidden = list.isEmpty
        } else {
            modelsLabel.stringValue = ""
            modelsLabel.isHidden = true
        }
        grid?.cell(for: modelsLabel)?.row?.isHidden = modelsLabel.isHidden
        fit()
    }

    /// The panel takes the content's size (rows come and go).
    private func fit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if size.height > 0 { panel.setContentSize(NSSize(width: max(size.width, 480), height: size.height)) }
    }

    /// Controls → settings. False (with a message) if the address isn't local.
    @discardableResult
    private func read() -> Bool {
        settings.enabled = enabledBox.state == .on
        let backend = LocalAISettings.Backend.allCases[max(0, presetPopup.indexOfSelectedItem)]
        if backend != settings.backend {
            settings.selectBackend(backend)
            report = nil
        }
        if backend == .custom {
            guard let url = LocalAISettings.parseEndpoint(urlField.stringValue) else {
                status(String(localized: "Not an address on this Mac or the local network."), error: true)
                return false
            }
            if url != settings.baseURL { settings.baseURL = url; report = nil }
        }
        settings.model = modelPopup.selectedItem?.representedObject as? String
        settings.minInterval = intervals[max(0, intervalPopup.indexOfSelectedItem)]
        return true
    }

    private func status(_ s: String, error: Bool = false) {
        statusLabel.stringValue = s
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func changed() {
        if read() { status("") }
        refresh()
    }

    @objc func test() {
        guard read(), !testing else { refresh(); return }
        testing = true
        testButton.isEnabled = false
        let builtIn = settings.backend == .builtIn
        status(builtIn ? String(localized: "Loading the model…") : String(localized: "Connecting…"))
        var quick = settings
        quick.timeout = 5
        let engine = builtIn ? self.engine : AIEngines.engine(for: quick)
        Task { @MainActor in
            let r = await engine.test()
            testing = false
            testButton.isEnabled = true
            report = r
            if let e = r.error {
                status(builtIn ? String(localized: "Couldn’t run the model (\(Self.describe(e))).")
                               : String(localized: "Couldn’t connect (\(Self.describe(e))). Is the server running?"), error: true)
            } else if builtIn {
                status(String(localized: "Loaded and answered in \(Int(r.latency * 1000)) ms."))
            } else {
                let n = r.models.filter { !$0.isEmbedding }.count
                status(String(localized: "Connected in \(Int(r.latency * 1000)) ms: \(n) models."))
            }
            refresh()
        }
    }

    static func describe(_ e: LocalAIError) -> String {
        switch e {
        case .endpointNotLocal: return String(localized: "not a local address")
        case .http(let c): return "HTTP \(c)"
        case .timedOut: return String(localized: "timed out")
        case .transport(let s): return s
        case .badResponse: return String(localized: "unexpected answer")
        case .cancelled: return String(localized: "cancelled")
        }
    }

    @objc func save() {
        guard read() else { return }
        let s = settings
        close(saved: true)
        Task { @MainActor in await OwlHub.shared.applyAISettings(s) }
    }

    @objc func cancel() { close(saved: false) }

    private func close(saved: Bool) {
        modelsView.detach()
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        Self.current = nil
        onClose?(saved)
    }

    /// Opens the sheet on `window` (or as a panel when there is none).
    static func show(on window: NSWindow?) {
        if let c = current { c.panel.makeKeyAndOrderFront(nil); return }
        let sheet = AISettingsSheet(settings: AIStore.load())
        current = sheet
        if let window { window.beginSheet(sheet.panel) } else { sheet.panel.center(); sheet.panel.makeKeyAndOrderFront(nil) }
    }
}
