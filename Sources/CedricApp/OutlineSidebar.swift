import AppKit
import CedricCore

/// The outline of a Markdown document (View › Show Outline, ⌃⌘O): its
/// headings, indented by level, at the left of the editor. A click jumps
/// to the heading; the heading the caret is under is selected; the filter
/// field narrows the list (Edit › Go to Heading…, ⇧⌘J, opens the outline
/// with the field focused: type, ↑/↓, Return). Built the first time it is
/// shown; refreshed off the main thread when typing pauses (in large mode
/// only when it is opened, and at most `largeLimit` headings).
@MainActor
final class OutlineSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let width: CGFloat = 220
    static let largeLimit = 5_000
    let field = NSSearchField()
    let table = NSTableView()
    let scroll = NSScrollView()
    let note = NSTextField(labelWithString: String(localized: "No headings"))
    private(set) var headings: [MarkdownOutline.Heading] = []
    /// Rows shown (indexes into `headings`) after the filter.
    private(set) var rows: [Int] = []
    private var settingSelection = false
    var onJump: ((MarkdownOutline.Heading) -> Void)?
    /// Esc in the field, or Return after a jump: back to the text.
    var onDone: (() -> Void)?
    private var textColor = NSColor.textColor
    private var dimColor = NSColor.secondaryLabelColor
    /// Rebuilds applied (the checks wait for one).
    private(set) var builds = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        field.placeholderString = String(localized: "Filter Headings")
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        let col = NSTableColumn(identifier: .init("h"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 20
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        addSubview(field)
        addSubview(scroll)
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: 22)
        scroll.frame = NSRect(x: 0, y: 34, width: bounds.width - 1, height: max(0, bounds.height - 34))
        table.tableColumns.first?.width = scroll.contentSize.width
        note.sizeToFit()
        note.frame.origin = NSPoint(x: 10, y: 40)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A hairline at the right edge, against the gutter. (Clipped to bounds.)
        let r = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).intersection(dirtyRect).intersection(bounds)
        dimColor.withAlphaComponent(0.25).setFill()
        r.fill()
    }

    func applyPalette(_ p: EditorPalette) {
        layer?.backgroundColor = NSColor(hex: p.gutterBackground).cgColor
        textColor = NSColor(hex: p.foreground)
        dimColor = NSColor(hex: p.gutterForeground)
        note.textColor = dimColor
        table.reloadData()
        needsDisplay = true
    }

    func setHeadings(_ h: [MarkdownOutline.Heading]) {
        headings = h
        builds += 1
        refilter()
    }

    private func refilter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        rows = q.isEmpty ? Array(headings.indices)
            : headings.indices.filter { headings[$0].title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        note.isHidden = !rows.isEmpty
        note.stringValue = headings.isEmpty ? String(localized: "No headings") : String(localized: "No matching headings")
        needsLayout = true
        table.reloadData()
    }

    /// Selects heading `index` (the caret is under it), without jumping.
    func setCurrent(_ index: Int?) {
        guard let index, let row = rows.firstIndex(of: index) else {
            if field.stringValue.isEmpty { settingSelection = true; table.deselectAll(nil); settingSelection = false }
            return
        }
        guard table.selectedRow != row else { return }
        settingSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        settingSelection = false
    }

    var selectedHeading: MarkdownOutline.Heading? {
        let r = table.selectedRow
        return r >= 0 && r < rows.count ? headings[rows[r]] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let h = headings[rows[row]]
        let cell = tableView.makeView(withIdentifier: .init("hc"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("hc")
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            c.addSubview(t)
            c.textField = t
            return c
        }()
        let indent = CGFloat(min(h.level, 6) - 1) * 12 + 8
        cell.textField?.frame = NSRect(x: indent, y: 2, width: max(10, tableView.bounds.width - indent - 4), height: 16)
        cell.textField?.autoresizingMask = [.width]
        cell.textField?.stringValue = h.title.isEmpty ? " " : h.title
        cell.textField?.font = .systemFont(ofSize: 12, weight: h.level <= 2 ? .semibold : .regular)
        cell.textField?.textColor = h.level <= 2 ? textColor : textColor.withAlphaComponent(0.85)
        cell.toolTip = h.title
        return cell
    }

    /// A row the user selected (click, or arrows in the list): jump there.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection, let h = selectedHeading else { return }
        lastJump = Date()
        onJump?(h)
    }

    private var lastJump = Date.distantPast

    @objc private func clicked(_ sender: Any?) {
        // A click on the row already selected (no selection change).
        guard Date().timeIntervalSince(lastJump) > 0.3 else { return }
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        onJump?(headings[rows[table.clickedRow]])
    }

    // The filter field: typing filters, ↑/↓ move, Return jumps, Esc is done.
    func controlTextDidChange(_ obj: Notification) {
        refilter()
        if !rows.isEmpty { settingSelection = true; table.selectRowIndexes([0], byExtendingSelection: false); settingSelection = false }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let r = table.selectedRow
            let next = sel == #selector(NSResponder.moveDown(_:)) ? min(rows.count - 1, r + 1) : max(0, r - 1)
            settingSelection = true
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            settingSelection = false
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let h = selectedHeading ?? rows.first.map({ headings[$0] }) { onJump?(h) }
            onDone?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDone?()
            return true
        default:
            return false
        }
    }
}

