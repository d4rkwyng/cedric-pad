import AppKit
import CedricCore

/// Find in Files (⇧⌘F): a side panel docked at the right of the selected
/// tab. The search runs on a background queue (`FileSearch`); results
/// stream into the list as `path:line: text`; clicking one opens the file
/// at that line.
@MainActor
final class FindInFilesPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let queryField = NSTextField()
    let folderField = NSTextField()
    let includeField = NSTextField()
    let excludeField = NSTextField()
    let regexBox = NSButton(checkboxWithTitle: String(localized: "Regex"), target: nil, action: nil)
    let caseBox = NSButton(checkboxWithTitle: String(localized: "Match case"), target: nil, action: nil)
    let findButton = NSButton(title: String(localized: "Find"), target: nil, action: nil)
    let stopButton = NSButton(title: String(localized: "Stop"), target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let table = NSTableView()
    private let tableScroll = NSScrollView()

    var isShown = false
    var onOpen: ((FileSearchResult) -> Void)?
    var onClose: (() -> Void)?
    private(set) var results: [FileSearchResult] = []
    private(set) var running: FileSearch?
    private(set) var lastSummary: FileSearchSummary?
    /// Called when a search finishes (the in-process check waits on it).
    var onFinished: (() -> Void)?
    private var pendingRows = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        clipsToBounds = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        s.alignment = .centerY
        return s
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Find in Files"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let close = NSButton(title: "", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))!,
                             target: self, action: #selector(closePanel))
        close.isBordered = false
        let chooser = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseFolder))
        chooser.controlSize = .small
        for f in [queryField, folderField, includeField, excludeField] {
            f.controlSize = .small
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.lineBreakMode = .byTruncatingHead
            f.cell?.isScrollable = true
            f.target = self
            f.action = #selector(startSearch)
            f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        queryField.placeholderString = String(localized: "Text or regular expression")
        includeField.placeholderString = String(localized: "All files (e.g. *.swift, *.md)")
        excludeField.stringValue = FileSearchOptions.defaultExclude.joined(separator: ", ")
        for b in [regexBox, caseBox] { b.controlSize = .small; b.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        findButton.target = self; findButton.action = #selector(startSearch)
        stopButton.target = self; stopButton.action = #selector(stopSearch)
        stopButton.isEnabled = false
        for b in [findButton, stopButton] { b.controlSize = .small; b.bezelStyle = .rounded }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let form = NSStackView(views: [
            row([title, spacer, close]),
            row([label(String(localized: "Find")), queryField]),
            row([label(""), regexBox, caseBox]),
            row([label(String(localized: "Folder")), folderField, chooser]),
            row([label(String(localized: "Include")), includeField]),
            row([label(String(localized: "Exclude")), excludeField]),
            row([label(""), findButton, stopButton, status]),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for v in form.arrangedSubviews { v.trailingAnchor.constraint(equalTo: form.trailingAnchor, constant: -8).isActive = true }

        let col = NSTableColumn(identifier: .init("result"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 18
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.borderType = .noBorder

        let stack = NSStackView(views: [form, tableScroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        tableScroll.setContentHuggingPriority(.init(1), for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    // MARK: Search

    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: (folderField.stringValue as NSString).expandingTildeInPath)
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { self?.folderField.stringValue = u.path }
        }
    }

    @objc func startSearch() {
        cancel()
        results = []
        table.reloadData()
        let path = (folderField.stringValue as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !queryField.stringValue.isEmpty else { status.stringValue = String(localized: "Type something to find."); return }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            status.stringValue = String(localized: "No such folder.")
            return
        }
        let o = FileSearchOptions(root: URL(fileURLWithPath: path), query: queryField.stringValue,
                                  regex: regexBox.state == .on, caseSensitive: caseBox.state == .on,
                                  include: FileSearchOptions.globs(includeField.stringValue),
                                  exclude: FileSearchOptions.globs(excludeField.stringValue))
        let search = FileSearch(o)
        running = search
        lastSummary = nil
        stopButton.isEnabled = true
        status.stringValue = String(localized: "Searching…")
        let me = WeakRef(self)
        search.start(batch: { b in
            MainActor.assumeIsolated {
                guard let p = me.value, p.running === search else { return }
                p.append(b)
            }
        }, done: { r in
            MainActor.assumeIsolated {
                guard let p = me.value, p.running === search else { return }
                p.finished(r)
            }
        })
    }

    @objc func stopSearch() {
        running?.cancel()
    }

    func cancel() {
        running?.cancel()
        running = nil
        stopButton.isEnabled = false
    }

    private func append(_ b: [FileSearchResult]) {
        let start = results.count
        results += b
        table.insertRows(at: IndexSet(start..<results.count), withAnimation: [])
        status.stringValue = String(localized: "Searching… \(results.count) matching lines")
    }

    private func finished(_ r: Result<FileSearchSummary, Error>) {
        running = nil
        stopButton.isEnabled = false
        switch r {
        case .success(let s):
            lastSummary = s
            var parts = [s.results == 1 ? String(localized: "1 line") : String(localized: "\(s.results) lines"),
                         String(localized: "in \(s.filesMatched) of \(s.filesSearched) files")]
            if s.truncated { parts.append(String(localized: "stopped at \(s.results)")) }
            if s.cancelled { parts.append(String(localized: "stopped")) }
            if s.skippedBinary > 0 { parts.append(String(localized: "\(s.skippedBinary) binary skipped")) }
            if s.skippedLarge > 0 { parts.append(String(localized: "\(s.skippedLarge) over 20 MB skipped")) }
            status.stringValue = parts.joined(separator: ", ")
            status.toolTip = status.stringValue
        case .failure(let e):
            if case FindEngine.FindError.invalidPattern = e {
                status.stringValue = String(localized: "Invalid regular expression")
            } else {
                status.stringValue = e.localizedDescription
            }
        }
        onFinished?()
    }

    @objc func closePanel() { onClose?() }

    @objc func rowClicked() {
        trace("find in files: clicked row \(table.clickedRow)")
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < results.count else { return }
        let result = results[r]
        // After the click finishes: opening may move this panel to another tab.
        DispatchQueue.main.async { [weak self] in self?.onOpen?(result) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let f = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = f
        } else {
            field = ResultLabel(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
        }
        field.attributedStringValue = Self.format(results[row])
        field.toolTip = "\(results[row].url.path):\(results[row].line)"
        return field
    }

    /// `path:line: text`, matches in bold on a highlight.
    static func format(_ r: FileSearchResult) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString(string: "\(r.relativePath):\(r.line): ",
                                            attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
        let text = r.text.replacingOccurrences(of: "\t", with: " ")
        let lead = text.prefix { $0 == " " }.utf16.count
        let body = NSMutableAttributedString(string: String(text.dropFirst(text.prefix { $0 == " " }.count)),
                                             attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        for range in r.ranges {
            let shifted = NSRange(location: range.location - lead, length: range.length)
            guard shifted.location >= 0, NSMaxRange(shifted) <= body.length else { continue }
            body.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.55),
                                .foregroundColor: NSColor.black], range: shifted)
        }
        out.append(body)
        return out
    }
}

/// A result row's text: clicks go to the table (one click opens the result).
final class ResultLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
