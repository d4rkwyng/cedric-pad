import AppKit
import CedricCore

/// The last Replace in Files, for Edit › Undo Replace in Files (kept
/// until the app quits, or until it is undone).
@MainActor
enum ReplaceInFiles {
    struct TabEdit {
        weak var tab: EditorWindowController?
        let url: URL
        let before: String
        let after: String
    }

    struct Operation {
        var diskOperation: UUID?
        var tabEdits: [TabEdit]
    }

    static var last: Operation?
    /// Where originals go before a write. The check points it at its temp folder.
    static var store = ReplaceUndoStore(root: ProcessInfo.processInfo.environment["CEDRIC_REPLACE_UNDO_DIR"].map { URL(fileURLWithPath: $0) }
        ?? ReplaceUndoStore.defaultRoot)
    static let actionName = String(localized: "Replace in Files")

    /// "a, b and 2 more".
    static func names(_ urls: [URL]) -> String {
        let n = urls.map(\.lastPathComponent)
        return n.count <= 3 ? n.joined(separator: ", ") : n.prefix(2).joined(separator: ", ") + String(localized: " and \(n.count - 2) more")
    }

    static func skippedText(_ s: [SkippedFile]) -> String {
        guard !s.isEmpty else { return "" }
        let parts = s.prefix(4).map { "\($0.relativePath) (\($0.reason.summary))" }
        return " " + String(localized: "Skipped: \(parts.joined(separator: ", "))\(s.count > 4 ? "…" : "").")
    }
}

/// Replace in Files (0.2.0): Edit › Replace in Files… (⌥⇧⌘F) opens the
/// Find in Files panel in replace mode; Edit › Undo Replace in Files puts
/// back the last operation's files (plan-0.2.0.md §2).
extension AppDelegate {
    @objc func replaceInFilesMenu(_ sender: Any?) {
        showFindInFiles(replace: true)
    }

    @objc func undoReplaceInFilesMenu(_ sender: Any?) {
        let message = undoLastReplace()
        if let p = findInFiles, p.isShown {
            p.summary.stringValue = message
            p.updateReplaceControls()
        } else if !message.isEmpty, ProcessInfo.processInfo.environment["CEDRIC_CHECK"] == nil {
            let a = NSAlert()
            a.messageText = ReplaceInFiles.actionName
            a.informativeText = message
            if let w = NSApp.keyWindow, w.attachedSheet == nil { a.beginSheetModal(for: w) } else { a.runModal() }
        }
    }

    func validateReplaceInFilesItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        // Not in a viewer tab (PDF, image…), like Find in Files.
        case #selector(replaceInFilesMenu(_:)): return currentViewerTab == nil && !tabs.isEmpty
        case #selector(undoReplaceInFilesMenu(_:)): return ReplaceInFiles.last != nil
        default: return nil
        }
    }

    /// The open text tab showing `url` (symbolic links resolved on both sides).
    func tab(showing url: URL) -> EditorWindowController? {
        let want = url.standardizedFileURL.resolvingSymlinksInPath().path
        return tabs.first { $0.doc.fileURL?.standardizedFileURL.resolvingSymlinksInPath().path == want }
    }

    /// The text of the files in `urls` that are open in a tab, by standardized path.
    func openBuffers(for urls: [URL]) -> [String: String] {
        // Tabs restored lazily from the session are built first, so none is missed.
        finishRestore()
        var out: [String: String] = [:]
        for u in urls {
            if let t = tab(showing: u) { out[u.standardizedFileURL.path] = t.text }
        }
        return out
    }

    /// Replace All on the checked matches: open tabs get one undoable edit
    /// each (not saved); the other files are written by FileReplace.apply.
    /// Returns what the panel shows.
    func applyReplace(_ plan: ReplacePlan) -> String {
        finishRestore()
        var tabEdits: [ReplaceInFiles.TabEdit] = []
        var diskFiles: [ReplaceFile] = []
        var skipped: [SkippedFile] = []
        var tabReplacements = 0
        for f in plan.files where !f.edits.isEmpty {
            guard let tab = tab(showing: f.url) else {
                if f.disk != nil { diskFiles.append(f) } else {
                    // Planned from a tab that has closed since: its file wasn't checked on disk.
                    skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .changedSincePreview))
                }
                continue
            }
            // Open now (or opened since the preview): edit the buffer, never the file behind it.
            let before = tab.text
            guard before == f.sourceText else {
                skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .changedSincePreview)); continue
            }
            guard tab.textView.isEditable, tab.tail == nil, let (span, new) = FileReplace.span(f.edits, in: before) else {
                skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .readOnlyTab)); continue
            }
            guard tab.replaceAsOneStep(span, with: new, actionName: ReplaceInFiles.actionName) else {
                skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .readOnlyTab)); continue
            }
            tab.colorizer.scheduleViewport()
            tabEdits.append(.init(tab: tab, url: f.url, before: before, after: tab.text))
            tabReplacements += f.edits.count
        }
        let report = FileReplace.apply(diskFiles, query: plan.query, root: plan.root, store: ReplaceInFiles.store)
        skipped += report.skipped
        if report.operation != nil || !tabEdits.isEmpty {
            ReplaceInFiles.last = .init(diskOperation: report.operation, tabEdits: tabEdits)
        }
        let total = report.replacements + tabReplacements
        let files = report.written.count + tabEdits.count
        var s = total == 1 ? String(localized: "Replaced 1 match in \(files) file.") : String(localized: "Replaced \(total) matches in \(files) files.")
        if !tabEdits.isEmpty {
            s += " " + String(localized: "In open tabs, not saved: \(ReplaceInFiles.names(tabEdits.map(\.url))).")
        }
        s += ReplaceInFiles.skippedText(skipped)
        trace("replace in files: \(s)")
        return s
    }

    /// Undo Replace in Files: restores the written files still holding what
    /// was written, and undoes the tab edits still on top of their tab's
    /// undo stack. Returns what to show.
    func undoLastReplace() -> String {
        guard let op = ReplaceInFiles.last else { return "" }
        ReplaceInFiles.last = nil
        var restored: [URL] = []
        var skipped: [SkippedFile] = []
        if let id = op.diskOperation {
            let r = ReplaceInFiles.store.undo(id)
            restored += r.restored
            skipped += r.skipped
        }
        for e in op.tabEdits {
            func skip() { skipped.append(SkippedFile(url: e.url, relativePath: e.url.lastPathComponent, reason: .changedSinceReplace)) }
            guard let tab = e.tab, tabs.contains(where: { $0 === tab }), let um = tab.textView.undoManager else { skip(); continue }
            // Only our own edit, still the last thing done in that tab.
            guard tab.text == e.after, um.canUndo, um.undoActionName == ReplaceInFiles.actionName else { skip(); continue }
            um.undo()
            if tab.text == e.before { restored.append(e.url) } else { skip() }
        }
        var s = restored.count == 1 ? String(localized: "Undid Replace in Files in 1 file.")
            : String(localized: "Undid Replace in Files in \(restored.count) files.")
        s += ReplaceInFiles.skippedText(skipped)
        trace("replace in files: \(s)")
        return s
    }
}
