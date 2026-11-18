import AppKit
import CedricCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var tabs: [EditorWindowController] = []
    private let store = SessionStore(directory: SessionStore.defaultDirectory())
    private let env = ProcessInfo.processInfo.environment
    private var untitledCounter = 0
    private var sessionTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    /// Files handed over before launch finished (Finder, `open`).
    private var pendingOpen: [URL] = []
    private var launched = false
    /// Set once quitting: windows closed by termination keep their buffers.
    private var terminating = false

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil) }
        }
        // The owl hub listens for View › Show Cedric the Owl; it must exist
        // before the first toggle (it was created lazily, so with the owl
        // off and only untitled tabs the menu item did nothing).
        _ = OwlHub.shared
        if env["CEDRIC_NO_RESTORE"] != "1" { restoreSession() }
        var toOpen = pendingOpen
        if let list = env["CEDRIC_OPEN"], !list.isEmpty {
            toOpen += list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        for url in toOpen { open(url) }
        pendingOpen = []
        if tabs.isEmpty { newTab(nil) }
        rebuildRecentMenu()
        launched = true
        DevHooks.afterLaunch(self)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingOpen += urls; return }
        for url in urls { open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newTab(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// No "save changes?" on quit: every tab, saved or not, comes back next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSession()
        terminating = true
        sessionTimer?.invalidate()
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        tabs.forEach { $0.reloadIfChangedOnDisk() }
    }

    /// `cedric://open?path=/abs/file&line=12` (the command-line launcher)
    /// and `cedric://open?untitled=/tmp/file` (stdin: opened as a new
    /// untitled tab, then the temp file is deleted).
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s), comps.scheme == "cedric" else { return }
        let q = Dictionary((comps.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        if let path = q["path"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                open(url)
            } else {
                // A new file: an empty tab that saves there.
                let doc = EditorDocument(fileURL: url, untitledName: url.lastPathComponent)
                doc.language = LanguageDetector.language(forFileName: url.lastPathComponent) ?? .plain
                let tab = makeTab(doc, text: "")
                doc.markDirtyFromSession()
                tab.updateTitle()
            }
            if let line = q["line"].flatMap(Int.init) { tabs.first { $0.doc.fileURL?.standardizedFileURL == url.standardizedFileURL }?.goToLine(line) }
        } else if let tmp = q["untitled"], tmp.hasPrefix(NSTemporaryDirectory()) || tmp.hasPrefix("/tmp/") || tmp.hasPrefix("/private/") {
            let url = URL(fileURLWithPath: tmp)
            if let (d, _) = try? EditorDocument.read(url) {
                let doc = newDocument()
                doc.apply(d)
                doc.language = LanguageDetector.sniff(d.text)
                makeTab(doc, text: d.text)
                doc.markDirtyFromSession()
                tabs.last?.updateTitle()
            }
            try? FileManager.default.removeItem(at: url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Tabs

    private func newDocument() -> EditorDocument {
        untitledCounter += 1
        return EditorDocument(untitledName: untitledCounter == 1 ? String(localized: "Untitled") : String(localized: "Untitled \(untitledCounter)"))
    }

    @discardableResult
    func makeTab(_ doc: EditorDocument, text: String, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true) -> EditorWindowController {
        let tab = EditorWindowController(doc: doc, text: text)
        tab.onChange = { [weak self] _ in self?.scheduleSessionSave() }
        tab.onClose = { [weak self] t in
            guard let self, !self.terminating else { return }
            self.tabs.removeAll { $0 === t }
            self.store.removeBuffer(t.doc.id)
            self.scheduleSessionSave()
        }
        tabs.append(tab)
        guard let window = tab.window else { return tab }
        let host = newWindow ? nil : group ?? NSApp.keyWindow ?? tabs.dropLast().last?.window
        if let host, host !== window, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        if show { window.makeKeyAndOrderFront(nil) }
        scheduleSessionSave()
        return tab
    }

    @objc func newTab(_ sender: Any?) {
        makeTab(newDocument(), text: "")
    }

    @objc func newWindow(_ sender: Any?) {
        makeTab(newDocument(), text: "", newWindow: true)
    }

    /// The "+" in the tab bar.
    @objc func newWindowForTab(_ sender: Any?) { newTab(sender) }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let dir = currentTab?.doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { open($0) }
    }

    var currentTab: EditorWindowController? {
        tabs.first { $0.window === NSApp.keyWindow } ?? tabs.first { $0.window === NSApp.mainWindow }
            // Not active (launched from a script, screen locked): the
            // frontmost tab. The owl check (CEDRIC_OWL_ASSUME_VISIBLE) may
            // run with no window ordered in; it falls back to the newest tab.
            ?? (NSApp.keyWindow == nil && NSApp.mainWindow == nil || OwlController.assumeVisible
                ? NSApp.orderedWindows.lazy.compactMap { w in self.tabs.first { $0.window === w } }.first
                    ?? (OwlController.assumeVisible ? tabs.last : nil)
                : nil)
    }

    /// Opens a file in a new tab, or focuses the tab that has it. An empty,
    /// untouched untitled tab is replaced, as in Notepad++.
    @discardableResult
    func open(_ url: URL) -> EditorWindowController? {
        let std = url.standardizedFileURL
        if let existing = tabs.first(where: { $0.doc.fileURL?.standardizedFileURL == std }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        do {
            let (d, mod) = try EditorDocument.read(std)
            let doc = EditorDocument(fileURL: std, untitledName: std.lastPathComponent)
            doc.apply(d)
            doc.fileModified = mod
            doc.language = LanguageDetector.detect(fileName: std.lastPathComponent, content: d.text)
            let blank = tabs.count == 1 && tabs[0].doc.fileURL == nil && !tabs[0].doc.isDirty && tabs[0].text.isEmpty ? tabs[0] : nil
            let tab = makeTab(doc, text: d.text)
            blank?.window?.close()
            OwlHub.shared.activity(in: tab)
            noteRecent(std)
            return tab
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func tabBecameKey(_ tab: EditorWindowController) {
        // The Find in Files panel follows the selected tab.
        if let p = findInFiles, p.isShown { tab.dockSidePanel(p) }
    }

    /// Find in Files (one panel, docked in whichever tab is selected) and
    /// open Compare windows (EditorTools.swift).
    var findInFiles: FindInFilesPanel?
    var compareWindows: [CompareWindowController] = []

    // MARK: Session

    /// Saves soon after a change (coalesced): a crash loses at most ~1.5 s of typing.
    func scheduleSessionSave() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    /// The windows in on-screen order, each with its tabs in tab-bar order.
    private func tabGroups() -> [[EditorWindowController]] {
        var seen = Set<ObjectIdentifier>()
        var groups: [[EditorWindowController]] = []
        let ordered = NSApp.orderedWindows + tabs.compactMap(\.window)
        for w in ordered {
            guard !seen.contains(ObjectIdentifier(w)), tabs.contains(where: { $0.window === w }) else { continue }
            let members = (w.tabbedWindows ?? [w]).compactMap { win in tabs.first { $0.window === win } }
            for m in members { if let mw = m.window { seen.insert(ObjectIdentifier(mw)) } }
            if !members.isEmpty { groups.append(members) }
        }
        return groups
    }

    func saveSession() {
        sessionTimer?.invalidate()
        guard env["CEDRIC_NO_SESSION_SAVE"] != "1" else { return }
        var windows: [SessionWindow] = []
        var keep = Set<UUID>()
        for group in tabGroups() {
            var sessionTabs: [SessionTab] = []
            var selected = 0
            for (i, t) in group.enumerated() {
                let d = t.doc
                let needsBuffer = d.isDirty || d.fileURL == nil && !t.text.isEmpty
                if needsBuffer {
                    keep.insert(d.id)
                    if d.sessionChangeCount != d.changeCount {
                        do {
                            try store.writeBuffer(d.id, text: t.text)
                            d.sessionChangeCount = d.changeCount
                        } catch {
                            FileHandle.standardError.write(Data("session: buffer write failed: \(error)\n".utf8))
                        }
                    }
                } else {
                    d.sessionChangeCount = -1
                }
                // An untouched empty untitled tab isn't worth restoring.
                if d.fileURL == nil && t.text.isEmpty { continue }
                let sel = t.textView.selectedRange()
                sessionTabs.append(SessionTab(id: d.id, path: d.fileURL?.path, untitledName: d.fileURL == nil ? d.untitledName : nil,
                                              hasBuffer: needsBuffer, encoding: d.encoding, lineEnding: d.lineEnding,
                                              language: d.languageIsManual ? d.language : nil,
                                              selectionLocation: sel.location, selectionLength: sel.length,
                                              topLine: t.topLine, fileModified: d.fileModified))
                if t.window === NSApp.keyWindow || t.window?.tabGroup?.selectedWindow === t.window { selected = sessionTabs.count - 1 }
            }
            if !sessionTabs.isEmpty {
                windows.append(SessionWindow(tabs: sessionTabs, selectedTab: selected, frame: group.first?.window?.frameDescriptor))
            }
        }
        do {
            try store.save(Session(windows: windows, untitledCounter: untitledCounter))
            store.pruneBuffers(keeping: keep)
        } catch {
            FileHandle.standardError.write(Data("session: save failed: \(error)\n".utf8))
        }
    }

    private func restoreSession() {
        guard let session = store.load() else { return }
        untitledCounter = session.untitledCounter
        for w in session.windows {
            var host: NSWindow?
            var selectedWindow: NSWindow?
            for (i, st) in w.tabs.enumerated() {
                let doc = EditorDocument(id: st.id, fileURL: st.path.map { URL(fileURLWithPath: $0) },
                                         untitledName: st.untitledName ?? st.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Untitled"))
                var text: String?
                if st.hasBuffer { text = store.readBuffer(st.id) }
                if text == nil, let url = doc.fileURL, let (d, mod) = try? EditorDocument.read(url, encoding: st.encoding) {
                    doc.apply(d)
                    doc.fileModified = mod
                    text = d.text
                } else if text != nil {
                    doc.encoding = st.encoding
                    doc.lineEnding = st.lineEnding
                    doc.fileModified = st.fileModified
                }
                guard let body = text else { continue } // the file is gone and there was no buffer
                if let l = st.language {
                    doc.language = l
                    doc.languageIsManual = true
                } else {
                    doc.language = LanguageDetector.detect(fileName: doc.fileURL?.lastPathComponent, content: body)
                }
                let tab = makeTab(doc, text: body, in: host, newWindow: host == nil, show: false)
                if st.hasBuffer { doc.markDirtyFromSession(); doc.sessionChangeCount = doc.changeCount }
                tab.updateTitle()
                let len = (body as NSString).length
                tab.textView.setSelectedRange(NSRange(location: min(st.selectionLocation, len), length: min(st.selectionLength, max(0, len - st.selectionLocation))))
                if host == nil {
                    host = tab.window
                    if let f = w.frame { tab.window?.setFrame(from: f) }
                    tab.window?.orderFront(nil)
                }
                if i == w.selectedTab { selectedWindow = tab.window }
                let top = st.topLine
                DispatchQueue.main.async { tab.scrollToLine(top) }
            }
            (selectedWindow ?? host)?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Menu actions routed to the current tab

    @objc func saveDocument(_ sender: Any?) { currentTab?.save() }
    @objc func saveDocumentAs(_ sender: Any?) { currentTab?.saveAs() }
    @objc func showFind(_ sender: Any?) { currentTab?.showFindBar(replace: false) }
    @objc func showReplace(_ sender: Any?) { currentTab?.showFindBar(replace: true) }
    @objc func findNextMatch(_ sender: Any?) { currentTab?.find(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { currentTab?.find(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let t = currentTab else { return }
        let sel = t.textView.selectedRange()
        guard sel.length > 0 else { return }
        t.findBar.findField.stringValue = (t.text as NSString).substring(with: sel)
    }
    @objc func goToLine(_ sender: Any?) { currentTab?.goToLinePrompt(sender) }
    @objc func togglePreview(_ sender: Any?) { currentTab?.togglePreview() }
    @objc func togglePreviewJavaScript(_ sender: Any?) { currentTab.map { $0.previewAllowsJavaScript.toggle() } }
    @objc func togglePreviewNetwork(_ sender: Any?) { currentTab.map { $0.previewAllowsNetwork.toggle() } }
    @objc func toggleWrap(_ sender: Any?) { Settings.shared.wrapLines.toggle() }
    @objc func toggleInvisibles(_ sender: Any?) { Settings.shared.showInvisibles.toggle() }
    @objc func toggleLineNumbers(_ sender: Any?) { Settings.shared.showLineNumbers.toggle() }
    @objc func toggleOwl(_ sender: Any?) { Settings.shared.showOwl.toggle() }
    @objc func showAISettings(_ sender: Any?) { AISettingsSheet.show(on: currentTab?.window) }
    @objc func pickOwlHintSource(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let src = OwlHintSource(rawValue: raw) { Settings.shared.owlHintSource = src }
    }
    @objc func zoomIn(_ sender: Any?) { Settings.shared.fontSize += 1 }
    @objc func zoomOut(_ sender: Any?) { Settings.shared.fontSize -= 1 }
    @objc func zoomReset(_ sender: Any?) { Settings.shared.fontSize = Settings.defaultFontSize }
    @objc func pickTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = EditorTheme(rawValue: raw) { Settings.shared.theme = t }
    }
    @objc func pickLanguageMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = Language(rawValue: raw) { currentTab?.setLanguage(l, manual: true) }
    }
    @objc func pickLineEndingMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let le = LineEnding(rawValue: raw) { currentTab?.convertLineEndings(to: le) }
    }
    @objc func pickEncodingMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let e = TextEncoding(rawValue: raw) { currentTab?.convertEncoding(to: e) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = currentTab
        let s = Settings.shared
        switch item.action {
        case #selector(toggleWrap(_:)): item.state = s.wrapLines ? .on : .off
        case #selector(toggleInvisibles(_:)): item.state = s.showInvisibles ? .on : .off
        case #selector(toggleLineNumbers(_:)): item.state = s.showLineNumbers ? .on : .off
        case #selector(toggleOwl(_:)): item.state = s.showOwl ? .on : .off
        case #selector(pickOwlHintSource(_:)):
            // "Rules + AI" stays off until an AI provider registers.
            let ai = OwlHub.shared.registry.hasAIProvider
            let effective = ai ? s.owlHintSource : .rules
            item.state = (item.representedObject as? String) == effective.rawValue ? .on : .off
            return s.showOwl && (item.representedObject as? String == OwlHintSource.rules.rawValue || ai)
        case #selector(pickTheme(_:)): item.state = (item.representedObject as? String) == s.theme.rawValue ? .on : .off
        case #selector(togglePreview(_:)):
            item.state = tab?.previewVisible == true ? .on : .off
            return tab?.doc.language.hasPreview == true
        case #selector(togglePreviewJavaScript(_:)):
            item.state = tab?.previewAllowsJavaScript == true ? .on : .off
            return tab?.previewVisible == true
        case #selector(togglePreviewNetwork(_:)):
            item.state = tab?.previewAllowsNetwork == true ? .on : .off
            return tab?.previewVisible == true
        case #selector(pickLanguageMenu(_:)): item.state = (item.representedObject as? String) == tab?.doc.language.rawValue ? .on : .off
        case #selector(pickLineEndingMenu(_:)): item.state = (item.representedObject as? String) == tab?.doc.lineEnding.rawValue ? .on : .off
        case #selector(pickEncodingMenu(_:)): item.state = (item.representedObject as? String) == tab?.doc.encoding.rawValue ? .on : .off
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(showFind(_:)), #selector(showReplace(_:)),
             #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(goToLine(_:)), #selector(useSelectionForFind(_:)):
            return tab != nil
        default: return validateToolItem(item)
        }
        return true
    }
}

func trace(_ s: String) {
    if ProcessInfo.processInfo.environment["CEDRIC_TRACE"] == "1" { FileHandle.standardError.write(Data("trace: \(s)\n".utf8)) }
}
