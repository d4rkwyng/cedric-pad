import AppKit
import CedricCore

/// The status bar's word count, clickable: it opens the stats popover.
/// With Full Keyboard Access on it takes keyboard focus like a button
/// (Tab to it, Space or Return opens the popover; UX review #5); View ›
/// Show Statistics opens it from the keyboard in any case.
final class CountsLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { super.mouseDown(with: event); return }
        onClick()
    }

    override var acceptsFirstResponder: Bool { onClick != nil && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override func keyDown(with event: NSEvent) {
        guard let onClick, let c = event.charactersIgnoringModifiers, [" ", "\r", "\u{3}"].contains(c) else {
            super.keyDown(with: event); return
        }
        onClick()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? super.accessibilityRole() : .button }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

/// A ring for the word goal: the share of the goal written so far.
final class GoalRingView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let c = NSPoint(x: r.midX, y: r.midY), radius = min(r.width, r.height) / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 5
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        track.stroke()
        guard progress > 0 else { return }
        let arc = NSBezierPath()
        // Clockwise from 12 o'clock.
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, progress)), clockwise: true)
        arc.lineWidth = 5
        arc.lineCapStyle = .round
        (progress >= 1 ? NSColor.systemGreen : NSColor.controlAccentColor).setStroke()
        arc.stroke()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { "\(Int((progress * 100).rounded(.down))) %" }
    override func accessibilityLabel() -> String? { String(localized: "Word goal progress") }
}

