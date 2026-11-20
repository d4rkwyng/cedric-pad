import UIKit
import SwiftUI
import CedricCore
import CedricAI

/// One open document: a UITextView on an explicit TextKit 2 stack (as the
/// Mac's NSTextView), coloured by the core's highlighter, with the system
/// find and replace (⌘F, ⌥⌘F), a status line (language, encoding, line
/// ending, caret), Cedric's hints, the Markdown preview and Ask Cedric.
final class EditorViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    let document: TextDocument
    let textView = UITextView(usingTextLayoutManager: true)
    private(set) var lineIndex = LineIndex()
    private var colorizer: SyntaxColorizer!
    let owl = EditorOwl()
    let hintBar = OwlHintBar()
    private let statusBar = UIView()
    private let statusLabel = UILabel()
    private let languageButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    /// In the bar that rides on the keyboard, only while it is up.
    let hideKeyboardButton = UIButton(type: .system)
    private let split = UIStackView()
    private(set) var preview: PreviewController?
    private(set) var previewOn = false
    private var generation = 0
    private var loading = false
    private(set) var palette = EditorPalettes.light
    private var previewTimer: Timer?
    /// Cedric, in the corner (as on the Mac).
    let owlSprite = OwlSprite()
    /// His bubble (the hint bar) is showing the current hint.
    private(set) var bubbleOpen = false
    private var lastHintCount = 0
    private var autoOpenedHint: String?
    private var textWidth: NSLayoutConstraint!
    /// Selection, scroll and keyboard while the preview covers the text
    /// (an iPhone Duo folded shut with the preview on).
    private var continuity: EditorContinuity?
    /// Ask Cedric docked beside the text on wide screens.
    private var askPanel: UIViewController?
    /// Ask Cedric as a sheet (compact width).
    private weak var askSheet: UIViewController?
    private var askPanelWidth: NSLayoutConstraint?
    private var askModel: AskCedricModel?
    private var splitTrailing: NSLayoutConstraint!
    /// The split's bottom: on the status line, or (Focus Preview, the status
    /// line hidden) on the safe area's bottom.
    private var splitBottom: NSLayoutConstraint!
    private var splitBottomFocus: NSLayoutConstraint!
    /// Focus Preview: the preview alone, editor, status line and owl hidden.
    private(set) var focusOn = false
    /// The preview was beside the text before Focus Preview (it comes back so).
    private var previewOnBeforeFocus = false
    /// The draggable handle between text and preview (wide screens).
    let divider = SplitDivider()
    /// Where the seam sits, kept per size class; a drag in progress.
    private(set) var splitPosition: SplitPosition = .fold
    private var dragFraction: Double?
    /// The preview's scroll share when the text was hidden: if it moved
    /// meanwhile, the text follows it when it comes back.
    private var previewFractionAtHide: Double?
    private var focusGestures: [UIGestureRecognizer] = []
    /// Undo and Redo in the bar, enabled from the text view's undo manager.
    private lazy var undoItem = barItem(String(localized: "Undo"), "arrow.uturn.backward", "editor.undo") { [weak self] in
        self?.textView.undoManager?.undo()
    }
    private lazy var redoItem = barItem(String(localized: "Redo"), "arrow.uturn.forward", "editor.redo") { [weak self] in
        self?.textView.undoManager?.redo()
    }
    /// Save, in the bar while "Save automatically" is off.
    private lazy var saveItem = barItem(String(localized: "Save"), "square.and.arrow.down", "editor.save") { [weak self] in
        self?.saveDocument()
    }
    /// Unsaved text from a crash, for this document.
    enum Recovery {
        /// Ask Restore / Discard when the editor appears.
        case offer(RecoveryRecord)
        /// Restore was chosen already (at launch).
        case restore(RecoveryRecord)
    }
    private var pendingRecovery: Recovery?
    private var recoveryWriter: RecoveryWriter!
    private var closing = false
    /// Why the text is read-only right now (nothing: editable).
    private(set) var editGate = EditGate()
    /// An iCloud conflict is being dealt with (copied, then asked).
    private var conflictResolver: ConflictResolver?

    init(document: TextDocument, recovery: Recovery? = nil) {
        self.document = document
        self.pendingRecovery = recovery
        super.init(nibName: nil, bundle: nil)
        OpenDocuments.paths.insert(document.recoveryPath)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpTextView()
        setUpStatusBar()
        setUpLayout()
        setUpNavigation()
        colorizer = SyntaxColorizer(textView: textView, language: document.language.language)
        colorizer.lineIndex = { [weak self] in self?.lineIndex ?? LineIndex() }
        document.currentText = { [weak self] in self?.textView.text ?? "" }
        document.onReload = { [weak self] in self?.loadText() }
        document.onEditedChange = { [weak self] in self?.updateEdited() }
        recoveryWriter = RecoveryWriter(document: document) { [weak self] in self?.textView.text ?? "" }
        document.onSaved = { [weak self] in
            guard let self, !self.closing else { return }
            // Edits made while it saved keep their copy.
            if self.document.hasUnsavedChanges { self.recoveryWriter.textChanged() } else { self.recoveryWriter.clear() }
        }
        owl.onChange = { [weak self] in self?.showHint() }
        owl.onNote = { [weak self] note in self?.toast(note) }
        applySettings()
        loadText()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.changed, object: nil)
        // As the Mac does: TextKit 2's content storage owns the storage's delegate.
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited),
                                               name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged),
                                               name: UIDocument.stateChangedNotification, object: document)
        for n in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                  .NSUndoManagerWillCloseUndoGroup] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoChanged(_:)), name: n, object: nil)
        }
        // With "Save automatically" off nothing saves on the way out: the
        // recovery copy is written now rather than up to 3 s later.
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        // Opening or closing an iPhone Duo is a size-class change (compact
        // outside, regular inside; outer landscape is compact both ways).
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self,
                                 UITraitVerticalSizeClass.self]) { (self: Self, _: UITraitCollection) in
            self.splitPosition = self.splitStore.position(regularWidth: self.traitCollection.horizontalSizeClass == .regular,
                                                          regularHeight: self.traitCollection.verticalSizeClass == .regular)
            self.applySettings()
            self.layoutPreview()
            self.updateAskPanelForWidth()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateEdited()
        colorizer.colorViewport()
        if let r = pendingRecovery {
            pendingRecovery = nil
            switch r {
            case .restore(let rec): restoreRecovered(rec)
            case .offer(let rec): offerRecovered(rec)
            }
        }
    }

    // MARK: Setup

    private func setUpTextView() {
        textView.delegate = self
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 80, right: 8)
        textView.accessibilityIdentifier = "editor.text"
        textView.allowsEditingTextAttributes = false
    }

    private func setUpStatusBar() {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "editor.status"
        for b in [languageButton, formatButton] {
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            b.showsMenuAsPrimaryAction = true
        }
        languageButton.accessibilityIdentifier = "editor.language"
        formatButton.accessibilityIdentifier = "editor.format"
        hideKeyboardButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hideKeyboardButton.accessibilityLabel = String(localized: "Hide Keyboard")
        hideKeyboardButton.accessibilityIdentifier = "editor.hideKeyboard"
        hideKeyboardButton.isHidden = true
        hideKeyboardButton.addAction(UIAction { [weak self] _ in self?.hideKeyboard() }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            hideKeyboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            hideKeyboardButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        let row = UIStackView(arrangedSubviews: [languageButton, formatButton, UIView(), statusLabel, hideKeyboardButton])
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(row)
        statusBar.backgroundColor = .secondarySystemBackground
        // The background runs to the screen's edges; the labels stay inside
        // the safe area and clear of the rounded corners (they were clipped
        // at the bottom left on an iPhone Duo): the margins guide includes
        // the safe area (insetsLayoutMarginsFromSafeArea), and on iOS 26+
        // the corner-adapted one also keeps out of the display's corners.
        statusBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
        statusBar.insetsLayoutMarginsFromSafeArea = true
        var guide: UILayoutGuide = statusBar.layoutMarginsGuide
        if #available(iOS 26.0, *) { guide = statusBar.layoutGuide(for: .margins(cornerAdaptation: .horizontal)) }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            row.topAnchor.constraint(equalTo: guide.topAnchor),
            row.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            statusBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    private func setUpLayout() {
        split.axis = .horizontal
        split.distribution = .fill
        split.spacing = 1
        split.addArrangedSubview(textView)
        for v in [split, statusBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // Frame-based, placed in viewDidLayoutSubviews: the owl and his bubble.
        view.addSubview(owlSprite)
        view.addSubview(hintBar)
        hintBar.isHidden = true
        hintBar.onClose = { [weak self] in
            self?.bubbleOpen = false
            self?.owl.dismissCurrent()
            self?.showHint()
        }
        hintBar.onNext = { [weak self] in self?.owl.showNext() }
        hintBar.onFix = { [weak self] in self?.applyFix() }
        setUpOwlSprite()
        setUpDivider()
        setUpFocusGestures()
        let g = view.safeAreaLayoutGuide
        splitTrailing = split.trailingAnchor.constraint(equalTo: g.trailingAnchor)
        splitBottom = split.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        splitBottomFocus = split.bottomAnchor.constraint(equalTo: g.bottomAnchor)
        // The text pane's width when the preview is beside it (the seam on
        // the fold of an unfolded iPhone Duo): set in updateSplit().
        textWidth = textView.widthAnchor.constraint(equalToConstant: 100)
        textWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: g.topAnchor),
            // Inside the safe area: clear of a vertical bar at the side, the
            // camera and the rounded corners in landscape.
            split.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            splitTrailing,
            splitBottom,
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSplit()
        updateAskPanelWidth()
        layoutOwl()
        layoutDivider()
    }

    // MARK: Fold (iPhone Duo)

    /// The fold, as the system's "division" reserved regions (iOS 27.1+),
    /// in the view's coordinates: also while the phone is flat open
    /// (.includeInactive), since the crease is still there. None elsewhere.
    func folds() -> [CGRect] {
        if #available(iOS 27.1, *) {
            return view.reservedRegions(kind: .division, options: .includeInactive).map(\.frame)
        }
        return []
    }

    private var rightToLeft: Bool { view.effectiveUserInterfaceLayoutDirection == .rightToLeft }

    private var sideBySide: Bool { previewOn && !focusOn && !textView.isHidden && preview?.view.isHidden == false }

    /// The seam's position now: the drag in progress, else the kept one.
    private var effectiveSplit: SplitPosition { dragFraction.map { .fraction($0) } ?? splitPosition }

    /// Text and preview side by side: the seam where it was put (a drag
    /// snaps to 1/3, 1/2, 2/3 or the fold), by default on the fold when
    /// there is one (an unfolded iPhone Duo), else in the middle.
    private func updateSplit() {
        guard sideBySide else {
            if textWidth.isActive { textWidth.isActive = false }
            return
        }
        let s = PreviewSplit.panes(effectiveSplit, content: split.frame, folds: folds(), spacing: 1, rightToLeft: rightToLeft)
        if split.spacing != s.gap { split.spacing = s.gap }
        if textWidth.constant != s.leading { textWidth.constant = s.leading }
        if !textWidth.isActive { textWidth.isActive = true }
    }

    private func setUpNavigation() {
        navigationItem.title = document.displayName
        navigationItem.style = .editor
        navigationItem.backAction = UIAction { [weak self] _ in self?.closeDocument() }
        navigationItem.documentProperties = UIDocumentProperties(url: document.fileURL)
        navigationItem.largeTitleDisplayMode = .never
        updateBarButtons()
    }

    private func updateBarButtons() {
        let find = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in
            self?.textView.findInteraction?.presentFindNavigator(showingReplace: false)
        })
        find.accessibilityIdentifier = "editor.find"
        find.title = String(localized: "Find")
        // Cedric himself is the owl in the editor's corner (OwlSprite), not
        // a small bar icon; Ask Cedric is also in the overflow menu.
        var items = [find]
        updateUndoItems()
        if SavePolicy.showsSaveButton(saveAutomatically: AppSettings.saveAutomatically) { items.insert(saveItem, at: 0) }
        if document.language.language == .markdown {
            let p = UIBarButtonItem(image: UIImage(systemName: previewOn ? "eye.fill" : "eye"), primaryAction: UIAction { [weak self] _ in
                self?.togglePreview()
            })
            p.title = String(localized: "Preview")
            p.accessibilityIdentifier = "editor.preview"
            items.append(p)
            let f = UIBarButtonItem(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), primaryAction: UIAction { [weak self] _ in
                self?.toggleFocusPreview()
            })
            f.title = String(localized: "Focus Preview")
            f.accessibilityLabel = String(localized: "Focus Preview")
            f.accessibilityIdentifier = "editor.focusPreview"
            items.append(f)
        }
        if focusOn {
            // Only the way back (and the overflow menu).
            let done = UIBarButtonItem(title: String(localized: "Edit"), image: nil, primaryAction: UIAction { [weak self] _ in
                self?.exitFocusPreview()
            })
            done.style = .done
            done.accessibilityHint = String(localized: "Leaves Focus Preview and shows the text.")
            done.accessibilityIdentifier = "editor.focusDone"
            if #available(iOS 27.0, *) { done.visibilityPriority = .high }
            navigationItem.rightBarButtonItems = [done]
            updateEdited()
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] done in
                done(self?.focusMenuItems() ?? [])
            }
            return
        }
        // Which stay when a vertical bar (iPhone Duo) runs out of room.
        if #available(iOS 27.0, *) {
            items.forEach { $0.visibilityPriority = .standard }
            for i in [find, undoItem, redoItem, saveItem] { i.visibilityPriority = .high }
        }
        // Undo and Redo first (leading), then Save, Find, Preview.
        items.insert(contentsOf: [undoItem, redoItem], at: 0)
        navigationItem.rightBarButtonItems = items.reversed()
        updateEdited()
        // The rest in the system's own overflow menu (the ellipsis is
        // reserved for it), not an app-made "More" menu.
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.moreMenuItems() ?? [])
        }
    }

    private func moreMenuItems() -> [UIMenuElement] {
        let save = UIAction(title: String(localized: "Save"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveDocument()
        }
        let revert = revertAction()
        let replace = UIAction(title: String(localized: "Find and Replace"), image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
            self?.textView.findInteraction?.presentFindNavigator(showingReplace: true)
        }
        let goTo = UIAction(title: String(localized: "Go to Line…"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
            self?.goToLine()
        }
        let check = UIAction(title: String(localized: "Check with Cedric"), image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.checkWithCedric()
        }
        let ask = UIAction(title: String(localized: "Ask Cedric"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [weak self] _ in
            self?.askCedric()
        }
        let settings = UIAction(title: String(localized: "Settings"), image: UIImage(systemName: "gear")) { [weak self] _ in
            self?.showSettings()
        }
        var first: [UIMenuElement] = [save, replace, goTo, ask, check]
        if document.language.language == .markdown {
            let focus = UIAction(title: String(localized: "Focus Preview"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.toggleFocusPreview()
            }
            focus.accessibilityIdentifier = "editor.menu.focusPreview"
            first.insert(focus, at: 0)
        }
        if UIApplication.shared.supportsMultipleScenes { first.append(Self.newWindowAction()) }
        return [UIMenu(options: .displayInline, children: first), UIMenu(options: .displayInline, children: [revert]),
                languageMenu(), formatMenu(),
                UIMenu(options: .displayInline, children: [settings])]
    }

    /// The overflow menu in Focus Preview: back to the text, the text size.
    private func focusMenuItems() -> [UIMenuElement] {
        let back = UIAction(title: String(localized: "Exit Focus Preview"), image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
            self?.exitFocusPreview()
        }
        let bigger = UIAction(title: String(localized: "Bigger Text"), image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in
            self?.preview?.bigger()
        }
        let smaller = UIAction(title: String(localized: "Smaller Text"), image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in
            self?.preview?.smaller()
        }
        let actual = UIAction(title: String(localized: "Actual Size"), image: UIImage(systemName: "textformat.size")) { [weak self] _ in
            self?.preview?.actualSize()
        }
        return [UIMenu(options: .displayInline, children: [back]), UIMenu(options: .displayInline, children: [bigger, smaller, actual])]
    }

    // MARK: Text

    private func loadText() {
        loading = true
        let sel = textView.selectedRange
        textView.text = document.text
        textView.font = AppSettings.font(for: traitCollection)
        textView.textColor = UIColor(hex: palette.foreground)
        textView.typingAttributes = [.font: AppSettings.font(for: traitCollection), .foregroundColor: UIColor(hex: palette.foreground)]
        lineIndex = LineIndex(textView.textStorage.string as NSString)
        if NSMaxRange(sel) <= (textView.text as NSString).length { textView.selectedRange = sel }
        loading = false
        colorizer.setLanguage(document.language.language)
        generation += 1
        updateStatus()
        updateBarButtons()
        scheduleOwl()
        refreshPreview()
    }

    @objc private func storageEdited() {
        let textStorage = textView.textStorage
        let edited = textStorage.editedRange, delta = textStorage.changeInLength
        guard textStorage.editedMask.contains(.editedCharacters), !loading else { return }
        let oldRange = NSRange(location: edited.location, length: edited.length - delta)
        let oldLines = lineIndex.lineCount
        let first = lineIndex.replace(oldRange, newLength: edited.length, in: textStorage.string as NSString)
        colorizer?.textDidChange(firstLine: first, lastLine: lineIndex.line(containing: NSMaxRange(edited)),
                                 lineDelta: lineIndex.lineCount - oldLines)
    }

    func textViewDidChange(_ textView: UITextView) {
        generation += 1
        document.updateChangeCount(.done)
        recoveryWriter.textChanged()
        updateUndoItems()
        updateStatus()
        scheduleOwl()
        if previewOn {
            previewTimer?.invalidate()
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreview() }
            }
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) { hideKeyboardButton.isHidden = false }
    func textViewDidEndEditing(_ textView: UITextView) { hideKeyboardButton.isHidden = true }

    /// The hide-keyboard button, Esc and ⌘. on a hardware keyboard (and
    /// still the interactive drag down).
    @objc func hideKeyboard() {
        textView.resignFirstResponder()
        hideKeyboardButton.isHidden = true
    }

    override var keyCommands: [UIKeyCommand]? {
        if focusOn {
            // Esc leaves Focus Preview (nothing else wants it there).
            let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(exitFocusPreview))
            esc.wantsPriorityOverSystemBehavior = true
            return [esc]
        }
        let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(hideKeyboard))
        let dot = UIKeyCommand(title: String(localized: "Hide Keyboard"), action: #selector(hideKeyboard), input: ".", modifierFlags: .command)
        // Esc stays with find and other system uses when they want it.
        esc.wantsPriorityOverSystemBehavior = false
        return [esc, dot]
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateStatus()
        fadeOwlNearCaret()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        colorizer?.scheduleViewport()
        fadeOwlNearCaret()
    }

    private func updateStatus() {
        let sel = textView.selectedRange
        let line = lineIndex.line(containing: min(sel.location, lineIndex.length))
        let col = sel.location - lineIndex.starts[line] + 1
        var s = String(localized: "Ln \(line + 1), Col \(col)")
        if sel.length > 0 { s += " · " + String(localized: "\(sel.length) selected") }
        statusLabel.text = s
        languageButton.setTitle(document.language.displayTitle, for: .normal)
        languageButton.menu = languageMenu()
        formatButton.setTitle("\(document.encoding.displayName) · \(document.lineEnding.rawValue.uppercased())", for: .normal)
        formatButton.menu = formatMenu()
    }

    private func languageMenu() -> UIMenu {
        let current = document.language.language
        let items = Language.allCases.sorted { $0.displayName < $1.displayName }.map { l in
            UIAction(title: l.displayName, state: l == current ? .on : .off) { [weak self] _ in self?.setLanguage(l) }
        }
        return UIMenu(title: String(localized: "Language"), image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), children: items)
    }

    private func formatMenu() -> UIMenu {
        let enc = TextEncoding.allCases.map { e in
            UIAction(title: e.displayName, state: e == document.encoding ? .on : .off) { [weak self] _ in self?.setEncoding(e) }
        }
        let ends = LineEnding.allCases.map { le in
            UIAction(title: le.displayName, state: le == document.lineEnding ? .on : .off) { [weak self] _ in
                guard let self, self.document.lineEnding != le else { return }
                self.document.lineEnding = le
                self.document.updateChangeCount(.done)
                self.updateStatus()
            }
        }
        return UIMenu(title: String(localized: "Encoding and Line Endings"), image: UIImage(systemName: "doc.text"), children: [
            UIMenu(title: String(localized: "Save As Encoding"), options: .displayInline, children: enc),
            UIMenu(title: String(localized: "Line Endings"), options: .displayInline, children: ends),
        ])
    }

    func setLanguage(_ l: Language) {
        document.language.choose(l)
        colorizer.setLanguage(l)
        updateStatus()
        updateBarButtons()
        if l != .markdown, previewOn { togglePreview() }
        scheduleOwl()
    }

    private func setEncoding(_ e: TextEncoding) {
        guard e != document.encoding else { return }
        guard TextCodec.canEncode(textView.text, as: e) else {
            toast(String(localized: "Some characters can’t be saved as \(e.displayName)."))
            return
        }
        document.encoding = e
        document.updateChangeCount(.done)
        updateStatus()
    }

    // MARK: Settings and theme

    @objc private func settingsChanged() {
        applySettings()
        updateBarButtons()
        scheduleOwl()
        showHint()
    }

    private func applySettings() {
        let dark = traitCollection.userInterfaceStyle == .dark
        palette = AppSettings.theme.palette(systemIsDark: dark)
        let bg = UIColor(hex: palette.background)
        textView.backgroundColor = bg
        view.backgroundColor = bg
        textView.tintColor = UIColor(hex: palette.caret)
        textView.keyboardAppearance = palette.isDark ? .dark : .light
        statusBar.backgroundColor = UIColor(hex: palette.statusBar)
        statusLabel.textColor = UIColor(hex: palette.gutterForeground)
        owlSprite.onDark = palette.isDark
        let font = AppSettings.font(for: traitCollection)
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
        }
        textView.typingAttributes[.foregroundColor] = UIColor(hex: palette.foreground)
        applyWrap()
        colorizer?.setPalette(palette)
        refreshPreview()
    }

    private func applyWrap() {
        let c = textView.textContainer
        if AppSettings.wrap {
            c.widthTracksTextView = true
        } else {
            c.widthTracksTextView = false
            c.size = CGSize(width: 20_000, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    // MARK: Owl

    private func scheduleOwl() {
        owl.schedule { [weak self] in self?.owlSnapshot() ?? EditorOwl.Snapshot(text: "", visible: NSRange(), selection: NSRange(),
                                                                                   fileName: nil, language: .plain, generation: 0,
                                                                                   facts: OwlDocumentFacts()) }
    }

    private func owlSnapshot() -> EditorOwl.Snapshot {
        let text = (textView.textStorage.string as NSString).copy() as! NSString
        return EditorOwl.Snapshot(text: text, visible: SyntaxColorizer.visibleRange(textView) ?? NSRange(location: 0, length: text.length),
                                  selection: textView.selectedRange, fileName: document.displayName,
                                  language: document.language.language, generation: generation,
                                  facts: OwlDocumentFacts(isWholeDocument: text.length <= OwlContextWindow.byteCap,
                                                          unsavedSince: document.firstUnsavedEdit, lineEnding: document.lineEnding,
                                                          mixedLineEndings: document.mixedLineEndings,
                                                          languageIsManual: document.language.isManual))
    }

    /// The hints he may show: the offline ones only with the setting on;
    /// ones asked for (Check with Cedric) always.
    private var shownHints: [EditorOwl.Shown] {
        owl.hints.filter { AppSettings.owlHints || $0.hint.source != "rules" }
    }

    /// The hints changed: his badge and pose; the bubble if it is open
    /// (rules hints wait for a tap; a check you asked for opens it).
    private func showHint() {
        // A check you asked for opens his bubble, once per hint.
        if let v = owl.visible, v.hint.source != "rules", v.hint.id != autoOpenedHint {
            autoOpenedHint = v.hint.id
            bubbleOpen = true
        }
        updateOwlBadge()
        guard bubbleOpen, let shown = owl.visible, AppSettings.owlHints || shown.hint.source != "rules" else {
            bubbleOpen = false
            updateOwlBadge()
            guard !hintBar.isHidden else { return }
            UIView.animate(withDuration: 0.2) { self.hintBar.alpha = 0 } completion: { _ in
                if !self.bubbleOpen { self.hintBar.isHidden = true }
            }
            return
        }
        var fixTitle: String?
        if shown.hint.replacement != nil, shown.hint.range != nil { fixTitle = String(localized: "Fix it") }
        if let l = RulesHintProvider.guessedLanguage(shown.hint) { fixTitle = String(localized: "Use \(l.displayName)") }
        if shown.hint.id == RulesHintProvider.saveCopyID { fixTitle = String(localized: "Save") }
        hintBar.show(shown.hint, fixTitle: fixTitle, more: shownHints.count > 1)
        if hintBar.isHidden {
            hintBar.alpha = 0
            hintBar.isHidden = false
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { self.hintBar.alpha = 1 }
    }

    /// Tap on the owl with a hint waiting: his bubble shows it.
    func openHint() {
        guard owl.visible != nil, !focusOn else { return }
        bubbleOpen = true
        showHint()
    }

    func closeHint() {
        bubbleOpen = false
        showHint()
    }

    // MARK: The owl in the corner

    private static let placementKey = "ios.owlPlacement"

    var owlPlacement: OwlPlacement {
        get {
            guard let d = AppSettings.defaults.data(forKey: Self.placementKey),
                  let p = try? JSONDecoder().decode(OwlPlacement.self, from: d) else { return .default }
            return p
        }
        set { AppSettings.defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.placementKey) }
    }

    private func setUpOwlSprite() {
        owlSprite.onTap = { [weak self] in
            guard let self else { return }
            if self.bubbleOpen { self.closeHint() }
            else if self.owl.visible != nil, !self.shownHints.isEmpty { self.openHint() }
            else { self.askCedric() }
        }
        owlSprite.onDoubleTap = { [weak self] in self?.moveOwl(to: .default) }
        owlSprite.onDragBegan = { [weak self] in self?.closeHint() }
        owlSprite.dragArea = { [weak self] in self?.owlArea() ?? .zero }
        owlSprite.onDragEnded = { [weak self] frame in
            guard let self else { return }
            self.moveOwl(to: OwlPlacement.snapped(frameYDown: frame, in: self.owlArea()))
        }
        owlSprite.menuProvider = { [weak self] in self?.owlMenu() ?? UIMenu(children: []) }
        owlSprite.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Ask Cedric")) { [weak self] _ in self?.askCedric(); return true },
            UIAccessibilityCustomAction(name: String(localized: "Reset Position")) { [weak self] _ in self?.moveOwl(to: .default); return true },
        ]
    }

    /// His long-press menu (the Mac's popover).
    private func owlMenu() -> UIMenu {
        let ask = UIAction(title: String(localized: "Ask Cedric"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [weak self] _ in
            self?.askCedric()
        }
        let check = UIAction(title: String(localized: "Check with Cedric"), image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.checkWithCedric()
        }
        let hints = UIAction(title: String(localized: "Offline Hints"), image: UIImage(systemName: "lightbulb"),
                             state: AppSettings.owlHints ? .on : .off) { _ in AppSettings.owlHints.toggle() }
        let reset = UIAction(title: String(localized: "Reset Position"), image: UIImage(systemName: "arrow.down.right.square")) { [weak self] _ in
            self?.moveOwl(to: .default)
        }
        return UIMenu(children: [ask, check, UIMenu(options: .displayInline, children: [hints, reset])])
    }

    /// Where he may sit: the text pane (inside the safe area, above the
    /// status line, which rides on the keyboard), a little in from its edges.
    func owlArea() -> CGRect {
        var area = view.safeAreaLayoutGuide.layoutFrame
        area.size.height = max(0, statusBar.frame.minY - area.minY)
        if !textView.isHidden { area = area.intersection(textView.frame.offsetBy(dx: split.frame.minX, dy: split.frame.minY)) }
        // Never over Ask Cedric's panel (he sat on its Send button).
        area = EditorPanes.owlArea(textPane: area, chat: askPanel?.view.frame)
        // Before the first real layout the area can be empty: insetting an
        // empty rect gives CGRect.null (infinite origin), and a frame from
        // that crashes CALayer (seen on the iPhone Duo simulator).
        guard !area.isNull, !area.isInfinite, area.width > 8, area.height > 8 else { return .zero }
        return area.insetBy(dx: 4, dy: 4)
    }

    private func layoutOwl() {
        // The panes' own frames first: the split lays out its panes after
        // this view, so a panel just opened still had the old text width
        // and he stayed where he was, on the panel.
        split.layoutIfNeeded()
        let area = owlArea()
        guard area.width >= OwlSprite.size, area.height >= OwlSprite.size else {
            // No room beside the chat: out of the way rather than on it.
            if askPanel != nil { owlSprite.isHidden = true }
            return
        }
        let size = CGSize(width: OwlSprite.size, height: OwlSprite.size)
        if !owlSprite.isDragging {
            let f = owlPlacement.frameYDown(in: area, size: size)
            owlSprite.frame = OwlPlacement.avoidingFolds(f, folds: folds(), in: area)
        }
        applyOwlHidden()
        layoutBubble(area: area)
        fadeOwlNearCaret()
    }

    private func layoutBubble(area: CGRect) {
        guard bubbleOpen, !hintBar.isHidden else { return }
        // On his side of the fold.
        let o = owlSprite.frame
        let fold = FoldLayout.crossingFolds(folds(), content: area).first
        let lane = FoldLayout.lane(in: area, folds: folds(), trailing: fold.map { o.midX > $0.midX } ?? true)
        guard lane.width > 60, lane.height > 40 else { return }
        let size = hintBar.fit(width: lane.width - 8)
        let b = OwlPlacement.bubbleYDown(owl: o, size: size, in: lane, avoid: hintedRect())
        hintBar.tailOnTop = b.tailOnTop
        hintBar.tailAtLeft = b.tailAtLeft
        hintBar.frame = b.frame
    }

    /// The lines the shown hint is about, across the view (nil if none or off screen).
    private func hintedRect() -> CGRect? {
        guard let v = owl.visible, let r = v.hint.range,
              let start = textView.position(from: textView.beginningOfDocument, offset: r.location + v.offset),
              let end = textView.position(from: start, offset: r.length),
              let range = textView.textRange(from: start, to: end) else { return nil }
        let rect = textView.firstRect(for: range)
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let inView = textView.convert(rect, to: view)
        return CGRect(x: view.bounds.minX, y: inView.minY, width: view.bounds.width, height: max(inView.height, 12))
    }

    /// Saves where he goes and slides him there (0.16 s, as on the Mac).
    func moveOwl(to place: OwlPlacement) {
        owlPlacement = place
        let area = owlArea()
        guard area.width >= OwlSprite.size, area.height >= OwlSprite.size else { return }
        let f = OwlPlacement.avoidingFolds(place.frameYDown(in: area, size: owlSprite.bounds.size), folds: folds(), in: area)
        if UIAccessibility.isReduceMotionEnabled {
            owlSprite.frame = f
        } else {
            UIView.animate(withDuration: 0.16) { self.owlSprite.frame = f }
        }
        layoutBubble(area: area)
        fadeOwlNearCaret()
    }

    /// He fades while the caret is near him (so he never sits on what you type).
    private func fadeOwlNearCaret() {
        guard !textView.isHidden, let sel = textView.selectedTextRange else { owlSprite.setFaded(false); return }
        let caret = textView.convert(textView.caretRect(for: sel.end), to: view)
        owlSprite.setFaded(caret.insetBy(dx: -28, dy: -18).intersects(owlSprite.frame))
    }

    private var owlBadgeHidden = false

    /// Hidden by his badge state, in Focus Preview, or if he'd touch the chat.
    private func applyOwlHidden() {
        let hide = owlBadgeHidden || EditorPanes.owlHidden(layout: paneLayout, owlFrame: owlSprite.frame, chat: askPanel?.view.frame)
        if owlSprite.isHidden != hide { owlSprite.isHidden = hide }
    }

    private func updateOwlBadge() {
        let count = shownHints.count
        let large = LargeDocument.reason(for: lineIndex) != nil
        let state = OwlBadge.make(hints: count, previous: lastHintCount, bubbleOpen: bubbleOpen,
                                  hintsOn: AppSettings.owlHints || count > 0, largeDocument: large,
                                  reduceMotion: UIAccessibility.isReduceMotionEnabled)
        lastHintCount = count
        owlBadgeHidden = state.hidden
        applyOwlHidden()
        owlSprite.apply(state)
        owlSprite.pose = count > 0 || bubbleOpen ? .talking : .idle
    }

    func applyFix() {
        guard let shown = owl.visible else { return }
        if let l = RulesHintProvider.guessedLanguage(shown.hint) {
            setLanguage(l)
            owl.dismissCurrent()
            return
        }
        if shown.hint.id == RulesHintProvider.saveCopyID {
            saveDocument()
            owl.dismissCurrent()
            return
        }
        guard let fix = owl.fix(in: textView.textStorage.string as NSString),
              let start = textView.position(from: textView.beginningOfDocument, offset: fix.range.location),
              let end = textView.position(from: start, offset: fix.range.length),
              let range = textView.textRange(from: start, to: end) else {
            toast(String(localized: "The text changed since Cedric looked. Try again in a moment."))
            owl.dismissCurrent()
            return
        }
        // Through UITextInput, so it is one undoable edit.
        textView.replace(range, withText: fix.replacement)
        bubbleOpen = false
        owl.dismissCurrent()
    }

    @objc func checkWithCedric() {
        owl.askAI { [weak self] in self!.owlSnapshot() }
        toast(String(localized: "Cedric is looking…"))
    }

    // MARK: Ask Cedric

    @objc func askCedric() {
        // Ask is about the text: Focus Preview ends.
        if focusOn { exitFocusPreview() }
        let snap = owlSnapshot()
        let model = AskCedricModel(text: snap.text as String, selection: snap.selection, visible: snap.visible,
                                   fileName: document.displayName, language: document.language.language)
        model.apply = { [weak self] proposal in self?.apply(proposal) ?? false }
        model.openSettings = { [weak self] in
            guard let self else { return }
            if self.askPanel != nil { self.closeAskPanel(); self.showSettings() }
            else { self.dismiss(animated: true) { self.showSettings() } }
        }
        askModel = model
        // Wide screens (an iPad, an unfolded iPhone Duo): docked beside the
        // text, meeting it at the fold, code on one side and Cedric on the
        // other. Compact: the sheet.
        closeHint()
        if EditorPanes.askPresentation(regularWidth: traitCollection.horizontalSizeClass == .regular) == .panel {
            openAskPanel(model)
            return
        }
        presentAskSheet(model)
    }

    private func presentAskSheet(_ model: AskCedricModel) {
        let host = UIHostingController(rootView: AskCedricView(model: model))
        host.modalPresentationStyle = .formSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.delegate = self
        }
        askSheet = host
        present(host, animated: true)
    }

    private func openAskPanel(_ model: AskCedricModel) {
        closeAskPanel()
        var root = AskCedricView(model: model)
        root.onDone = { [weak self] in self?.closeAskPanel() }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.accessibilityIdentifier = "ask.panel"
        view.insertSubview(host.view, belowSubview: owlSprite)
        let g = view.safeAreaLayoutGuide
        let width = host.view.widthAnchor.constraint(equalToConstant: 360)
        splitTrailing.isActive = false
        splitTrailing = split.trailingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: -1)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: g.topAnchor),
            host.view.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            width, splitTrailing,
        ])
        host.didMove(toParent: self)
        askPanel = host
        askPanelWidth = width
        updateAskPanelWidth()
        // The panel takes the preview's place (never three columns).
        layoutPreview()
        view.setNeedsLayout()
    }

    func closeAskPanel() {
        guard let host = askPanel else { return }
        askModel?.stop()
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        askPanel = nil
        askPanelWidth = nil
        splitTrailing.isActive = false
        splitTrailing = split.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        splitTrailing.isActive = true
        // The preview comes back.
        layoutPreview()
        view.setNeedsLayout()
    }

    /// The panel takes the trailing side of the fold when there is one,
    /// else 40% of the width (at least 340 pt).
    private func updateAskPanelWidth() {
        guard let w = askPanelWidth else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let lane = FoldLayout.lane(in: safe, folds: folds(), trailing: true, rightToLeft: rightToLeft, gap: 0)
        let width = lane.width < safe.width ? lane.width : max(340, safe.width * 0.4)
        let clamped = min(width, max(0, safe.width - 280))
        if w.constant != clamped { w.constant = clamped }
    }

    /// Folded shut with the panel open: it becomes the sheet, same
    /// conversation; unfolded with the sheet up: it becomes the panel (a
    /// form sheet left up on a wide screen showed as a centred card).
    private func updateAskPanelForWidth() {
        let current: EditorPanes.Ask = askPanel != nil ? .panel : askSheet != nil ? .sheet : .none
        guard let model = askModel,
              let want = EditorPanes.askSwitch(from: current, regularWidth: traitCollection.horizontalSizeClass == .regular) else { return }
        if want == .panel {
            guard let sheet = askSheet else { return }
            askSheet = nil
            sheet.dismiss(animated: false) { [weak self] in self?.openAskPanel(model) }
            return
        }
        let host = askPanel
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        askPanel = nil
        askPanelWidth = nil
        splitTrailing.isActive = false
        splitTrailing = split.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        splitTrailing.isActive = true
        presentAskSheet(model)
    }

    /// Applies an Ask Cedric edit if the text it replaces is unchanged.
    private func apply(_ p: OwlEditProposal) -> Bool {
        let ns = textView.textStorage.string as NSString
        guard NSMaxRange(p.range) <= ns.length, ns.substring(with: p.range) == p.original,
              let start = textView.position(from: textView.beginningOfDocument, offset: p.range.location),
              let end = textView.position(from: start, offset: p.range.length),
              let r = textView.textRange(from: start, to: end) else { return false }
        textView.replace(r, withText: p.replacement)
        return true
    }

    // MARK: Preview

    @objc func togglePreview() {
        guard document.language.language == .markdown else { return }
        // ⇧⌘P in Focus Preview: back to the text.
        if focusOn { exitFocusPreview(); return }
        previewOn.toggle()
        if previewOn { makePreview() }
        layoutPreview()
        refreshPreview()
        updateBarButtons()
    }

    private func makePreview() {
        guard preview == nil else { return }
        let p = PreviewController()
        addChild(p)
        p.didMove(toParent: self)
        p.onZoom = { [weak self] (z: Double) in
            let pct = Int((z * 100).rounded())
            self?.zoomNote(String(localized: "Text \(pct)%"))
        }
        preview = p
    }

    /// iPad (regular width): side by side. iPhone: the preview replaces the
    /// text. Focus Preview: the preview alone, everywhere.
    /// Never three columns: Ask Cedric's panel takes the preview's place on
    /// a wide screen (EditorPanes).
    var paneLayout: EditorPanes.Layout {
        EditorPanes.layout(previewOn: previewOn, askOpen: askPanel != nil || askSheet != nil, focus: focusOn,
                           regularWidth: traitCollection.horizontalSizeClass == .regular)
    }

    private func layoutPreview() {
        guard let p = preview else { return }
        let l = paneLayout
        if l.preview {
            let wasShowing = p.view.superview === split && !p.view.isHidden
            if p.view.superview !== split { split.addArrangedSubview(p.view) }
            p.view.isHidden = false
            if !l.text, !textView.isHidden { hideTextKeepingState(previewWasShowing: wasShowing) }
            if l.text, textView.isHidden { showTextRestoringState() }
        } else {
            p.view.isHidden = true
            if textView.isHidden { showTextRestoringState() }
        }
        view.setNeedsLayout()
    }

    /// The text's scroll share (0 top, 1 bottom).
    private var textScrollFraction: Double {
        let i = textView.adjustedContentInset
        return ScrollSync.fraction(offset: textView.contentOffset.y, contentHeight: textView.contentSize.height,
                                   visibleHeight: textView.bounds.height, insetTop: i.top, insetBottom: i.bottom)
    }

    /// The preview takes the whole screen (Focus Preview, or an iPhone Duo
    /// folded shut with the preview on): remember the caret, selection,
    /// scroll and keyboard. A preview that wasn't showing opens at the
    /// text's place.
    private func hideTextKeepingState(previewWasShowing: Bool) {
        continuity = EditorContinuity(selection: textView.selectedRange, contentOffset: textView.contentOffset,
                                      wasEditing: textView.isFirstResponder)
        if let p = preview {
            if !previewWasShowing { p.scrollFraction = textScrollFraction }
            previewFractionAtHide = p.scrollFraction
        }
        textView.resignFirstResponder()
        textView.isHidden = true
    }

    /// The text is back (opened again, the preview turned off, Focus
    /// Preview left): as it was, or, if the preview was scrolled meanwhile,
    /// at the preview's place (the keyboard then stays down, so the caret
    /// doesn't pull the text back).
    private func showTextRestoringState() {
        textView.isHidden = false
        let moved: Double? = {
            guard let at = previewFractionAtHide, let now = preview?.scrollFraction, abs(now - at) > 0.02 else { return nil }
            return now
        }()
        previewFractionAtHide = nil
        guard let c = continuity else { return }
        continuity = nil
        textView.selectedRange = c.restoredSelection(length: (textView.text as NSString).length)
        view.layoutIfNeeded()
        let maxOffset = CGPoint(x: textView.contentSize.width + textView.adjustedContentInset.right - textView.bounds.width,
                                y: textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        if let f = moved {
            let i = textView.adjustedContentInset
            let y = ScrollSync.offset(fraction: f, contentHeight: textView.contentSize.height, visibleHeight: textView.bounds.height,
                                      insetTop: i.top, insetBottom: i.bottom)
            textView.setContentOffset(CGPoint(x: c.restoredOffset(maxOffset: maxOffset).x, y: y), animated: false)
            return
        }
        textView.setContentOffset(c.restoredOffset(maxOffset: maxOffset), animated: false)
        if c.wasEditing { textView.becomeFirstResponder() }
    }

    // MARK: Focus Preview

    /// One tap: the preview alone (turned on if it was off), on any screen.
    @objc func toggleFocusPreview() {
        guard document.language.language == .markdown else { return }
        if focusOn { exitFocusPreview(); return }
        // The preview alone: a docked Ask Cedric panel closes.
        closeAskPanel()
        previewOnBeforeFocus = previewOn
        focusOn = true
        previewOn = true
        makePreview()
        closeHint()
        setFocusChrome(true)
        layoutPreview()
        refreshPreview()
        updateBarButtons()
        updateOwlBadge()
        UIAccessibility.post(notification: .screenChanged, argument: String(localized: "Focus Preview. Edit returns to the text."))
    }

    /// Back to the text: side by side again on a wide screen if the preview
    /// was beside it before; on a phone-sized screen, the text.
    @objc func exitFocusPreview() {
        guard focusOn else { return }
        focusOn = false
        let regular = traitCollection.horizontalSizeClass == .regular
        previewOn = regular && previewOnBeforeFocus
        setFocusChrome(false)
        layoutPreview()
        updateBarButtons()
        updateOwlBadge()
        UIAccessibility.post(notification: .screenChanged, argument: textView)
    }

    /// The status line goes in Focus Preview (the preview runs to the bottom).
    private func setFocusChrome(_ focus: Bool) {
        statusBar.isHidden = focus
        if focus {
            splitBottom.isActive = false
            splitBottomFocus.isActive = true
        } else {
            splitBottomFocus.isActive = false
            splitBottom.isActive = true
        }
        if focus { hintBar.isHidden = true }
        focusGestures.forEach { $0.isEnabled = focus }
        divider.isHidden = true
        view.setNeedsLayout()
    }

    /// Ways back besides Edit and Esc: a swipe down with the preview at its
    /// top, and a swipe in from the leading edge.
    private func setUpFocusGestures() {
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDownInFocus))
        down.direction = .down
        down.delegate = self
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwipedInFocus(_:)))
        edge.edges = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        for g in [down, edge] as [UIGestureRecognizer] {
            g.isEnabled = false
            view.addGestureRecognizer(g)
        }
        focusGestures = [down, edge]
    }

    @objc private func swipedDownInFocus() { exitFocusPreview() }

    @objc private func edgeSwipedInFocus(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .ended, abs(g.translation(in: view).x) > 60 else { return }
        exitFocusPreview()
    }

    /// A short note for the preview's text size (one at a time).
    private weak var zoomLabel: UILabel?
    private func zoomNote(_ text: String) {
        zoomLabel?.removeFromSuperview()
        toast(text)
        zoomLabel = view.subviews.last { $0.accessibilityIdentifier == "editor.toast" } as? UILabel
    }

    // MARK: Resizable split

    private var splitStore: PreviewSplitStore { PreviewSplitStore(defaults: AppSettings.defaults) }

    private func setUpDivider() {
        view.insertSubview(divider, aboveSubview: split)
        divider.isHidden = true
        splitPosition = splitStore.position(regularWidth: traitCollection.horizontalSizeClass == .regular,
                                            regularHeight: traitCollection.verticalSizeClass == .regular)
        divider.onDrag = { [weak self] (x: CGFloat, ended: Bool) in self?.dividerDragged(to: x, ended: ended) }
        divider.onReset = { [weak self] in self?.setSplit(.fold) }
        divider.onStep = { [weak self] (direction: Int) in
            guard let self else { return }
            // Increment gives the preview (the trailing pane) more room.
            self.setSplit(PreviewSplit.step(self.splitPosition, by: -direction, content: self.split.frame, folds: self.folds(),
                                            rightToLeft: self.rightToLeft))
        }
        divider.value = { [weak self] in self?.dividerValue() ?? "" }
    }

    private func dividerValue() -> String {
        let pct = PreviewSplit.previewPercent(splitPosition, content: split.frame, folds: folds(), rightToLeft: rightToLeft)
        if splitPosition == .fold, PreviewSplit.foldFraction(content: split.frame, folds: folds()) != nil {
            return String(localized: "At the fold, preview \(pct)%")
        }
        return String(localized: "Preview \(pct)%")
    }

    private func layoutDivider() {
        guard sideBySide, split.frame.width > 0 else {
            if !divider.isHidden { divider.isHidden = true }
            return
        }
        divider.isHidden = false
        let x = PreviewSplit.seamX(effectiveSplit, content: split.frame, folds: folds(), spacing: 1, rightToLeft: rightToLeft)
        divider.frame = CGRect(x: x - SplitDivider.hitWidth / 2, y: split.frame.minY,
                               width: SplitDivider.hitWidth, height: split.frame.height)
    }

    private func dividerDragged(to x: CGFloat, ended: Bool) {
        let f = PreviewSplit.fraction(seamAt: x, content: split.frame, rightToLeft: rightToLeft)
        guard ended else {
            dragFraction = f
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return
        }
        dragFraction = nil
        setSplit(PreviewSplit.snap(f, content: split.frame, folds: folds(), rightToLeft: rightToLeft))
    }

    /// Moves the seam to `p` (snapped, animated) and keeps it for this size class.
    private func setSplit(_ p: SplitPosition) {
        let changed = p != splitPosition
        splitPosition = p
        splitStore.set(p, regularWidth: traitCollection.horizontalSizeClass == .regular,
                       regularHeight: traitCollection.verticalSizeClass == .regular)
        if changed { UISelectionFeedbackGenerator().selectionChanged() }
        view.setNeedsLayout()
        if UIAccessibility.isReduceMotionEnabled {
            view.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { self.view.layoutIfNeeded() }
        }
        UIAccessibility.post(notification: .layoutChanged, argument: divider)
    }

    private func refreshPreview() {
        guard previewOn, let p = preview else { return }
        p.show(markdown: textView.text, palette: palette)
    }

    // MARK: Commands

    @objc func saveDocument() {
        document.save(to: document.fileURL, for: .forOverwriting) { [weak self] ok in
            if !ok { self?.toast(String(localized: "Couldn’t save \(self?.document.displayName ?? "")")) }
        }
    }

    /// With "Save automatically" off and unsaved changes: Save / Don't
    /// Save / Cancel. Otherwise it closes (autosave saves first when on).
    @objc func closeDocument() {
        guard !closing else { return }
        switch SavePolicy.onClose(saveAutomatically: AppSettings.saveAutomatically, hasUnsavedChanges: document.hasUnsavedChanges) {
        case .close:
            finishClose(saveFirst: false)
        case .ask:
            let a = UIAlertController(title: String(localized: "Save the changes to \(document.displayName)?"),
                                      message: String(localized: "If you don’t save, your changes are lost."), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self] _ in self?.finishClose(saveFirst: true) })
            a.addAction(UIAlertAction(title: String(localized: "Don’t Save"), style: .destructive) { [weak self] _ in
                self?.finishClose(saveFirst: false, discarding: true)
            })
            a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            a.preferredAction = a.actions.first
            present(a, animated: true)
        }
    }

    private func finishClose(saveFirst: Bool, discarding: Bool = false) {
        if saveFirst {
            document.save(to: document.fileURL, for: .forOverwriting) { [weak self] ok in
                guard let self else { return }
                if ok { self.finishClose(saveFirst: false) } else { self.toast(String(localized: "Couldn’t save \(self.document.displayName)")) }
            }
            return
        }
        closing = true
        owl.cancel()
        textView.resignFirstResponder()
        document.close { [weak self] _ in
            guard let self else { return }
            // A clean close: the opened copy goes, and the recovery copy
            // unless the changes are still unsaved (a save that failed).
            self.recoveryWriter.stop(keepingCopy: !discarding && self.document.hasUnsavedChanges)
            self.document.discardOpenedCopy()
            OpenDocuments.paths.remove(self.document.recoveryPath)
            self.dismiss(animated: true)
        }
    }

    // ⌘+, ⌘− and ⌘0 size the preview's text in Focus Preview, the editor's otherwise.
    @objc func biggerFont() { if focusOn { preview?.bigger() } else { AppSettings.fontSize += 1 } }
    @objc func smallerFont() { if focusOn { preview?.smaller() } else { AppSettings.fontSize -= 1 } }
    @objc func actualSizeFont() { if focusOn { preview?.actualSize() } else { AppSettings.resetFontSize() } }
    @objc func toggleWrap() { AppSettings.wrap.toggle() }

    @objc func showSettings() {
        let host = UIHostingController(rootView: SettingsView())
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    @objc func newWindow() {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
    }

    /// New Window as the system's scene activation action: the system
    /// hides or refuses it where a new window can't open (an iPhone Duo's
    /// outer display) instead of the request failing silently.
    static func newWindowAction() -> UIAction {
        UIWindowScene.ActivationAction(title: String(localized: "New Window"), image: UIImage(systemName: "macwindow.badge.plus"),
                                      identifier: nil, alternate: nil) { _ in
            UIWindowScene.ActivationConfiguration(userActivity: NSUserActivity(activityType: "app.owlink.ios.newWindow"))
        }
    }

    @objc func goToLine() {
        let alert = UIAlertController(title: String(localized: "Go to Line"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "1–\(self.lineIndex.lineCount)" }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Go"), style: .default) { [weak self, weak alert] _ in
            guard let self, let n = Int(alert?.textFields?.first?.text ?? ""), n >= 1 else { return }
            let line = min(n, self.lineIndex.lineCount) - 1
            let r = NSRange(location: self.lineIndex.starts[line], length: 0)
            self.textView.selectedRange = r
            self.textView.scrollRangeToVisible(r)
            self.textView.becomeFirstResponder()
        })
        present(alert, animated: true)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(togglePreview) || action == #selector(toggleFocusPreview) {
            return document.language.language == .markdown
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Data safety

    private func barItem(_ title: String, _ symbol: String, _ id: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
        let i = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
        i.title = title
        i.accessibilityLabel = title
        i.accessibilityIdentifier = id
        return i
    }

    @objc private func undoChanged(_ note: Notification) {
        guard let um = note.object as? UndoManager, um === textView.undoManager else { return }
        // After the group is closed (WillClose comes before it is counted).
        DispatchQueue.main.async { [weak self] in self?.updateUndoItems() }
    }

    private func updateUndoItems() {
        let um = textView.undoManager
        undoItem.isEnabled = editGate.isEditable && um?.canUndo ?? false
        redoItem.isEnabled = editGate.isEditable && um?.canRedo ?? false
    }

    /// Sets one reason the text is read-only, and the text view to match.
    func setEditLock(_ reason: EditGate.Reason, _ on: Bool) {
        editGate.set(reason, on)
        applyEditGate()
    }

    private func applyEditGate() {
        let editable = editGate.isEditable
        if textView.isEditable != editable {
            if !editable { textView.resignFirstResponder() }
            textView.isEditable = editable
        }
        updateUndoItems()
    }

    /// "Edited" as soon as there are unsaved changes, gone once saved:
    /// UIDocument's own hasUnsavedChanges, no separate flag.
    func updateEdited() {
        let edited = document.hasUnsavedChanges
        let name = document.displayName
        if #available(iOS 26.0, *) {
            navigationItem.title = name
            navigationItem.subtitle = edited ? String(localized: "Edited") : nil
        } else {
            navigationItem.title = edited ? String(localized: "\(name) — Edited") : name
        }
        view.window?.windowScene?.title = edited ? String(localized: "\(name) — Edited") : name
        saveItem.isEnabled = edited
    }

    var undoBarItem: UIBarButtonItem { undoItem }
    var redoBarItem: UIBarButtonItem { redoItem }
    var saveBarItem: UIBarButtonItem { saveItem }
    /// The Edited mark is showing (the subtitle, or the title before iOS 26).
    var editedShown: Bool {
        let edited = String(localized: "Edited")
        if #available(iOS 26.0, *), navigationItem.subtitle == edited { return true }
        return navigationItem.title?.hasSuffix(edited) == true
    }

    @objc private func enteredBackground() {
        recoveryWriter.writeNow()
    }

    /// Replaces the whole text as one undoable edit (Undo brings it back).
    private func replaceAllText(with text: String) {
        guard let all = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) else { return }
        let g = generation
        textView.replace(all, withText: text)
        if generation == g { textViewDidChange(textView) }
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    private func revertAction() -> UIAction {
        let a = UIAction(title: String(localized: "Revert to Opened Version…"), image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
            self?.confirmRevert()
        }
        a.accessibilityIdentifier = "editor.revert"
        switch document.openedCopy {
        case .kept?:
            break
        case .tooLarge?:
            a.attributes = .disabled
            a.subtitle = String(localized: "Not available for files over 20 MB")
        case .failed?, nil:
            a.attributes = .disabled
            a.subtitle = String(localized: "No copy of the opened version")
        }
        return a
    }

    private func confirmRevert() {
        let a = UIAlertController(title: String(localized: "Revert to the version you opened?"),
                                  message: String(localized: "The text goes back to how \(document.displayName) was when you opened it. You can undo this with Undo."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: String(localized: "Revert"), style: .destructive) { [weak self] _ in self?.revertToOpened() })
        present(a, animated: true)
    }

    func revertToOpened() {
        guard let data = document.openedBytes(), let decoded = TextCodec.decode(data) else {
            toast(String(localized: "Couldn’t read the opened version."))
            return
        }
        replaceAllText(with: decoded.text)
        if document.encoding != decoded.encoding || document.lineEnding != decoded.lineEnding {
            document.encoding = decoded.encoding
            document.lineEnding = decoded.lineEnding
            updateStatus()
        }
        toast(String(localized: "Reverted to the opened version."))
    }

    private func offerRecovered(_ r: RecoveryRecord) {
        let a = RecoveryOffer.alert(for: r) { [weak self] restore in
            if restore { self?.restoreRecovered(r) } else { SaveSafetyStores.recovery.clear(documentPath: r.documentPath) }
        }
        present(a, animated: true)
    }

    /// The unsaved text comes back as an edit (Undo shows the file's text).
    private func restoreRecovered(_ r: RecoveryRecord) {
        replaceAllText(with: r.text)
        document.encoding = r.encoding
        document.lineEnding = r.lineEnding
        updateStatus()
        recoveryWriter.writeNow()
        toast(String(localized: "Restored the unsaved changes."))
    }

    @objc private func documentStateChanged() {
        if document.documentState.contains(.inConflict), conflictResolver == nil, !closing { beginConflict() }
    }

    // MARK: iCloud conflicts

    /// Copies every version (and any unsaved text) first, then asks which
    /// to keep. Editing is off until it is resolved.
    private func beginConflict() {
        let resolver = ConflictResolver(document: document)
        conflictResolver = resolver
        setEditLock(.conflict, true)
        let v = resolver.versions()
        guard !v.others.isEmpty else { endConflict(); return }
        resolver.backUp(v, unsavedText: document.hasUnsavedChanges ? textView.text : nil) { [weak self] failure in
            guard let self else { return }
            if let failure {
                // Nothing resolved and nothing removed: the conflict stays
                // (iCloud keeps every version), and so does the lock.
                self.showAlert(String(localized: "This file has a conflict"), failure.localizedDescription)
                return
            }
            self.askConflict(resolver, v)
        }
    }

    private func askConflict(_ resolver: ConflictResolver, _ v: ConflictResolver.Versions, note: String? = nil) {
        let a = ConflictResolver.chooser(name: document.displayName, v, note: note) { [weak self] choice in
            self?.resolveConflict(choice, resolver, v)
        }
        present(a, animated: true)
    }

    private func resolveConflict(_ choice: ConflictResolution.Choice, _ resolver: ConflictResolver, _ v: ConflictResolver.Versions) {
        resolver.resolve(choice, v) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let f):
                // Ask again: every version is still there (or copied).
                self.askConflict(resolver, v, note: f.localizedDescription)
            case .success(let savedName):
                switch choice {
                case .keepThis:
                    self.toast(String(localized: "Kept this version. A copy of the other version is kept in Owlink."))
                    self.endConflict()
                case .keepBoth:
                    self.toast(String(localized: "Kept this version and saved the other as “\(savedName ?? "")”."))
                    self.endConflict()
                case .keepOther:
                    // The other version is the file now: read it. The text
                    // shown here (saved or not) is copied already.
                    self.recoveryWriter.clear()
                    self.document.revertAfterChoice { [weak self] _ in
                        self?.toast(String(localized: "Kept the other version. A copy of this one is kept in Owlink."))
                        self?.endConflict()
                    }
                }
            }
        }
    }

    private func endConflict() {
        conflictResolver = nil
        setEditLock(.conflict, false)
        // Another conflict may have come in meanwhile.
        if document.documentState.contains(.inConflict),
           NSFileVersion.unresolvedConflictVersionsOfItem(at: document.fileURL)?.isEmpty == false {
            beginConflict()
        }
    }

    private func showAlert(_ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }

    // MARK: Toast

    private func toast(_ text: String) {
        let label = PaddingLabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .label
        // tertiarySystemBackground is white in light mode, the same as the
        // editor, so the toast read as loose text over the code. Use a
        // contrasting fill and a hairline border so it stands out as a pill.
        label.backgroundColor = .secondarySystemBackground
        label.layer.borderWidth = 1
        label.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "editor.toast"
        view.addSubview(label)
        // Inside the safe area, and on one side of an iPhone Duo's fold.
        let lane = FoldLayout.lane(in: view.safeAreaLayoutGuide.layoutFrame, folds: folds(), trailing: true,
                                   rightToLeft: rightToLeft)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.leftAnchor, constant: lane.midX),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: max(120, lane.width - 40)),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.3) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
        }
    }
}

extension EditorViewController: UISheetPresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === askSheet { askSheet = nil }
    }
}

extension EditorViewController {
    /// The swipe down in Focus Preview only with the preview at its top
    /// (otherwise it is a scroll), and alongside the page's own gestures.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let swipe = g as? UISwipeGestureRecognizer, swipe.direction == .down else { return true }
        guard focusOn, let s = preview?.web.scrollView else { return false }
        return s.contentOffset.y <= -s.adjustedContentInset.top + 1
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        focusGestures.contains(g)
    }
}

final class PaddingLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 12, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 24, height: s.height + 16)
    }
}