/// The outline's per-tab state (EditorWindowController.outline).
@MainActor
final class OutlineState {
    var sidebar: OutlineSidebar?
    var visible: Bool { sidebar?.superview != nil }
    /// Shown by Go to Heading only: hidden again when it is done.
    var transient = false
    var timer: Timer?
    let ticket = RenderTicket()
    var generation = 0
    private static let queue = DispatchQueue(label: "cedric.outline", qos: .userInitiated)

    /// Rebuilds the list from `text` off the main thread.
    func rebuild(_ text: String, large: Bool, then: @escaping @MainActor () -> Void) {
        generation += 1
        let gen = generation
        ticket.set(gen)
        let ticket = ticket
        let limit = large ? OutlineSidebar.largeLimit : .max
        Self.queue.async {
            guard ticket.value == gen else { return }
            let h = MarkdownOutline.headings(in: text, limit: limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation, let s = self.sidebar else { return }
                    s.setHeadings(h)
                    then()
                }
            }
        }
    }
}

extension EditorWindowController {
    var outlineVisible: Bool { outline.visible }

    /// View › Show Outline (⌃⌘O).
    func toggleOutline() {
        if outline.visible { hideOutline(); return }
        guard doc.language == .markdown else { NSSound.beep(); return }
        showOutline()
        outline.transient = false
    }

    private func showOutline() {
        let s = outline.sidebar ?? makeOutlineSidebar()
        s.applyPalette(palette)
        editorContainer.sidebar = s
        refreshOutline()
    }

    func hideOutline() {
        outline.timer?.invalidate()
        editorContainer.sidebar = nil
        outline.transient = false
        if window?.firstResponder === outline.sidebar?.field.currentEditor() { window?.makeFirstResponder(textView) }
    }

    /// Edit › Go to Heading… (⇧⌘J): the outline, with its filter focused.
    func goToHeading() {
        guard doc.language == .markdown else { NSSound.beep(); return }
        if !outline.visible {
            showOutline()
            outline.transient = true
        }
        guard let s = outline.sidebar else { return }
        s.field.stringValue = ""
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        updateOutlineCurrent()
        window?.makeFirstResponder(s.field)
    }

    private func makeOutlineSidebar() -> OutlineSidebar {
        let s = OutlineSidebar(frame: .zero)
        s.onJump = { [weak self] h in self?.jump(to: h) }
        s.onDone = { [weak self] in
            guard let self else { return }
            if self.outline.transient { self.hideOutline() }
            self.window?.makeFirstResponder(self.textView)
        }
        outline.sidebar = s
        return s
    }

    private func jump(to h: MarkdownOutline.Heading) {
        let l = max(0, min(h.line, lineIndex.lineCount - 1))
        textView.setSelectedRange(NSRange(location: lineIndex.starts[l], length: 0))
        scrollToLine(max(0, l - 2))
        window?.makeFirstResponder(textView)
        if outline.transient { hideOutline() }
    }

    func refreshOutline() {
        guard outline.visible else { return }
        outline.rebuild(textView.string, large: extrasPaused) { [weak self] in self?.updateOutlineCurrent() }
    }

    /// The text changed: rebuild when typing pauses (not in large mode).
    func outlineTextChanged() {
        guard outline.visible else { return }
        if doc.language != .markdown { hideOutline(); return }
        guard !extrasPaused else { return }
        outline.timer?.invalidate()
        outline.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOutline() }
        }
    }

    /// The caret moved: select the heading it is under.
    func updateOutlineCurrent() {
        guard outline.visible, let s = outline.sidebar, lineIndex.lineCount > 0 else { return }
        let line = lineIndex.line(containing: min(textView.selectedRange().location, lineIndex.length))
        s.setCurrent(MarkdownOutline.current(s.headings, line: line))
    }
}
