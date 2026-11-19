import AppKit
import CedricCore

/// Holds the gutter beside the scroll view.
final class EditorContainer: NSView {
    let gutter: GutterView
    let scrollView: NSScrollView
    var gutterWidth: CGFloat = 40 { didSet { needsLayout = true } }
    /// The owl's layer over the editor (nil while the owl is off).
    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay) }
            needsLayout = true
        }
    }
    var showsGutter = true { didSet { gutter.isHidden = !showsGutter; needsLayout = true } }
    /// The outline at the left (nil while it is hidden).
    var sidebar: NSView? {
        didSet {
            guard oldValue !== sidebar else { return }
            oldValue?.removeFromSuperview()
            if let sidebar { addSubview(sidebar) }
            needsLayout = true
        }
    }

    init(gutter: GutterView, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let side = sidebar == nil ? 0 : min(OutlineSidebar.width, max(0, bounds.width - 200))
        sidebar?.frame = NSRect(x: 0, y: 0, width: side, height: bounds.height)
        let g = showsGutter ? gutterWidth : 0
        gutter.frame = NSRect(x: side, y: 0, width: g, height: bounds.height)
        scrollView.frame = NSRect(x: side + g, y: 0, width: bounds.width - g - side, height: bounds.height)
        if let overlay {
            // Over the text area, clear of the scrollers.
            scrollView.layoutSubtreeIfNeeded()
            overlay.frame = scrollView.convert(scrollView.contentView.frame, to: self)
        }
    }
}

