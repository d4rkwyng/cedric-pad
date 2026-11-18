import AppKit
import CedricCore
import CedricAI

/// CEDRIC_AI_CHECK=/out/dir: the owl's local-AI path end to end, in
/// process, with real NSEvents. Open a Swift file of 250+ lines (over the
/// 8 KB context cap, so the context starts mid-file) with the owl on.
///
///   1. View › Cedric AI Settings… (through the menu action); snapshot the
///      sheet. Live (CEDRIC_AI_CHECK_MODEL=id): Test Connection, wait for
///      the list, pick that model; snapshot again. Tick "Ask a local model"
///      and click Save.
///   2. The provider registered and the source is now "Rules + AI".
///   3. Go to line 200 and type a Swift off-by-one (`0...items.count`).
///   4. The owl takes its thinking pose while the request runs (snapshot).
///   5. The bubble shows the AI hint, source "local:<model>", and its
///      range, moved by `textStart`, is the right text in the document
///      (snapshot). Fake: the range is exactly `0...items.count` on the
///      typed line; Apply fixes it. Live: whatever the model said is
///      printed; its range (if any) must point at text in the document.
///   6. Fake only: the provider now hangs past the timeout; the owl
///      thinks, then goes back to idle with no bubble (snapshot).
@MainActor
enum AICheck {
    static var failures = 0
    static let env = ProcessInfo.processInfo.environment
    static var live: String? { env["CEDRIC_AI_CHECK_MODEL"] }

