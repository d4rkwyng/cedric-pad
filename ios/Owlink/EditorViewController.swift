import UIKit
import SwiftUI
import CedricCore
import CedricAI

/// One open document: a UITextView on an explicit TextKit 2 stack (as the
/// Mac's NSTextView), coloured by the core's highlighter, with the system
/// find and replace (⌘F, ⌥⌘F), a status line (language, encoding, line
/// ending, caret), Cedric's hints, the Markdown preview and Ask Cedric.
final class EditorViewController: UIViewController, UITextViewDelegate {
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
    private let split = UIStackView()
    private(set) var preview: PreviewController?
    private(set) var previewOn = false
    private var generation = 0
    private var loading = false
    private(set) var palette = EditorPalettes.light
    private var previewTimer: Timer?

    init(document: TextDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
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
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.applySettings()
            self.layoutPreview()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.windowScene?.title = document.displayName
        colorizer.colorViewport()
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
        let row = UIStackView(arrangedSubviews: [languageButton, formatButton, UIView(), statusLabel])
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(row)
        statusBar.backgroundColor = .secondarySystemBackground
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: statusBar.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: statusBar.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: statusBar.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    private func setUpLayout() {
        split.axis = .horizontal
        split.distribution = .fillEqually
        split.spacing = 1
        split.addArrangedSubview(textView)
        for v in [split, statusBar, hintBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        hintBar.isHidden = true
        hintBar.onClose = { [weak self] in self?.owl.dismissCurrent() }
        hintBar.onNext = { [weak self] in self?.owl.showNext() }
        hintBar.onFix = { [weak self] in self?.applyFix() }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: g.topAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            hintBar.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: 12),
            hintBar.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -12),
            hintBar.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            hintBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -10),
            hintBar.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        // As wide as it may be: the full width on a phone, 640 pt on an iPad.
        let wide = hintBar.widthAnchor.constraint(equalTo: g.widthAnchor, constant: -24)
        wide.priority = .defaultHigh
        wide.isActive = true
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        statusBar.insetsLayoutMarginsFromSafeArea = true
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
        let ask = UIBarButtonItem(image: UIImage(named: "Owl", in: .owlink, with: nil)?.preparingThumbnail(of: CGSize(width: 28, height: 28))?
            .withRenderingMode(.alwaysOriginal), primaryAction: UIAction { [weak self] _ in self?.askCedric() })
        ask.title = String(localized: "Ask Cedric")
        ask.accessibilityIdentifier = "editor.ask"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu())
        more.accessibilityIdentifier = "editor.more"
        more.title = String(localized: "More")
        var items = [more, ask, find]
        if document.language.language == .markdown {
            let p = UIBarButtonItem(image: UIImage(systemName: previewOn ? "eye.fill" : "eye"), primaryAction: UIAction { [weak self] _ in
                self?.togglePreview()
            })
            p.title = String(localized: "Preview")
            p.accessibilityIdentifier = "editor.preview"
            items.insert(p, at: 1)
        }
        navigationItem.rightBarButtonItems = items
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreMenuItems() ?? []) },
        ])
    }

    private func moreMenuItems() -> [UIMenuElement] {
        let save = UIAction(title: String(localized: "Save"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveDocument()
        }
        let replace = UIAction(title: String(localized: "Find and Replace"), image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
            self?.textView.findInteraction?.presentFindNavigator(showingReplace: true)
        }
        let goTo = UIAction(title: String(localized: "Go to Line…"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
            self?.goToLine()
        }
        let check = UIAction(title: String(localized: "Check with Cedric"), image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.checkWithCedric()
        }
        let window = UIAction(title: String(localized: "New Window"), image: UIImage(systemName: "macwindow.badge.plus")) { _ in
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
        }
        let settings = UIAction(title: String(localized: "Settings"), image: UIImage(systemName: "gear")) { [weak self] _ in
            self?.showSettings()
        }
        var first: [UIMenuElement] = [save, replace, goTo, check]
        if UIApplication.shared.supportsMultipleScenes { first.append(window) }
        return [UIMenu(options: .displayInline, children: first), languageMenu(), formatMenu(),
                UIMenu(options: .displayInline, children: [settings])]
    }

    // MARK: Text

    private func loadText() {
        loading = true
        let sel = textView.selectedRange
        textView.text = document.text
        textView.font = AppSettings.font()
        textView.textColor = UIColor(hex: palette.foreground)
        textView.typingAttributes = [.font: AppSettings.font(), .foregroundColor: UIColor(hex: palette.foreground)]
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
        updateStatus()
        scheduleOwl()
        if previewOn {
            previewTimer?.invalidate()
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreview() }
            }
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) { updateStatus() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { colorizer?.scheduleViewport() }

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
        scheduleOwl()
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
        let font = AppSettings.font()
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

    private func showHint() {
        guard let shown = owl.visible, AppSettings.owlHints || shown.hint.source != "rules" else {
            UIView.animate(withDuration: 0.2) { self.hintBar.alpha = 0 } completion: { _ in
                if self.owl.visible == nil { self.hintBar.isHidden = true }
            }
            return
        }
        var fixTitle: String?
        if shown.hint.replacement != nil, shown.hint.range != nil { fixTitle = String(localized: "Fix it") }
        if let l = RulesHintProvider.guessedLanguage(shown.hint) { fixTitle = String(localized: "Use \(l.displayName)") }
        if shown.hint.id == RulesHintProvider.saveCopyID { fixTitle = String(localized: "Save") }
        hintBar.show(shown.hint, fixTitle: fixTitle, more: owl.hints.count > 1)
        if hintBar.isHidden {
            hintBar.alpha = 0
            hintBar.isHidden = false
        }
        UIView.animate(withDuration: 0.2) { self.hintBar.alpha = 1 }
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
        owl.dismissCurrent()
    }

    @objc func checkWithCedric() {
        owl.askAI { [weak self] in self!.owlSnapshot() }
        toast(String(localized: "Cedric is looking…"))
    }

    // MARK: Ask Cedric

    @objc func askCedric() {
        let snap = owlSnapshot()
        let model = AskCedricModel(text: snap.text as String, selection: snap.selection, visible: snap.visible,
                                   fileName: document.displayName, language: document.language.language)
        model.apply = { [weak self] proposal in self?.apply(proposal) ?? false }
        model.openSettings = { [weak self] in
            self?.dismiss(animated: true) { self?.showSettings() }
        }
        let host = UIHostingController(rootView: AskCedricView(model: model))
        host.modalPresentationStyle = .formSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(host, animated: true)
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
        previewOn.toggle()
        if previewOn, preview == nil {
            let p = PreviewController()
            addChild(p)
            p.didMove(toParent: self)
            preview = p
        }
        layoutPreview()
        refreshPreview()
        updateBarButtons()
    }

    /// iPad (regular width): side by side. iPhone: the preview replaces the text.
    private func layoutPreview() {
        guard let p = preview else { return }
        let regular = traitCollection.horizontalSizeClass == .regular
        if previewOn {
            if p.view.superview !== split { split.addArrangedSubview(p.view) }
            p.view.isHidden = false
            textView.isHidden = !regular
            if !regular { textView.resignFirstResponder() }
        } else {
            p.view.isHidden = true
            textView.isHidden = false
        }
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

    @objc func closeDocument() {
        owl.cancel()
        textView.resignFirstResponder()
        document.close { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    @objc func biggerFont() { AppSettings.fontSize += 1 }
    @objc func smallerFont() { AppSettings.fontSize -= 1 }
    @objc func actualSizeFont() { AppSettings.fontSize = AppSettings.defaultFontSize }
    @objc func toggleWrap() { AppSettings.wrap.toggle() }

    @objc func showSettings() {
        let host = UIHostingController(rootView: SettingsView())
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    @objc func newWindow() {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
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
        if action == #selector(togglePreview) { return document.language.language == .markdown }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func documentStateChanged() {
        if document.documentState.contains(.inConflict) {
            toast(String(localized: "This file was changed on another device. The newest version is kept."))
            if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: document.fileURL) {
                for v in versions { v.isResolved = true }
            }
            try? NSFileVersion.removeOtherVersionsOfItem(at: document.fileURL)
        }
    }

    // MARK: Toast

    private func toast(_ text: String) {
        let label = PaddingLabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .label
        label.backgroundColor = .tertiarySystemBackground
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "editor.toast"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.3) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
        }
    }
}

final class PaddingLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 12, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 24, height: s.height + 16)
    }
}