/// One tab: a window (grouped with others by native window tabbing) with
/// the editor, line numbers, the optional preview, the find bar and the
/// status bar, for one `EditorDocument`.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSSplitViewDelegate {
    let doc: EditorDocument
    let textView = EditorTextView.make()
    let scrollView = NSScrollView()
    let gutter = GutterView()
    private(set) var lineIndex = LineIndex()
    private(set) var colorizer: SyntaxColorizer!
    /// Built the first time it is used (an NSSearchField and its row cost
    /// ~5 ms of every tab's launch otherwise).
    private(set) lazy var findBar: FindBar = makeFindBar()
    /// Whether the find bar exists and shows (without building it).
    var isFindBarOpen: Bool { findBarBuilt && !findBar.isHidden }
    private var findBarBuilt = false
    private(set) var stack: NSStackView!
    let statusBar = StatusBar()
    let split = PaneSplitView()
    private var container: EditorContainer!
    /// The gutter and text: the pane in `split` the side panels dock around.
    var editorArea: NSView { container }
    /// The preview with its header, docked in `split` or in `previewWindow`.
    private(set) var previewPane: PreviewPane?
    /// The web preview (Markdown, HTML), for its JavaScript and network switches.
    var preview: PreviewController? { previewPane?.renderer as? PreviewController }
    /// The detached preview's window (View › Detach Preview).
    private(set) var previewWindow: PreviewWindowController?
    var previewDetached: Bool { previewWindow != nil }
    /// Shown: detached, or docked in this tab's split. By identity, not by
    /// counting the split's panes: Find in Files and the folder sidebar
    /// dock there too.
    var previewVisible: Bool {
        guard let pane = previewPane else { return false }
        return previewDetached || pane.superview === split
    }
    private var previewTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// While loading text, edits aren't user changes.
    private var loading = false
    var onChange: ((EditorWindowController) -> Void)?
    var onClose: ((EditorWindowController) -> Void)?
    /// Cedric the owl, while View › Show Cedric the Owl is on.
    private(set) var owl: OwlController?
    /// Ask Cedric's panel, made on first use (OwlChatPanel.swift).
    private(set) var owlChat: OwlChatPanel?
    func chatPanel() -> OwlChatPanel {
        if let p = owlChat { return p }
        let p = OwlChatPanel(tab: self)
        owlChat = p
        return p
    }
    /// Spell checking in scope (Spelling.swift).
    private(set) lazy var spelling = EditorSpelling(tab: self)
    /// Fix Typos… while its panel is open (SpellStepPanel.swift).
    var spellStep: SpellStepController?
    /// Grammar in prose (Grammar.swift), and Fix Grammar… while its panel is open.
    private(set) lazy var grammar: EditorGrammar = {
        let g = EditorGrammar(tab: self)
        textView.grammar = g
        return g
    }()
    var grammarStep: GrammarStepController?
    /// View › Follow File (EditorTools.swift).
    var tail: FileTail?
    /// Large mode (LargeDocumentMode.swift): why, and "Turn On Anyway".
    var largeReason: LargeDocument.Reason?
    var largeOverride = false
    /// An edit made the document large; applied on the next turn.
    var largePending = false
    var isLargeDocument: Bool { largeReason != nil }
    let largeBar = LargeDocumentBar()
    /// A file that looks binary (BinaryFile.swift): nil for text.
    var binary: BinaryFileState?
    /// Its bar, built only for such a file.
    var binaryBar: BinaryFileBar?
    /// "Changed on disk — Reload / Keep Mine" (DiskChange.swift), built when first needed.
    var diskBar: NoticeBar?
    /// A one-off notice in this tab (the closed-tab "not saved" notice).
    var noticeBar: NoticeBar?
    /// Highlight-all, marks, bookmarks and the other editing extras
    /// (EditingFeatures.swift).
    let editing = EditingState()
    /// Branch, change bars and GitHub links (GitIntegration.swift); made
    /// after the first frame, for files only.
    var gitState: GitTabState?
    /// Which lines are in fenced code, for the Markdown editing keys
    /// (cached per line start; dropped from an edited line down).
    let fences = FenceIndex()
    /// The Markdown outline sidebar (OutlineSidebar.swift).
    let outline = OutlineState()
    var editorContainer: EditorContainer { container }
    /// Code folding (Folding.swift): nil until the first fold.
    var folding: FoldingController?
    /// How long the last Fold All / Fold to Level took (the folding check logs it).
    var lastFoldAllMs: Double = 0

    init(doc: EditorDocument, text: String) {
        self.doc = doc
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "CedricEditor"
        window.minSize = NSSize(width: 420, height: 240)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        buildViews()
        PerfTrace.mark("build_views")
        colorizer = SyntaxColorizer(textView: textView, language: doc.language)
        textView.language = doc.language
        // [weak self] everywhere a view keeps a closure: AppKit can keep a
        // closed tab's window and views alive (and drawing) after this
        // controller is gone, and an unowned self there aborted the app.
        colorizer.lineIndexProvider = { [weak self] in self?.lineIndex ?? LineIndex() }
        textView.contentStorage?.lineRange = { [weak self] offset in
            guard let self else { return nil }
            let index = self.lineIndex
            guard index.length == self.textView.textStorage?.length else { return nil }
            let line = index.line(containing: offset)
            return NSRange(location: index.starts[line], length: index.lineLength(line))
        }
        setText(text)
        applyAppearance()
        PerfTrace.mark("apply_appearance")
        observe()
        updateTitle()
        setOwlVisible(Settings.shared.showOwl)
        PerfTrace.mark("owl")
        AfterFirstFrame.run { [weak self] in self?.gitTabShown() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Views

    private func buildViews() {
        guard let window else { return }
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        textView.delegate = self
        textView.onCutLine = { [weak self] in self?.cutLine() }
        textView.indentation = { [weak self] in self?.indentation ?? Settings.shared.defaultIndentation }
        textView.onShiftLines = { [weak self] right in self?.shiftLines(right: right) }
        textView.tabInsertsSpaces = { [weak self] in self?.tabKeyInsertsSpaces ?? false }
        textView.onEdit = { [weak self] e, name in self?.apply(e, actionName: name) }
        textView.inFence = { [weak self] offset in
            guard let self else { return false }
            let index = self.lineIndex
            guard index.length == self.textView.textStorage?.length else { return false }
            return self.fences.isInFence(self.textView.string as NSString, index: index, line: index.line(containing: offset))
        }
        textView.onImages = { [weak self] files, bitmap, at in self?.insertImages(files, bitmap: bitmap, at: at) }
        textView.onDropFiles = { urls in FileDrop.open(urls) }
        textView.lineStartFor = { [weak self] offset in
            guard let index = self?.lineIndex, index.lineCount > 0 else { return 0 }
            return index.starts[index.line(containing: offset)]
        }
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        gutter.textView = textView
        gutter.clipsToBounds = true
        gutter.lineIndex = { [weak self] in self?.lineIndex ?? LineIndex() }
        gutter.bookmarks = { [weak self] in self?.editing.bookmarks ?? Bookmarks() }
        gutter.onClickLine = { [weak self] line in self?.toggleBookmark(line: line) }
        gutter.onClickFold = { [weak self] line in self?.toggleFold(line: line) ?? false }
        gutter.foldMarks = { [weak self] hovering in self?.foldMarks(hovering: hovering) }
        gutter.gitChanges = { [weak self] in
            guard let git = self?.gitState, git.showsGutter else { return nil }
            return git.changes
        }
        container = EditorContainer(gutter: gutter, scrollView: scrollView)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(container)

        largeBar.isHidden = true
        largeBar.onTurnOn = { [weak self] in self?.turnOnExtras() }
        let stack = FileDropStackView(views: [largeBar, split, statusBar])
        // A file or folder dropped beside the text (gutter, status bar) opens too.
        stack.onDropFiles = { urls in FileDrop.open(urls) }
        stack.acceptFileDrops()
        self.stack = stack
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.detachesHiddenViews = true
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        split.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        configureStatusBar()
    }

    private func makeFindBar() -> FindBar {
        let findBar = FindBar()
        findBar.isHidden = true
        findBar.onChange = { [weak self] in self?.findChanged() }
        findBar.onFind = { [weak self] back in self?.find(backwards: back) }
        findBar.onReplace = { [weak self] in self?.replaceOne() }
        findBar.onReplaceAll = { [weak self] in self?.replaceAll() }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        // Between the large-document bar and the editor.
        stack.insertArrangedSubview(findBar, at: 1)
        findBarBuilt = true
        return findBar
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil) { [weak self] n in
            MainActor.assumeIsolated { self?.storageEdited() }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        scrollView.postsFrameChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAnchor() }
        })
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // TextKit 2 re-estimates heights as it lays out, which resizes
                // the text view and would slide a different line under the
                // same scroll offset: keep the top line where it was.
                self?.keepAnchor()
                self?.gutter.needsDisplay = true
                self?.colorizer.scheduleViewport()
            }
        })
        observers.append(nc.addObserver(forName: .cedricAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        })
        observers.append(nc.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: .main) { _ in
            FileHandle.standardError.write(Data("warning: text view fell back to TextKit 1\n".utf8))
        })
    }

    // MARK: Text

    /// Replaces the whole text (open, reload, restore): not a user edit.
    func setText(_ text: String) {
        loading = true
        doc.detectedIndentation = nil
        // Large mode first, so TextKit never lays out a huge line whole.
        applyLargeMode(LargeDocument.reason(for: LineIndex(text as NSString)), newText: true)
        PerfTrace.mark("large_check")
        let attrs = baseAttributes()
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        storage.endEditing()
        PerfTrace.mark("set_text_storage")
        lineIndex = LineIndex(storage.string as NSString)
        fences.invalidateAll()
        folding?.reset()
        PerfTrace.mark("line_index")
        editing.bookmarks.clamp(lineCount: lineIndex.lineCount)
        textView.typingAttributes = attrs
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        loading = false
        updateGutterWidth()
        colorizer.recolorAll()
        PerfTrace.mark("recolor_all")
        updateStatus()
        PerfTrace.mark("status")
        gitState?.scheduleRefresh()
    }

    var text: String { textView.string }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let font = Settings.shared.font
        let para = NSMutableParagraphStyle()
        let space = (String(repeating: " ", count: tabWidth) as NSString).size(withAttributes: [.font: font]).width
        para.tabStops = []
        para.defaultTabInterval = space
        return [.font: font, .paragraphStyle: para, .foregroundColor: NSColor(hex: palette.foreground)]
    }

    /// Where the last edit began and how much it inserted (the language
    /// sniff only reads the start; a paste sniffs at once).
    private var lastEditLocation = 0
    private var lastEditLength = 0
    /// Character edits seen by the storage, and how many textDidChange has
    /// handled: NSTextView's undo and redo change the text without calling
    /// textDidChange, so storageEdited catches up for them on the next turn
    /// (else an undo after a save left the tab marked saved, and its text
    /// unsaved).
    private var storageEdits = 0
    private var handledEdits = 0
    private var sniffTimer: Timer?

    /// Auto-detection for an untitled tab (see textDidChange).
    func sniffLanguage() {
        sniffTimer?.invalidate()
        sniffTimer = nil
        guard doc.fileURL == nil, !extrasPaused, doc.languageChoice.textChanged(textView.string, isUntitled: true) else { return }
        languageChanged()
    }

    private func storageEdited() {
        guard let storage = textView.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let delta = storage.changeInLength
        let oldRange = NSRange(location: edited.location, length: edited.length - delta)
        let oldLines = lineIndex.lineCount
        lastEditLocation = edited.location
        lastEditLength = edited.length
        editing.documentCounts = nil
        // Bookmarks follow their lines (EditingFeatures.swift).
        var bookmarkEdit: (first: Int, removed: Int, wholeLines: Bool)?
        if !loading, !editing.bookmarks.isEmpty {
            let a = lineIndex.line(containing: oldRange.location), b = lineIndex.line(containing: NSMaxRange(oldRange))
            bookmarkEdit = (a, b - a, lineIndex.starts[a] == oldRange.location && lineIndex.starts[b] == NSMaxRange(oldRange))
        }
        textView.textEdited(oldRange: oldRange, newLength: edited.length)
        if let folding, !loading { folding.textEdited(oldRange: oldRange, newLength: edited.length, storage: storage) }
        let first = lineIndex.replace(oldRange, newLength: edited.length, in: storage.string as NSString)
        fences.invalidate(fromLine: first)
        if loading { return }
        spellStep?.textEdited(oldRange, newLength: edited.length)
        if !textView.grammarRanges.isEmpty { grammar.textEdited(oldRange, newLength: edited.length) }
        grammarStep?.textEdited(oldRange, newLength: edited.length)
        if let chat = owlChat, chat.pending != nil { DispatchQueue.main.async { MainActor.assumeIsolated { chat.documentEdited() } } }
        storageEdits += 1
        let seen = storageEdits
        // Only undo and redo: Follow File appends on purpose without a
        // user change (the tab stays clean).
        if let um = textView.undoManager, um.isUndoing || um.isRedoing {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.handledEdits < seen, self.window != nil else { return }
                self.textDidChange(Notification(name: NSText.didChangeNotification, object: self.textView))
            }
        }
        if let e = bookmarkEdit {
            editing.bookmarks.adjust(firstLine: e.first, removed: e.removed, inserted: lineIndex.lineCount - oldLines + e.removed,
                                     wholeLines: e.wholeLines)
        }
        colorizer.textDidChange(firstLine: first, lastLine: lineIndex.line(containing: NSMaxRange(edited)),
                                lineDelta: lineIndex.lineCount - oldLines, lineCount: lineIndex.lineCount)
        if lineIndex.lineCount != oldLines { updateGutterWidth() }
        gitState?.edited(firstLine: first, lineDelta: lineIndex.lineCount - oldLines)
        checkLargeAfterEdit(lines: first..<(first + max(1, lineIndex.lineCount - oldLines + 1)))
    }

    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        handledEdits = storageEdits
        let wasDirty = doc.isDirty
        doc.noteChange()
        if wasDirty != doc.isDirty { updateTitle() }
        // An untitled tab nobody picked a language for follows what is
        // typed or pasted (LanguageChoice): a paste at once, typing when
        // it pauses. The sniff reads the first 4 KB, so edits further down
        // skip it.
        // A paste may bring the first indented lines: look again when needed.
        if lastEditLength > 1, case .some(nil) = doc.detectedIndentation { doc.detectedIndentation = nil }
        if doc.fileURL == nil, doc.languageChoice.isAuto, lastEditLocation < 4096, !extrasPaused {
            sniffTimer?.invalidate()
            if lastEditLength > 1 {
                sniffLanguage()
            } else {
                let t = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sniffLanguage() }
                }
                RunLoop.main.add(t, forMode: .common)
                sniffTimer = t
            }
        }
        gutter.needsDisplay = true
        editingTextChanged()
        updateStatus()
        schedulePreview()
        outlineTextChanged()
        if let owl {
            owl.noteTyping()
            OwlHub.shared.activity(in: self)
        }
        grammar.schedule()
        onChange?(self)
    }

    /// Folding: a key move skips hidden text, anything else opens it (Folding.swift).
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
                  toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
        guard let folding else { return newSelectedCharRanges }
        return folding.selectionWillChange(from: oldSelectedCharRanges, to: newSelectedCharRanges, byKey: self.textView.keyNavigating)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // New text starts in the theme's text colour, never in the colour
        // of the token before the caret (or a default black); the
        // highlighter recolours it a moment later.
        if !textView.hasMarkedText() { textView.typingAttributes = baseAttributes() }
        updateStatus()
        gutter.needsDisplay = true
        owl?.caretMoved(byUser: true)
        scheduleHighlights()
        updateBracketMatch()
        updateOutlineCurrent()
    }

    /// The line at the top when the user last scrolled: kept there when
    /// the window is resized (re-wrapping would otherwise drift the view).
    private var anchorLine = 0
    private var restoringAnchor = false

    private func keepAnchor() {
        guard !restoringAnchor, anchorLine > 0, topLine != anchorLine else { return }
        restoringAnchor = true
        scrollToLine(anchorLine)
        restoringAnchor = false
    }

    private func scrolled() {
        if !restoringAnchor { anchorLine = topLine }
        colorizer.scheduleViewport()
        // Once more after TextKit has laid out the new viewport.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.colorizer.colorViewport()
            self?.gutter.needsDisplay = true
            self?.refreshHighlights()
        }
        gutter.needsDisplay = true
        syncPreviewScroll()
        owl?.caretMoved()
        if owl != nil { OwlHub.shared.visibleChanged(in: self) }
    }

    // MARK: Appearance

    var palette: EditorPalette { Settings.shared.palette(for: window?.effectiveAppearance) }

    func applyAppearance() {
        let s = Settings.shared
        window?.appearance = s.windowAppearance
        let p = palette
        textView.palette = p
        textView.backgroundColor = NSColor(hex: p.background)
        scrollView.backgroundColor = NSColor(hex: p.background)
        textView.insertionPointColor = NSColor(hex: p.caret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(hex: p.selection)]
        textView.showInvisibles = s.showInvisibles
        gutter.palette = p
        container.showsGutter = s.showLineNumbers
        statusBar.background = NSColor(hex: p.statusBar)
        // Font and foreground over the whole text: one attribute run.
        let attrs = baseAttributes()
        if let storage = textView.textStorage, storage.length > 0,
           (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) != s.font
            || (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) != NSColor(hex: p.foreground) {
            loading = true
            storage.beginEditing()
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            loading = false
        }
        textView.font = s.font
        textView.textColor = NSColor(hex: p.foreground)
        textView.typingAttributes = attrs
        tabWidthChanged()
        applyWrap(s.wrapLines)
        updateGutterWidth()
        colorizer.setPalette(p)
        statusBar.zoom.stringValue = "\(Int((s.fontSize / Settings.defaultFontSize * 100).rounded()))%"
        textView.needsDisplay = true
        if previewVisible { renderPreview() }
        outline.sidebar?.applyPalette(p)
        owl?.layoutViews()
        spelling.apply()
        gitState?.settingChanged()
        // Grammar waits for the first frame (a pass is scheduled, never run, here).
        AfterFirstFrame.run { [weak self] in self?.grammar.apply() }
    }

    private(set) var wrapsLines = true

    /// Perf experiments only (CEDRIC_PERF_WRAP).
    func forceWrapForPerf(_ wrap: Bool) { applyWrap(wrap) }

    private func applyWrap(_ wrap: Bool) {
        wrapsLines = wrap
        guard let container = textView.textContainer else { return }
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    func updateGutterWidth() {
        gutter.foldColumn = foldingAvailable ? GutterView.foldColumnWidth : 0
        container.gutterWidth = gutter.requiredWidth(lines: lineIndex.lineCount, font: Settings.shared.font)
        gutter.needsDisplay = true
    }

    // MARK: Title and status

    func updateTitle() {
        guard let window else { return }
        window.title = doc.displayName
        window.representedURL = doc.fileURL
        window.isDocumentEdited = doc.isDirty
        window.tab.toolTip = doc.fileURL?.path
        previewWindow?.updateTitle()
    }

    private func configureStatusBar() {
        statusBar.gitButton.target = self
        statusBar.gitButton.action = #selector(showGitMenu(_:))
        statusBar.languageButton.target = self
        statusBar.encodingButton.target = self
    }

    func updateStatus() {
        let sel = textView.selectedRange()
        let line = lineIndex.line(containing: sel.location)
        let col = sel.location - lineIndex.starts[line] + 1
        var pos = String(localized: "Ln \(line + 1), Col \(col)")
        if let marks = editing.markCount { pos += "  " + String(localized: "\(marks) marked") }
        scheduleCounts()
        statusBar.position.stringValue = pos
        StatusBar.fill(statusBar.languageButton, title: doc.languageChoice.displayTitle,
                       items: Language.allCases.map { ($0.displayName, $0.rawValue, $0 == doc.language) },
                       target: self, action: #selector(pickLanguage(_:)))
        var encItems: [(String, Any?, Bool)] = [(String(localized: "Save with Encoding"), nil, false)]
        encItems += TextEncoding.allCases.map { ($0.displayName, "save:" + $0.rawValue, $0 == doc.encoding) }
        if doc.fileURL != nil {
            encItems += [("-", nil, false), (String(localized: "Reopen with Encoding"), nil, false)]
            encItems += TextEncoding.allCases.map { ($0.displayName, "reopen:" + $0.rawValue, false) }
        }
        StatusBar.fill(statusBar.encodingButton, title: doc.encoding.displayName, items: encItems,
                       target: self, action: #selector(pickEncoding(_:)))
        let leTitle = doc.mixedLineEndings ? String(localized: "\(doc.lineEnding.displayName) (mixed)") : doc.lineEnding.displayName
        StatusBar.fill(statusBar.lineEndingButton, title: leTitle,
                       items: [(String(localized: "Convert Line Endings To"), nil, false)]
                        + LineEnding.allCases.map { ($0.displayName, $0.rawValue, $0 == doc.lineEnding) },
                       target: self, action: #selector(pickLineEnding(_:)))
    }

    @objc func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Language(rawValue: raw) else { return }
        setLanguage(l)
    }

    /// Picked by the user (status bar or Format › Language): fixed from now on.
    func setLanguage(_ l: Language) {
        doc.languageChoice.choose(l)
        languageChanged()
    }

    /// A language change that belongs to an edit (the owl's to-do fix
    /// colours the tab as Markdown): registered in the same undo group,
    /// so one ⌘Z restores the text and the language, and ⇧⌘Z redoes both.
    func setLanguageWithUndo(_ l: Language) {
        let old = doc.languageChoice
        setLanguage(l)
        registerLanguageUndo(back: old)
    }

    private func registerLanguageUndo(back old: LanguageChoice) {
        guard let um = textView.undoManager else { return }
        // Undo runs on the main thread (AppKit's undo manager); the 6.1
        // compiler sees registerUndo's handler as nonisolated and Sendable.
        um.registerUndo(withTarget: self) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.doc.languageChoice
                self.doc.languageChoice = old
                self.languageChanged()
                self.registerLanguageUndo(back: now)
            }
        }
    }

    private func languageChanged() {
        let l = doc.language
        colorizer.setLanguage(l)
        textView.language = l
        foldingContextChanged()
        updateGutterWidth()
        // What counts as a word changed (code vs prose): check again
        // (or not at all: data such as JSON isn't checked).
        if textView.isContinuousSpellCheckingEnabled { textView.isContinuousSpellCheckingEnabled = false }
        textView.markedMisspellings = []
        spelling.apply()
        grammar.apply()
        updateStatus()
        previewLanguageChanged()
        if outlineVisible, !l.hasOutline { hideOutline() } else if outlineVisible { refreshOutline() }
        onChange?(self)
    }

    @objc func pickEncoding(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? String else { return }
        let parts = rep.split(separator: ":")
        guard parts.count == 2, let enc = TextEncoding(rawValue: String(parts[1])) else { return }
        if parts[0] == "save" {
            convertEncoding(to: enc)
        } else {
            reopen(with: enc)
        }
    }

    func convertEncoding(to enc: TextEncoding) {
        guard enc != doc.encoding else { return }
        if !TextCodec.canEncode(textView.string, as: enc) {
            let a = NSAlert()
            a.messageText = String(localized: "Some characters can’t be represented in \(enc.displayName).")
            a.informativeText = String(localized: "Keep the current encoding, or remove those characters first.")
            a.beginSheetModal(for: window!)
            return
        }
        doc.encoding = enc
        markConverted()
    }

    func reopen(with enc: TextEncoding) {
        guard let url = doc.fileURL else { return }
        if doc.isDirty {
            let a = NSAlert()
            a.messageText = String(localized: "Reopen “\(doc.displayName)” as \(enc.displayName)?")
            a.informativeText = String(localized: "Your unsaved changes in this tab will be lost.")
            a.addButton(withTitle: String(localized: "Reopen"))
            a.addButton(withTitle: String(localized: "Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let (d, mod) = try EditorDocument.read(url, encoding: enc)
            doc.apply(d)
            doc.fileModified = mod
            setText(d.text)
            doc.markSaved()
            updateTitle()
            onChange?(self)
        } catch {
            showError(error)
        }
    }

    @objc func pickLineEnding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let le = LineEnding(rawValue: raw) else { return }
        convertLineEndings(to: le)
    }

    func convertLineEndings(to le: LineEnding) {
        guard le != doc.lineEnding || doc.mixedLineEndings else { return }
        doc.lineEnding = le
        doc.mixedLineEndings = false
        markConverted()
    }

    /// Encoding and line endings apply on save: the tab becomes unsaved.
    private func markConverted() {
        doc.noteChange()
        updateTitle()
        updateStatus()
        onChange?(self)
    }

    // MARK: Saving

    @discardableResult
    func save() -> Bool {
        guard !binaryBlocksSave else { NSSound.beep(); return false }
        guard let url = doc.fileURL else { return saveAs() }
        // Another app changed the file since it was read or saved here: ask
        // (DiskChange.swift) rather than overwrite its changes.
        if fileChangedOnDisk(url) { askSaveConflict(url); return false }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        guard !binaryBlocksSave else { NSSound.beep(); return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? doc.untitledName + (doc.language == .markdown ? ".md" : ".txt")
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try doc.write(textView.string, to: url)
        } catch {
            showError(error)
            return false
        }
        if doc.languageChoice.saved(fileName: url.lastPathComponent, content: textView.string) { languageChanged() }
        hideDiskBar()
        (NSApp.delegate as? AppDelegate)?.noteRecent(url)
        updateTitle()
        updateStatus()
        owl?.noteSave()
        gitSaved()
        onChange?(self)
        return true
    }

    func showError(_ error: Error) {
        let a = NSAlert(error: error)
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    /// Reloads from disk if the file changed and the tab has no unsaved
    /// edits; with unsaved edits, shows the "Changed on disk" bar (and
    /// flags it for the owl's "Reload?"). Never drops unsaved edits.
    func reloadIfChangedOnDisk() {
        guard tail == nil, let url = doc.fileURL, fileChangedOnDisk(url) else { return }
        if doc.isDirty {
            if !doc.changedOnDisk {
                doc.changedOnDisk = true
                if owl != nil { OwlHub.shared.activity(in: self) }
            }
            showDiskBar()
            return
        }
        guard let (d, newMod) = try? EditorDocument.read(url, encoding: doc.encoding) else { return }
        hideDiskBar()
        if case .held = binary {
            // Not shown yet (Open Anyway): only what it will show changes.
            binary = .held(d.text)
            doc.fileModified = newMod
            return
        }
        let sel = textView.selectedRange()
        doc.apply(d)
        doc.fileModified = newMod
        setText(d.text)
        doc.markSaved()
        let len = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        if previewVisible { renderPreview() }
    }

    /// The owl's "Reload?": replaces the text with the file on disk as one
    /// undoable edit (unlike `setText`, which clears undo).
    func reloadFromDisk() {
        guard let url = doc.fileURL, let storage = textView.textStorage else { return }
        do {
            let (d, mod) = try EditorDocument.read(url, encoding: doc.encoding)
            let all = NSRange(location: 0, length: storage.length)
            textView.breakUndoCoalescing()
            if textView.shouldChangeText(in: all, replacementString: d.text) {
                storage.replaceCharacters(in: all, with: NSAttributedString(string: d.text, attributes: baseAttributes()))
                textView.didChangeText()
                textView.undoManager?.setActionName(String(localized: "Reload"))
            }
            doc.apply(d)
            doc.fileModified = mod
            doc.markSaved()
            hideDiskBar()
            updateTitle()
            updateStatus()
            onChange?(self)
        } catch {
            showError(error)
        }
    }

    /// The owl's "Save a copy?": writes the text elsewhere; the tab keeps
    /// its file and stays unsaved.
    func saveCopy() {
        guard !binaryBlocksSave else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let base = (doc.displayName as NSString).deletingPathExtension
        let ext = (doc.displayName as NSString).pathExtension
        panel.nameFieldStringValue = String(localized: "\(base) copy") + (ext.isEmpty ? ".txt" : "." + ext)
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = TextCodec.encode(textView.string, encoding: doc.encoding, lineEnding: doc.lineEnding) else {
            showError(NSError(domain: "Cedric", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Couldn’t encode the copy.")]))
            return
        }
        do { try data.write(to: SafePaths.writeTarget(for: url), options: .atomic) } catch { showError(error) }
    }

    // MARK: Owl

    func setOwlVisible(_ on: Bool) {
        if on, owl == nil {
            let o = OwlController(tab: self)
            owl = o
            container.overlay = o.overlay
            o.appeared()
            OwlHub.shared.activity(in: self)
        } else if !on, let o = owl {
            o.detach()
            owl = nil
            container.overlay = nil
        }
    }

    /// What the providers see: the visible lines and their margin.
    func owlContextWindow() -> OwlContextWindow {
        OwlContextWindow(text: textView.string as NSString, visible: textView.visibleCharacterRange ?? NSRange(location: 0, length: 0),
                         selection: textView.selectedRange(), fileName: doc.fileURL?.lastPathComponent,
                         language: doc.language.rawValue, documentID: doc.id, editGeneration: doc.changeCount)
    }

    func owlFacts(wholeDocument: Bool) -> OwlDocumentFacts {
        OwlDocumentFacts(isWholeDocument: wholeDocument, changedOnDisk: doc.changedOnDisk,
                         unsavedSince: doc.isDirty ? doc.unsavedSince : nil, lineEnding: doc.lineEnding,
                         mixedLineEndings: doc.mixedLineEndings, languageIsManual: doc.languageIsManual)
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard doc.isDirty, !(doc.fileURL == nil && textView.string.isEmpty) else { return true }
        // Hot close (ClosedTabs.swift): the unsaved text is kept for File ›
        // Reopen Closed Tab. Only if it can't be written do we ask.
        if (NSApp.delegate as? AppDelegate)?.keepTextForClose(self) == true { return true }
        let a = NSAlert()
        a.messageText = String(localized: "Save changes to “\(doc.displayName)”?")
        a.informativeText = String(localized: "Your changes are lost if you don’t save them.")
        a.addButton(withTitle: String(localized: "Save"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.addButton(withTitle: String(localized: "Don’t Save"))
        a.buttons[2].hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        previewTimer?.invalidate()
        if let pw = previewWindow { previewWindow = nil; pw.closeWithTab() }
        owl?.detach()
        sniffTimer?.invalidate()
        editing.stop()
        spellStep?.closeWithTab()
        grammar.stop()
        grammarStep?.closeWithTab()
        OwlHub.shared.closed(self)
        owlChat?.close()
        OwlChatStore.shared.closed(doc.id)
        tail?.stop()
        tail = nil
        gitState?.stop()
        onClose?(self)
        // Last: rememberClosed (onClose) still reads the selection and scroll place.
        detachViews()
    }

    /// The window is closing: AppKit may keep it (and so the views) a
    /// while longer, even drawing it (tab bar), after this controller is
    /// freed. Cut every path from the views back to the controller and
    /// take the views out of the window, so nothing draws or calls in.
    private func detachViews() {
        textView.onCutLine = nil
        textView.indentation = nil
        textView.onShiftLines = nil
        textView.tabInsertsSpaces = nil
        textView.onDropFiles = nil
        (stack as? FileDropStackView)?.onDropFiles = nil
        textView.lineStartFor = nil
        textView.contentStorage?.lineRange = nil
        colorizer.lineIndexProvider = { LineIndex() }
        gutter.lineIndex = { LineIndex() }
        gutter.bookmarks = { Bookmarks() }
        gutter.gitChanges = { nil }
        gutter.onClickLine = nil
        gutter.onClickFold = nil
        gutter.foldMarks = { _ in nil }
        gutter.textView = nil
        if textView.delegate === self { textView.delegate = nil }
        window?.delegate = nil
        // A docked preview's WKWebView comes out first: swapping the content
        // view with a web view inside traps in WebKit (see PreviewWindowController).
        previewPane?.removeFromSuperview()
        window?.contentView = NSView()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Changed on disk while another tab or app was in front (owl or
        // not). Not before the first frame: nothing new on the launch path.
        if AfterFirstFrame.passed { reloadIfChangedOnDisk() }
        gitTabShown()
        (NSApp.delegate as? AppDelegate)?.tabBecameKey(self)
    }

    // MARK: Navigation

    var topLine: Int {
        guard let vr = textView.viewportCharacterRange else { return 0 }
        // The viewport range starts above the visible rect; use the visible rect's top instead.
        let visibleTop = scrollView.contentView.bounds.minY
        if let tlm = textView.textLayoutManager,
           let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visibleTop - textView.textContainerOrigin.y))) {
            return lineIndex.line(containing: textView.offset(of: frag.rangeInElement.location))
        }
        return lineIndex.line(containing: vr.location)
    }

    func scrollToLine(_ line: Int) {
        let l = visibleLine(max(0, min(line, lineIndex.lineCount - 1)))
        reveal(NSRange(location: lineIndex.starts[l], length: 0), position: .top)
    }

    enum RevealPosition { case top, center }

    /// Scrolls `range` into view. TextKit 2 estimates the heights of text
    /// it hasn't laid out, and laying out the new viewport refines those
    /// estimates and moves everything, so in a big file a single scroll
    /// (or `scrollRangeToVisible`) lands short of the target. This scrolls
    /// to the target's current frame, lays out the viewport, and repeats
    /// until the target is where it should be (a few passes at most).
    func reveal(_ range: NSRange, position: RevealPosition = .center) {
        folding?.reveal(range)
        guard let tlm = textView.textLayoutManager, let r = textView.textRange(for: range) else {
            textView.scrollRangeToVisible(range)
            return
        }
        let vlc = tlm.textViewportLayoutController
        let origin = textView.textContainerOrigin.y
        for _ in 0..<10 {
            tlm.ensureLayout(for: r)
            guard let frag = tlm.textLayoutFragment(for: r.location) else { textView.scrollRangeToVisible(range); break }
            let f = frag.layoutFragmentFrame
            let visible = scrollView.contentView.bounds
            let fy = f.minY + origin
            let inView = fy >= visible.minY && fy + min(f.height, visible.height) <= visible.maxY
            if inView && position == .center { break }
            var y = fy
            if position == .center { y -= max(0, (visible.height - f.height) / 2) }
            y = max(0, y)
            if abs(y - visible.minY) < 1 { break }
            textView.scroll(NSPoint(x: 0, y: y))
            vlc.layoutViewport()
        }
        colorizer.scheduleViewport()
        gutter.needsDisplay = true
    }

    func goToLine(_ line: Int, column: Int = 1) {
        // Clamped before subtracting: Int.min from a link must not trap.
        let l = OneBased.index(line, count: lineIndex.lineCount)
        let r = lineIndex.contentRange(ofLine: l)
        let loc = r.location + OneBased.index(column, count: r.length + 1)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        reveal(NSRange(location: loc, length: 0))
    }

    @objc func goToLinePrompt(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = String(localized: "Go to Line")
        a.informativeText = String(localized: "Line (1–\(lineIndex.lineCount)), optionally followed by :column.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "42 or 42:7"
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "Go"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let line = parts.first else { return }
            self?.goToLine(line, column: parts.count > 1 ? parts[1] : 1)
            self?.window?.makeFirstResponder(self?.textView)
        }
    }

    // MARK: Find

    func showFindBar(replace: Bool) {
        findBar.isHidden = false
        findBar.showsReplace = replace
        let sel = textView.selectedRange()
        if sel.length > 0, sel.length < 200 {
            findBar.findField.stringValue = (textView.string as NSString).substring(with: sel)
        }
        window?.makeFirstResponder(findBar.findField)
        findBar.findField.selectText(nil)
        findChanged()
    }

    func hideFindBar() {
        findBar.isHidden = true
        window?.makeFirstResponder(textView)
    }

    private func currentRegex() -> NSRegularExpression? {
        do {
            let re = try FindEngine.regex(findBar.findField.stringValue, findBar.options)
            return re
        } catch FindEngine.FindError.invalidPattern {
            findBar.status.stringValue = String(localized: "Invalid pattern")
            return nil
        } catch {
            findBar.status.stringValue = ""
            return nil
        }
    }

    private func findChanged() {
        guard let re = currentRegex() else { return }
        let n = FindEngine.matches(re, in: textView.string as NSString).count
        findBar.status.stringValue = n == 1 ? String(localized: "1 match") : String(localized: "\(n) matches")
        // Incremental: select the first match at or after the selection start.
        if let r = FindEngine.next(re, in: textView.string as NSString, from: textView.selectedRange().location) {
            select(r)
        }
    }

    func find(backwards: Bool) {
        if findBar.isHidden || findBar.findField.stringValue.isEmpty { showFindBar(replace: false); return }
        guard let re = currentRegex() else { return }
        let sel = textView.selectedRange()
        let from = backwards ? sel.location : sel.location + sel.length
        if let r = FindEngine.next(re, in: textView.string as NSString, from: from, backwards: backwards) {
            select(r)
        } else {
            NSSound.beep()
        }
    }

    private func select(_ r: NSRange) {
        textView.setSelectedRange(r)
        reveal(r)
        textView.showFindIndicator(for: r)
        colorizer.scheduleViewport()
    }

    private func replaceOne() {
        guard let re = currentRegex() else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        // Replace the selection if it is a match, then move to the next.
        if sel.length > 0, let m = re.firstMatch(in: ns as String, options: [.anchored], range: sel), m.range == sel {
            let rep = FindEngine.replacement(for: m, in: ns, template: findBar.replaceField.stringValue, regex: re, options: findBar.options)
            if textView.shouldChangeText(in: sel, replacementString: rep) {
                textView.textStorage?.replaceCharacters(in: sel, with: NSAttributedString(string: rep, attributes: baseAttributes()))
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: sel.location + (rep as NSString).length, length: 0))
            }
        }
        find(backwards: false)
        findChanged()
    }

    private func replaceAll() {
        guard let re = currentRegex(), textView.textStorage != nil else { return }
        let ns = textView.string as NSString
        let found = FindEngine.matches(re, in: ns)
        guard !found.isEmpty else { NSSound.beep(); return }
        let reps = found.map { FindEngine.replacement(for: $0, in: ns, template: findBar.replaceField.stringValue, regex: re, options: findBar.options) }
        // One undo step: register the whole affected span as one change.
        let span = NSRange(location: found.first!.range.location,
                           length: found.last!.range.location + found.last!.range.length - found.first!.range.location)
        let newSpan = NSMutableString(string: ns.substring(with: span))
        for (m, rep) in zip(found, reps).reversed() {
            newSpan.replaceCharacters(in: NSRange(location: m.range.location - span.location, length: m.range.length), with: rep)
        }
        replaceAsOneStep(span, with: newSpan as String, actionName: String(localized: "Replace All"))
        findBar.status.stringValue = String(localized: "Replaced \(found.count)")
    }

    // MARK: Preview

    /// The Certificate panel applies: a certificate file name, or PEM text
    /// near the start, in a language without its own preview. Not for a
    /// file held or shown as binary (a .crt that isn't DER or PEM).
    var showsCertificatePanel: Bool {
        binary == nil && !doc.language.hasPreview && Certificates.isCertificateText(textView.string, fileName: doc.fileURL?.lastPathComponent)
    }

    /// View › Show Preview applies: Markdown, HTML, CSV, or the Certificate panel.
    var previewApplies: Bool { doc.language.hasPreview || showsCertificatePanel }

    /// View › Show Preview (⌥⌘P): docked beside the text, or closed
    /// (detached too).
    func togglePreview() {
        if previewPane != nil {
            if previewPane?.renderer is CertificatePanel { CertificatePanel.closedByUser = true }
            closePreview()
            return
        }
        guard previewApplies else { NSSound.beep(); return }
        if showsCertificatePanel { CertificatePanel.closedByUser = false }
        dock(makePreviewPane())
        renderPreview()
        onChange?(self)
    }

    private func makePreviewPane() -> PreviewPane {
        let pane = PreviewPane(renderer: makeRenderer(for: doc.language))
        pane.titleLabel.stringValue = pane.renderer is CertificatePanel ? String(localized: "Certificate") : String(localized: "Preview")
        pane.bar.onAction = { [weak self] item in self?.previewBarAction(item) }
        pane.bar.onExport = { [weak self] html in html ? self?.exportHTML() : self?.exportPDF() }
        pane.applyPalette(palette)
        previewPane = pane
        updatePreviewBar()
        return pane
    }

    /// The preview bar scrolls the preview in step with the text (both ways, Markdown; the grid follows, CSV).
    private(set) var previewSyncsScroll = true

    /// The preview bar's state from the tab and its renderer.
    func updatePreviewBar() {
        guard let pane = previewPane else { return }
        let r = pane.renderer
        let csv = r as? CSVPreview, web = r as? PreviewController
        var s = PreviewBarState()
        s.items = PreviewBarItem.items(for: doc.language, certificate: r is CertificatePanel)
        s.syncScroll = previewSyncsScroll
        s.zoom = r.zoom
        s.allowJavaScript = web?.allowJavaScript ?? false
        s.allowNetwork = web?.allowNetwork ?? false
        s.detached = previewDetached
        s.sorted = csv?.isSorted ?? false
        s.rowCount = csv?.rowCountText ?? ""
        // Called after every render: a no-op unless something changed.
        if pane.bar.apply(s) { pane.needsLayout = true }
    }

    /// A preview bar button.
    func previewBarAction(_ item: PreviewBarItem) {
        guard let pane = previewPane else { return }
        switch item {
        case .refresh:
            pane.renderer.refresh()
            renderPreview()
        case .syncScroll:
            previewSyncsScroll.toggle()
            if previewSyncsScroll { syncPreviewScroll() }
        case .zoomIn, .zoomOut:
            pane.renderer.zoom = PreviewZoom.step(pane.renderer.zoom, in: item == .zoomIn)
        case .allowJavaScript: previewAllowsJavaScript.toggle()
        case .allowNetwork: previewAllowsNetwork.toggle()
        case .detach: toggleDetachPreviewAction(nil)
        case .sortReset: (pane.renderer as? CSVPreview)?.resetSort()
        case .export, .rowCount: break
        }
        updatePreviewBar()
    }

    private func makeRenderer(for language: Language) -> PreviewRenderer {
        if !language.hasPreview {
            let c = CertificatePanel()
            c.isLarge = { [weak self] in self?.extrasPaused ?? false }
            return c
        }
        if language == .csv {
            let g = CSVPreview()
            g.isLarge = { [weak self] in self?.extrasPaused ?? false }
            g.currentText = { [weak self] in (self?.textView.string ?? "") as NSString }
            g.onApplied = { [weak self] in self?.updatePreviewBar() }
            g.onSelectField = { [weak self] offset in
                guard let self else { return }
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.textView)
                self.textView.setSelectedRange(NSRange(location: offset, length: 0))
                self.reveal(NSRange(location: offset, length: 0))
            }
            return g
        }
        let p = PreviewController()
        p.onLoaded = { [weak self] in self?.syncPreviewScroll() }
        p.onScrolledToLine = { [weak self] line in self?.previewScrolled(toLine: line) }
        p.onLink = { [weak self] action in self?.previewLink(action) }
        return p
    }

    private func dock(_ pane: PreviewPane) {
        pane.setDetached(false)
        split.addArrangedSubview(pane)
        split.adjustSubviews()
        FolderSidebar.keepWidth(in: split)
        // Half the room right of a folder sidebar: the divider right after
        // the editor (the sidebar may sit before it).
        let w = split.bounds.width
        if w > 0, let i = split.arrangedSubviews.firstIndex(of: container) {
            let left = container.frame.minX
            split.setPosition(left + (w - left) / 2, ofDividerAt: i)
        }
    }

    func closePreview() {
        previewTimer?.invalidate()
        if let pw = previewWindow {
            previewWindow = nil
            pw.closeReleasingPane()
        }
        let docked = previewPane?.superview === split
        previewPane?.removeFromSuperview()
        previewPane = nil
        if docked { FolderSidebar.keepWidth(in: split) }
        onChange?(self)
    }

    /// View › Detach Preview (⇧⌥⌘P), or the header's Detach: the preview
    /// in its own window, bound to this tab's document. `frame`: where it
    /// was (session restore); `activate` false leaves the focus alone.
    func detachPreview(frame: String? = nil, activate: Bool = true) {
        guard !previewDetached else { return }
        guard previewApplies else { NSSound.beep(); return }
        let pane = previewPane ?? makePreviewPane()
        let docked = pane.superview === split
        pane.removeFromSuperview()
        if docked { FolderSidebar.keepWidth(in: split) }
        let pw = PreviewWindowController(tab: self, pane: pane, frame: frame)
        previewWindow = pw
        pw.window?.orderFront(nil)
        if activate { window?.makeKeyAndOrderFront(nil) }
        renderPreview()
        updatePreviewBar()
        onChange?(self)
    }

    /// View › Attach Preview, or the detached window's Attach: docked again.
    func attachPreview() {
        guard let pw = previewWindow, let pane = previewPane else { return }
        previewWindow = nil
        pw.closeReleasingPane()
        dock(pane)
        window?.makeKeyAndOrderFront(nil)
        renderPreview()
        updatePreviewBar()
        onChange?(self)
    }

    @objc func toggleDetachPreviewAction(_ sender: Any?) {
        if previewDetached { attachPreview() } else { detachPreview() }
    }

    /// The user closed the detached window: the preview is closed.
    func previewWindowClosedByUser() {
        previewWindow = nil
        previewPane = nil
        previewTimer?.invalidate()
        onChange?(self)
    }

    /// The language changed: another renderer if this one doesn't draw it.
    private func previewLanguageChanged() {
        guard let pane = previewPane else { return }
        if !previewApplies { closePreview(); return }
        if !pane.renderer.handles(doc.language) {
            pane.replaceRenderer(makeRenderer(for: doc.language))
            pane.titleLabel.stringValue = pane.renderer is CertificatePanel ? String(localized: "Certificate") : String(localized: "Preview")
        }
        renderPreview()
    }

    var previewAllowsJavaScript: Bool {
        get { preview?.allowJavaScript ?? false }
        set { preview?.allowJavaScript = newValue; renderPreview() }
    }

    var previewAllowsNetwork: Bool {
        get { preview?.allowNetwork ?? false }
        set { preview?.allowNetwork = newValue; renderPreview() }
    }

    private func schedulePreview() {
        guard previewVisible else { return }
        previewTimer?.invalidate()
        // The render runs off the main thread; in large mode it waits for
        // a longer pause, so a huge document isn't re-rendered per word.
        previewTimer = Timer.scheduledTimer(withTimeInterval: extrasPaused ? 2 : 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderPreview() }
        }
    }

    func renderPreview() {
        guard let pane = previewPane else { return }
        let start = DispatchTime.now()
        pane.applyPalette(palette)
        previewWindow?.updateTitle()
        // `string` is a copy (the renderers work on it off the main thread).
        pane.renderer.render(text: textView.string, language: doc.language, palette: palette,
                             baseURL: doc.fileURL?.deletingLastPathComponent(), fileName: doc.fileURL?.lastPathComponent)
        (pane.renderer as? PreviewController)?.noteMainThread(start)
        updatePreviewBar()
    }

    /// The user scrolled the preview: the editor follows (Markdown), and
    /// doesn't send its own scrolling back for a moment.
    private var followingPreviewUntil = Date.distantPast

    private func previewScrolled(toLine line: Double) {
        guard previewVisible, previewSyncsScroll, doc.language == .markdown, lineIndex.lineCount > 0 else { return }
        followingPreviewUntil = Date().addingTimeInterval(0.3)
        let target = max(0, min(Int(line.rounded()), lineIndex.lineCount - 1))
        if target != topLine { scrollToLine(target) }
    }

    private func syncPreviewScroll() {
        guard let pane = previewPane, previewVisible, previewSyncsScroll, Date() >= followingPreviewUntil else { return }
        let top = topLine
        let fraction = lineIndex.lineCount > 1 ? Double(top) / Double(lineIndex.lineCount - 1) : 0
        pane.renderer.sync(line: top, fraction: fraction, language: doc.language)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { max(proposed, 200) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { min(proposed, splitView.bounds.width - 200) }
}

/// The tab's split view (folder sidebar | editor | preview | Find in
/// Files). It knows when the user is dragging one of its dividers: a
/// mouse-down on the split itself (its subviews take every other click)
/// starts a drag that lasts until the button is up. A click elsewhere in
/// the window that docks or closes a panel (the × of Find in Files) is not
/// a drag, though its mouse events are the current event while the panes
/// are resized.
final class PaneSplitView: NSSplitView {
    private(set) var isDraggingDivider = false

    override func mouseDown(with event: NSEvent) {
        isDraggingDivider = true
        super.mouseDown(with: event)
        // NSSplitView tracks the drag in its own loop: the button is up when it returns.
        if NSEvent.pressedMouseButtons & 1 == 0 { isDraggingDivider = false }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingDivider = false
        super.mouseUp(with: event)
    }
}
