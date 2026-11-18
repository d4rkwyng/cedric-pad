import AppKit
import CedricCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var tabs: [EditorWindowController] = []
    let store = SessionStore(directory: SessionStore.defaultDirectory())
    private let env = ProcessInfo.processInfo.environment
    private var sessionTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    /// Files handed over before launch finished (Finder, `open`).
    private var pendingOpen: [URL] = []
    private var launched = false
    /// Open Recent rebuild queued (EditorTools.swift).
    var recentRebuildScheduled = false
    /// Set once quitting: windows closed by termination keep their buffers.
    private var terminating = false
    /// File › Reopen Closed Tab (ClosedTabs.swift): closed tabs, newest
    /// last, saved with the session; their unsaved text stays in their
    /// buffer files. `closedTexts` holds the text in memory instead when
    /// session saving is off (the checks).
    var closedTabs: [SessionTab] = []
    var closedTexts: [UUID: String] = [:]

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("will_finish")
        NSWindow.allowsAutomaticWindowTabbing = true
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("did_finish")
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil) }
        }
        // The owl hub listens for View › Show Cedric the Owl; it must exist
        // before the first toggle (it was created lazily, so with the owl
        // off and only untitled tabs the menu item did nothing). Not needed
        // for the first frame (a tab with the owl on creates it at once).
        AfterFirstFrame.run { _ = OwlHub.shared }
        if env["CEDRIC_NO_RESTORE"] != "1" { restoreSession() }
        LaunchTrace.mark("restored")
        var toOpen = pendingOpen
        if let list = env["CEDRIC_OPEN"], !list.isEmpty {
            toOpen += list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        for url in toOpen { open(url) }
        pendingOpen = []
        if tabs.isEmpty { newTab(nil) }
        schedulePendingRestore()
        LaunchTrace.mark("tabs_ready")
        recentMenu?.delegate = self
        scheduleRecentMenuRebuild()
        launched = true
        DevHooks.afterLaunch(self)
        LaunchTrace.afterLaunch(self)
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
        releaseAllWaiters()
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
                doc.languageChoice = .forFile(named: url.lastPathComponent, content: "")
                let tab = makeTab(doc, text: "")
                doc.markDirtyFromSession()
                tab.updateTitle()
            }
            let tab = tabs.first { $0.doc.fileURL?.standardizedFileURL == url.standardizedFileURL }
            if let line = q["line"].flatMap(Int.init) { tab?.goToLine(line, column: q["col"].flatMap(Int.init) ?? 1) }
            // `cedric -w`: the script waits until this marker file goes.
            if let marker = q["wait"], let tab { addWaiter(marker, for: tab) }
        } else if let tmp = q["untitled"], tmp.hasPrefix(NSTemporaryDirectory()) || tmp.hasPrefix("/tmp/") || tmp.hasPrefix("/private/") {
            let url = URL(fileURLWithPath: tmp)
            if let (d, _) = try? EditorDocument.read(url) {
                let doc = newDocument()
                doc.apply(d)
                doc.languageChoice = .untitled(content: d.text)
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
        // The lowest free number among the untitled tabs open now (not a
        // counter that only grows: that gave "Untitled 3" with none open).
        let open = tabs.filter { $0.doc.fileURL == nil }.map(\.doc.untitledName)
        let name = UntitledNames.next(open: open, base: String(localized: "Untitled"))
        return EditorDocument(untitledName: name)
    }

    @discardableResult
    func makeTab(_ doc: EditorDocument, text: String, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true,
                 tabIndex: Int? = nil) -> EditorWindowController {
        let tab = EditorWindowController(doc: doc, text: text)
        tab.onChange = { [weak self] _ in self?.scheduleSessionSave() }
        tab.onClose = { [weak self] t in
            self?.releaseWaiters(for: t.doc.id)
            guard let self, !self.terminating else { return }
            self.tabs.removeAll { $0 === t }
            // Hot close: remembered for Reopen Closed Tab, unsaved text and all.
            self.rememberClosed(t)
        }
        tabs.append(tab)
        guard let window = tab.window else { return tab }
        let host = newWindow ? nil : group ?? NSApp.keyWindow ?? tabs.dropLast().last?.window
        if let tabIndex, let host = group, host !== window, let tg = host.tabGroup {
            // A restored tab built after launch: its saved place in the tab bar.
            tg.insertWindow(window, at: min(tabIndex, tg.windows.count))
        } else if let host, host !== window, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        PerfTrace.mark("tab_built")
        if show { window.makeKeyAndOrderFront(nil) }
        PerfTrace.mark("order_front")
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
        restorePendingTab(for: std)
        if let existing = tabs.first(where: { $0.doc.fileURL?.standardizedFileURL == std }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        do {
            let (d, mod) = try EditorDocument.read(std)
            let doc = EditorDocument(fileURL: std, untitledName: std.lastPathComponent)
            doc.apply(d)
            doc.fileModified = mod
            PerfTrace.mark("read_decode")
            doc.languageChoice = .forFile(named: std.lastPathComponent, content: d.text)
            PerfTrace.mark("detect_language")
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
            MainActor.assumeIsolated { self?.saveSession(sync: false) }
        }
    }

    /// The windows in on-screen order, each with its tabs in tab-bar order.
    func tabGroups() -> [[EditorWindowController]] {
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

    /// Session writes, in order, off the main thread (a 636 KB unsaved
    /// buffer is a few ms of disk work); quit waits for them.
    let sessionQueue = DispatchQueue(label: "cedric.session-save", qos: .utility)

    /// Snapshots the tabs on the main thread, then writes the changed
    /// buffers, the session and the prune on `sessionQueue`, in that order.
    /// `sync`: wait for it (quit).
    func saveSession(sync: Bool = true) {
        sessionTimer?.invalidate()
        guard env["CEDRIC_NO_SESSION_SAVE"] != "1" else { return }
        // Tabs not built yet would be dropped from the session (and their buffers pruned).
        finishRestore()
        var windows: [SessionWindow] = []
        var keep = Set<UUID>()
        var buffers: [(UUID, String)] = []
        for group in tabGroups() {
            var sessionTabs: [SessionTab] = []
            var selected = 0
            for (i, t) in group.enumerated() {
                let d = t.doc
                let isEmpty = (t.textView.textStorage?.length ?? 0) == 0
                let needsBuffer = d.isDirty || d.fileURL == nil && !isEmpty
                if needsBuffer {
                    keep.insert(d.id)
                    if d.sessionChangeCount != d.changeCount {
                        // One copy of the text (the storage keeps changing).
                        buffers.append((d.id, t.text))
                        d.sessionChangeCount = d.changeCount
                    }
                } else {
                    d.sessionChangeCount = -1
                }
                // An untouched empty untitled tab isn't worth restoring.
                if d.fileURL == nil && isEmpty { continue }
                let sel = t.textView.selectedRange()
                sessionTabs.append(SessionTab(id: d.id, path: d.fileURL?.path, untitledName: d.fileURL == nil ? d.untitledName : nil,
                                              hasBuffer: needsBuffer, encoding: d.encoding, lineEnding: d.lineEnding,
                                              language: d.languageIsManual ? d.language : nil,
                                              selectionLocation: sel.location, selectionLength: sel.length,
                                              topLine: t.topLine, fileModified: d.fileModified,
                                              bookmarks: t.editing.bookmarks.isEmpty ? nil : t.editing.bookmarks.lines,
                                              indentation: d.indentation))
                if t.window === NSApp.keyWindow || t.window?.tabGroup?.selectedWindow === t.window { selected = sessionTabs.count - 1 }
            }
            if !sessionTabs.isEmpty {
                windows.append(SessionWindow(tabs: sessionTabs, selectedTab: selected, frame: group.first?.window?.frameDescriptor))
            }
        }
        for c in closedTabs where c.hasBuffer { keep.insert(c.id) }
        let session = Session(windows: windows, closedTabs: closedTabs.isEmpty ? nil : closedTabs)
        let store = self.store
        let toWrite = buffers, keeping = keep
        let write: @Sendable () -> Void = {
            for (id, text) in toWrite {
                do { try store.writeBuffer(id, text: text) } catch {
                    FileHandle.standardError.write(Data("session: buffer write failed: \(error)\n".utf8))
                }
            }
            do {
                try store.save(session)
                store.pruneBuffers(keeping: keeping)
            } catch {
                FileHandle.standardError.write(Data("session: save failed: \(error)\n".utf8))
            }
        }
        if sync { sessionQueue.sync(execute: write) } else { sessionQueue.async(execute: write) }
    }

    /// A restored tab not built yet: each window's selected tab is built
    /// during launch; the others are built after the first frame, one per
    /// run-loop turn (`restoreNextPending`), so a long session neither
    /// delays the window nor blocks the first keystrokes for long. Adding a
    /// window to a tab group costs AppKit ~10 ms per tab (~45 ms for the
    /// first, which creates the tab bar), whatever the tab holds.
    private struct PendingTab {
        let tab: SessionTab
        let group: RestoreGroup
        /// Its place in the saved window's tab bar.
        let index: Int
    }

    /// One saved window's tabs built so far, by their saved index.
    private final class RestoreGroup {
        var built: [(index: Int, window: NSWindow)] = []
    }

    private var pendingRestore: [PendingTab] = []
    /// Seconds after the first frame before the other tabs are built (about
    /// a human reaction time, so a keystroke right after the window shows
    /// doesn't wait behind them). CEDRIC_RESTORE_DELAY overrides it (session-check).
    static let pendingRestoreDelay: TimeInterval =
        ProcessInfo.processInfo.environment["CEDRIC_RESTORE_DELAY"].flatMap(Double.init) ?? 0.25

    private func restoreSession() {
        guard let session = store.load() else { return }
        closedTabs = session.closedTabs ?? []
        for w in session.windows {
            // The selected tab first (it is what shows); if its file has
            // gone, the next one that still restores.
            let order = w.tabs.indices.contains(w.selectedTab)
                ? [w.selectedTab] + w.tabs.indices.filter { $0 != w.selectedTab } : Array(w.tabs.indices)
            let group = RestoreGroup()
            var host: NSWindow?
            var rest: [Int] = []
            for i in order {
                if host != nil { rest.append(i); continue }
                guard let tab = restoreTab(w.tabs[i], into: nil), let window = tab.window else { continue }
                host = window
                group.built.append((i, window))
                if let f = w.frame { window.setFrame(from: f) }
            }
            guard let host else { continue }
            pendingRestore += rest.sorted().map { PendingTab(tab: w.tabs[$0], group: group, index: $0) }
            host.makeKeyAndOrderFront(nil)
        }
    }

    /// Builds one saved tab; nil if its file has gone and it had no buffer.
    /// `place` nil: in a new window (not ordered in). Else into that
    /// window's tab group at that position.
    @discardableResult
    private func restoreTab(_ st: SessionTab, into place: (host: NSWindow, index: Int)?) -> EditorWindowController? {
        let doc = EditorDocument(id: st.id, fileURL: st.path.map { URL(fileURLWithPath: $0) },
                                 untitledName: st.untitledName ?? st.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Untitled"))
        doc.indentation = st.indentation
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
        guard let body = text else { return nil } // the file is gone and there was no buffer
        if let l = st.language {
            doc.languageChoice.choose(l)
        } else if let url = doc.fileURL {
            doc.languageChoice = .forFile(named: url.lastPathComponent, content: body)
        } else {
            doc.languageChoice = .untitled(content: body)
        }
        let tab = makeTab(doc, text: body, in: place?.host, newWindow: place == nil, show: false, tabIndex: place?.index)
        if st.hasBuffer { doc.markDirtyFromSession(); doc.sessionChangeCount = doc.changeCount }
        tab.updateTitle()
        let len = (body as NSString).length
        tab.textView.setSelectedRange(NSRange(location: min(st.selectionLocation, len), length: min(st.selectionLength, max(0, len - st.selectionLocation))))
        if let marks = st.bookmarks {
            tab.editing.bookmarks = Bookmarks(marks)
            tab.editing.bookmarks.clamp(lineCount: tab.lineIndex.lineCount)
        }
        let top = st.topLine
        DispatchQueue.main.async { tab.scrollToLine(top) }
        return tab
    }

    /// Starts building the pending tabs once the first frame is on screen.
    private func schedulePendingRestore() {
        guard !pendingRestore.isEmpty else { return }
        AfterFirstFrame.run {
            Timer.scheduledTimer(withTimeInterval: Self.pendingRestoreDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreNextPending() }
            }
        }
    }

    /// One pending tab per run-loop turn (key events get through in between).
    private func restoreNextPending() {
        guard !pendingRestore.isEmpty else { return }
        restorePending(pendingRestore.removeFirst())
        if pendingRestore.isEmpty { scheduleSessionSave(); return }
        perform(#selector(restoreNextPendingLater), with: nil, afterDelay: 0)
    }

    @objc private func restoreNextPendingLater() { restoreNextPending() }

    private func restorePending(_ p: PendingTab) {
        // The saved window's tabs still open (the user may have closed some).
        let live = p.group.built.filter { b in tabs.contains { $0.window === b.window } }
        guard let anchor = live.first?.window, let tg = anchor.tabGroup else {
            // All of them closed before this one was built: it gets its own window.
            if let tab = restoreTab(p.tab, into: nil), let w = tab.window {
                p.group.built.append((p.index, w))
                w.orderFront(nil)
            }
            return
        }
        // After the nearest tab saved before it, else first.
        let before = live.filter { $0.index < p.index }.max { $0.index < $1.index }
        let position = before.flatMap { b in tg.windows.firstIndex { $0 === b.window } }.map { $0 + 1 } ?? 0
        // Keep the user where they are: building a tab must not move the selection.
        let selected = tg.selectedWindow
        if let tab = restoreTab(p.tab, into: (anchor, position)), let w = tab.window { p.group.built.append((p.index, w)) }
        if let selected, tg.selectedWindow !== selected { tg.selectedWindow = selected }
    }

    /// Builds every pending tab now (save, quit, open, the dev hooks).
    func finishRestore() {
        while !pendingRestore.isEmpty { restorePending(pendingRestore.removeFirst()) }
    }

    /// A pending tab for this file, built now so it isn't opened twice.
    private func restorePendingTab(for url: URL) {
        let std = url.standardizedFileURL
        guard let i = pendingRestore.firstIndex(where: { $0.tab.path.map { URL(fileURLWithPath: $0).standardizedFileURL } == std }) else { return }
        restorePending(pendingRestore.remove(at: i))
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
    @objc func toggleSpellingWhileTyping(_ sender: Any?) { Settings.shared.checkSpellingWhileTyping.toggle() }
    @objc func checkDocumentNow(_ sender: Any?) { currentTab?.spelling.selectNext() }
    @objc func fixTyposMenu(_ sender: Any?) { currentTab?.startSpellStep() }
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
        if let raw = sender.representedObject as? String, let l = Language(rawValue: raw) { currentTab?.setLanguage(l) }
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
        case #selector(toggleSpellingWhileTyping(_:)): item.state = s.checkSpellingWhileTyping ? .on : .off
        case #selector(checkDocumentNow(_:)), #selector(fixTyposMenu(_:)): return tab != nil
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
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(showFind(_:)), #selector(showReplace(_:)),
             #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(goToLine(_:)), #selector(useSelectionForFind(_:)),
             #selector(printDocument(_:)):
            return tab != nil
        default: return validateEditingItem(item) ?? validateIndentationItem(item) ?? validateFileItem(item) ?? validateFilterItem(item) ?? validateToolItem(item)
        }
        return true
    }
}

func trace(_ s: String) {
    if ProcessInfo.processInfo.environment["CEDRIC_TRACE"] == "1" { FileHandle.standardError.write(Data("trace: \(s)\n".utf8)) }
}