/// Click on the status bar's word count: words, characters, lines and
/// reading time of the document (and of the selection, when there is
/// one), and the file's word goal with its ring. The goal is kept in the
/// session (never in the file). Nothing is built until the first click.
@MainActor
final class StatsPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    let popover = NSPopover()
    private weak var tab: EditorWindowController?
    /// The values shown, by key ("words", "characters", "lines", "reading",
    /// and "sel.words"…): for the checks.
    private(set) var values: [String: String] = [:]
    let goalField = NSTextField()
    let ring = GoalRingView()
    let goalLabel = NSTextField(labelWithString: "")
    private var cells: [String: NSTextField] = [:]
    private let selectionHeader = NSTextField(labelWithString: String(localized: "Selection"))
    private var refreshTimer: Timer?

    init(tab: EditorWindowController) {
        self.tab = tab
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let vc = NSViewController()
        vc.view = build()
        popover.contentViewController = vc
    }

    private func label(_ s: String, bold: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize) : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        l.alignment = align
        return l
    }

    private func build() -> NSView {
        let rows: [(String, String)] = [("words", String(localized: "Words")), ("characters", String(localized: "Characters")),
                                        ("lines", String(localized: "Lines")), ("reading", String(localized: "Reading time"))]
        selectionHeader.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        selectionHeader.alignment = .right
        var gridRows: [[NSView]] = [[NSGridCell.emptyContentView, label(String(localized: "Document"), bold: true, align: .right), selectionHeader]]
        for (key, title) in rows {
            let doc = label("", align: .right), sel = label("", align: .right)
            cells[key] = doc
            cells["sel." + key] = sel
            gridRows.append([label(title), doc, sel])
        }
        let grid = NSGridView(views: gridRows)
        grid.columnSpacing = 16
        grid.rowSpacing = 4
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing

        goalField.placeholderString = String(localized: "None")
        goalField.delegate = self
        goalField.alignment = .right
        goalField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        goalField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        goalField.setAccessibilityLabel(String(localized: "Word goal"))
        goalField.toolTip = String(localized: "Kept with this window's session, never written into the file. Empty: no goal.")
        goalLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        goalLabel.textColor = .secondaryLabelColor
        let goalTitle = label(String(localized: "Word goal"), bold: true)
        let fieldRow = NSStackView(views: [goalTitle, goalField])
        fieldRow.spacing = 8
        let goalText = NSStackView(views: [fieldRow, goalLabel])
        goalText.orientation = .vertical
        goalText.alignment = .leading
        goalText.spacing = 4
        ring.setContentHuggingPriority(.required, for: .horizontal)
        let goalRow = NSStackView(views: [ring, goalText])
        goalRow.spacing = 10
        goalRow.alignment = .centerY

        let note = NSTextField(labelWithString: String(localized: "Reading time at \(ReadingTime.wordsPerMinute) words a minute."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [grid, NSBox.separator(), goalRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        return stack
    }

    func show(relativeTo view: NSView) {
        refresh()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// A moment after typing or selecting while shown.
    func scheduleRefresh() {
        guard popover.isShown else { return }
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func fmt(_ n: Int) -> String { n.formatted() }

    private func readingText(_ words: Int) -> String {
        let m = ReadingTime.minutes(words: words)
        if m == 0 { return "–" }
        if m < 60 { return String(localized: "\(m) min") }
        let h: Int = m / 60, rest: Int = m % 60
        return rest == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(rest) min")
    }

    func refresh() {
        guard let tab else { return }
        let ns = tab.textView.string as NSString
        let docCounts: TextCounts?
        if let cached = tab.editing.documentCounts {
            docCounts = cached
        } else {
            docCounts = TextStats.count(ns, range: NSRange(location: 0, length: ns.length))
            tab.editing.documentCounts = .some(docCounts)
        }
        set("", docCounts, lines: tab.lineIndex.lineCount)
        let sel = tab.textView.selectedRange()
        let hasSel = sel.length > 0
        selectionHeader.isHidden = !hasSel
        for k in ["words", "characters", "lines", "reading"] { cells["sel." + k]?.isHidden = !hasSel }
        if hasSel { set("sel.", TextStats.count(ns, range: sel), lines: nil) } else { for k in ["words", "characters", "lines", "reading"] { values["sel." + k] = nil } }
        updateGoal(words: docCounts?.words)
    }

    private func set(_ prefix: String, _ c: TextCounts?, lines: Int?) {
        let v: [String: String]
        if let c {
            v = ["words": fmt(c.words), "characters": fmt(c.characters), "lines": fmt(c.lines), "reading": readingText(c.words)]
        } else {
            // Past TextStats.maxCounted: lines only.
            v = ["words": "–", "characters": "–", "lines": lines.map(fmt) ?? "–", "reading": "–"]
        }
        for (k, s) in v {
            cells[prefix + k]?.stringValue = s
            values[prefix + k] = s
        }
    }

    private func updateGoal(words: Int?) {
        guard let tab else { return }
        let goal = tab.editing.wordGoal
        if goalField.currentEditor() == nil { goalField.stringValue = goal.map(fmt) ?? "" }
        guard let goal else {
            ring.progress = 0
            goalLabel.stringValue = String(localized: "Set a goal for this file.")
            values["goal"] = nil
            return
        }
        let w = words ?? 0
        ring.progress = WordGoal.progress(words: w, goal: goal)
        let pct: Int = WordGoal.percent(words: w, goal: goal)
        let ws: String = fmt(w), gs: String = fmt(goal)
        goalLabel.stringValue = String(localized: "\(ws) of \(gs) words (\(pct) %)")
        values["goal"] = gs
        values["goal.percent"] = "\(pct)"
    }

    /// Return or leaving the field sets the goal; empty (or 0) clears it.
    func controlTextDidEndEditing(_ obj: Notification) { commitGoal() }

    func commitGoal() {
        guard let tab else { return }
        tab.setWordGoal(WordGoal.parse(goalField.stringValue))
        refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        if tab?.editing.statsPopover === self { tab?.editing.statsPopover = nil }
    }
}

extension EditorWindowController {
    /// The status bar's counts open the stats popover (and close it again).
    func toggleStatsPopover() {
        if let p = editing.statsPopover, p.popover.isShown { p.popover.close(); return }
        let p = editing.statsPopover ?? StatsPopover(tab: self)
        editing.statsPopover = p
        p.show(relativeTo: statusBar.counts)
    }

    /// Sets (or with nil clears) this tab's word goal, and the file's in the session.
    func setWordGoal(_ goal: Int?) {
        editing.wordGoal = goal
        if let path = doc.fileURL?.path { (NSApp.delegate as? AppDelegate)?.setFileWordGoal(goal, path: path) }
        (NSApp.delegate as? AppDelegate)?.scheduleSessionSave()
    }
}

extension AppDelegate {
    /// View › Show Statistics: the word count's popover, from the keyboard.
    @objc func showStatisticsMenu(_ sender: Any?) {
        guard let tab = currentTab else { NSSound.beep(); return }
        tab.toggleStatsPopover()
    }

    func setFileWordGoal(_ goal: Int?, path: String) {
        fileWordGoals = FileWordGoals.setting(goal, for: path, in: fileWordGoals)
        scheduleSessionSave()
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}