    static func check(_ ok: Bool, _ what: String) {
        print("aicheck: \(ok ? "ok  " : "FAIL") \(what)")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    static func log(_ s: String) { print("aicheck: \(s)"); fflush(stdout) }

    static func finish() {
        log(failures == 0 ? "PASS" : "FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    /// Polls `cond` every 0.1 s until it holds or `timeout` passes.
    static func wait(_ what: String, timeout: Double, _ cond: @escaping @MainActor () -> Bool, then: @escaping @MainActor (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if cond() { then(true); return }
            if Date() > deadline { log("timed out waiting for \(what)"); then(false); return }
            OwlCheck.after(0.1, poll)
        }
        poll()
    }

    /// A real click (mouse down/up through the window). A locked screen
    /// can swallow it; then the button is pressed the AppKit way, once.
    static func press(_ b: NSButton, _ name: String, happened: @MainActor () -> Bool) {
        if let w = b.window, NSApp.keyWindow != nil {
            let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            func ev(_ t: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) {
                NSApp.postEvent(up, atStart: false)
                w.sendEvent(down)
            }
        }
        if !happened() {
            log("(no click delivered on \(name)\(NSApp.keyWindow == nil ? ": no key window, screen locked" : ""); performClick)")
            b.performClick(nil)
        }
    }

    static func type(_ w: NSWindow, _ text: String) {
        for c in text {
            if c == "\n" { OwlCheck.key(w, "\r", code: 36, []) } else { OwlCheck.key(w, String(c), code: 0, []) }
        }
    }

    static func run(_ app: AppDelegate, out: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        guard let tab = app.currentTab ?? app.tabs.last, let window = tab.window, tab.owl != nil else { log("no tab with the owl"); exit(1) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.textView)
        if !(NSApp.isActive && window.occlusionState.contains(.visible)) {
            log("(screen not visible: treating the window as visible)")
            OwlController.assumeVisible = true
            tab.owl?.updateTimer()
        }
        OwlHub.shared.appActiveChanged()
        check(!OwlHub.shared.registry.hasAIProvider, "no AI provider before the settings are saved")
        NSApp.sendAction(#selector(AppDelegate.showAISettings(_:)), to: app, from: nil)
        guard let sheet = AISettingsSheet.current else { check(false, "the settings sheet opened"); finish(); return }
        check(sheet.enabledBox.state == .off, "AI is off by default")
        OwlCheck.after(0.3) {
            OwlCheck.snapshot(sheet.panel, "\(out)/0-sheet.png") {
                if let model = live { liveSheet(sheet, model: model, tab: tab, out: out) } else { saveSheet(sheet, tab: tab, out: out) }
            }
        }
    }

    static func liveSheet(_ sheet: AISettingsSheet, model: String, tab: EditorWindowController, out: String) {
        press(sheet.testButton, "Test Connection") { sheet.testing || sheet.report != nil }
        wait("Test Connection", timeout: 20, { !sheet.testing && sheet.report != nil }) { _ in
            let r = sheet.report
            check(r?.error == nil, "Test Connection reached the server (\(sheet.statusLabel.stringValue))")
            log("models: \(r?.models.map { "\($0.id) [\($0.sizeLabel)]" }.joined(separator: ", ") ?? "-")")
            log("suggested: \(r?.suggested?.id ?? "none")")
            check(r?.suggested.map { ($0.parametersB ?? 99) <= ModelPicker.maxAutoParametersB } ?? true, "the suggestion is never a big model")
            if let i = sheet.modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == model }) {
                sheet.modelPopup.selectItem(at: i)
                NSApp.sendAction(sheet.modelPopup.action!, to: sheet.modelPopup.target, from: sheet.modelPopup)
            }
            check((sheet.modelPopup.selectedItem?.representedObject as? String) == model, "picked \(model)")
            let weak = sheet.effectiveModel.map(ModelPicker.isWeak) ?? false
            check(sheet.weakLabel.isHidden == !weak, "the weak-model note \(weak ? "shows" : "is hidden") for \(model)")
            saveSheet(sheet, tab: tab, out: out)
        }
    }

    static func saveSheet(_ sheet: AISettingsSheet, tab: EditorWindowController, out: String) {
        press(sheet.enabledBox, "the checkbox") { sheet.enabledBox.state == .on }
        check(sheet.enabledBox.state == .on, "ticked “Ask a local model for hints”")
        OwlCheck.after(0.2) {
            OwlCheck.snapshot(sheet.panel, "\(out)/0-sheet-\(live == nil ? "enabled" : "tested").png") {
                press(sheet.saveButton, "Save") { AISettingsSheet.current == nil }
                let hub = OwlHub.shared
                wait("the provider to register", timeout: 15, { hub.ai.isActive && hub.coordinator.source == .rulesAndAI }) { ok in
                    if !ok { log("state: active=\(hub.ai.isActive) problem=\(hub.ai.lastProblem ?? "-") source=\(hub.coordinator.source) settings=\(Settings.shared.owlHintSource) saved=\(AIStore.load())") }
                    check(ok, "saved: provider \(hub.ai.providerName ?? "none") registered, source is Rules + AI")
                    check(Settings.shared.owlHintSource == .rulesAndAI, "Owl Hint Source › Rules + AI is selected")
                    if !ok { finish(); return }
                    typeBug(tab, out: out, attempt: 1)
                }
            }
        }
    }

    static let snippet = "func total(_ items: [Int]) -> Int {\nvar sum = 0\nfor i in 0...items.count { sum += items[i] }\nreturn sum\n}\n"

    static func typeBug(_ tab: EditorWindowController, out: String, attempt: Int) {
        guard let window = tab.window, let owl = tab.owl else { return }
        tab.goToLine(200)
        let hub = OwlHub.shared
        var shown: OwlHint?
        hub.onPresent = { t, h in if t === tab { shown = h } }
        OwlCheck.after(0.3) {
            if attempt == 1 {
                type(window, snippet)
            } else {
                type(window, " ")   // a new generation: the scheduler asks again
            }
            let top = tab.topLine
            log("typed at line 200 (top line \(top + 1), attempt \(attempt))")
            check(top > 150, "the view is scrolled to around line 200")
            wait("the thinking pose", timeout: 20, { owl.owl.pose == .thinking || shown != nil }) { ok in
                check(ok && shown == nil, "the owl thinks while the request runs")
                OwlCheck.snapshot(window, "\(out)/1-thinking.png") {
                    let budget: Double = live == nil ? 10 : 60
                    wait("the AI bubble", timeout: budget, { shown != nil || (hub.ai.thinking.isEmpty && owl.owl.pose != .thinking) }) { _ in
                        guard let hint = shown else {
                            if live != nil, attempt < 3 {
                                log("the model gave no hint this time; editing again (attempt \(attempt + 1))")
                                OwlCheck.after(Double(env["CEDRIC_AI_INTERVAL"] ?? "5") ?? 5) { typeBug(tab, out: out, attempt: attempt + 1) }
                            } else {
                                check(false, "the AI hint appeared in the bubble"); finish()
                            }
                            return
                        }
                        bubble(tab, hint, out: out)
                    }
                }
            }
        }
    }

    static func bubble(_ tab: EditorWindowController, _ hint: OwlHint, out: String) {
        guard let owl = tab.owl, let window = tab.window else { return }
        let hub = OwlHub.shared
        hub.onPresent = nil
        let name = hub.ai.providerName ?? "?"
        check(hint.source == name && hint.source.hasPrefix("local:"), "the bubble shows the AI hint, source \(hint.source)")
        check(owl.bubble != nil && owl.owl.pose == .talking, "bubble up, owl talking")
        log("hint: [\(hint.kind.rawValue)] \(hint.title)\(hint.detail.map { " — \($0)" } ?? "")\(hint.replacement.map { " → \($0)" } ?? "")")
        let ns = tab.text as NSString
        let typed = ns.range(of: FakeAIProvider.needle)
        if let r = owl.presentedHint?.documentRange {
            let ok = NSMaxRange(r) <= ns.length
            let text = ok ? ns.substring(with: r) : "<out of range>"
            let line = tab.lineIndex.line(containing: r.location) + 1
            log("document range \(r.location)+\(r.length) (line \(line)) = “\(text)”; context range \(hint.range.map { "\($0.location)+\($0.length)" } ?? "-")")
            check(ok && hint.range.map { $0.location != r.location } == true, "the range was moved from the context into the document (textStart > 0)")
            if live == nil {
                check(r == typed && text == FakeAIProvider.needle && line >= 200, "the range is exactly the typed `0...items.count` on line \(line)")
            } else {
                check(ok && line > 150, "the range points at text in the viewed region (line \(line))")
            }
        } else {
            check(live != nil, "the hint has a range")
        }
        OwlCheck.snapshot(window, "\(out)/2-bubble.png") {
          wait("the status line", timeout: 5, { owl.owl.toolTipText.contains("Last checked") }) { ok in
            check(ok, "the owl's tooltip shows the AI status: \(owl.owl.toolTipText.replacingOccurrences(of: "\n", with: " | "))")
            guard live == nil else { finish(); return }
            // Fake: Apply, and the next request hangs past the timeout.
            FakeAIProvider.delay.set(30)
            guard let apply = owl.bubble?.buttons.first(where: { $0.title == String(localized: "Fix it") }) else {
                check(false, "bubble has Apply"); finish(); return
            }
            press(apply, "Apply") { owl.bubble == nil }
            check((tab.text as NSString).range(of: "for i in 0..<items.count").location != NSNotFound, "Apply fixed the loop in the document")
            timeoutPhase(tab, out: out)
          }
        }
    }

    static func timeoutPhase(_ tab: EditorWindowController, out: String) {
        guard let owl = tab.owl, let window = tab.window else { return }
        let hub = OwlHub.shared
        var shown = false
        hub.onPresent = { _, _ in shown = true }
        wait("thinking after the edit", timeout: 10, { owl.owl.pose == .thinking }) { ok in
            check(ok, "the next request: thinking")
            let t0 = Date()
            wait("idle after the timeout", timeout: 15, { owl.owl.pose == .idle && hub.ai.thinking.isEmpty }) { ok in
                check(ok && !shown && owl.bubble == nil, String(format: "timed out after %.1f s: the owl is idle again, no bubble", Date().timeIntervalSince(t0)))
                OwlCheck.snapshot(window, "\(out)/3-timeout-idle.png") { finish() }
            }
        }
    }
}
