import AppKit
import CedricCore

/// Cedric › Settings… (⌘,): the preferences that have no menu of their
/// own (0.2.1: each option lives in one place; settings-audit.md). Built
/// the first time it is opened, never at launch. Every control writes
/// straight to `Settings` (which restyles the open tabs). The View and
/// Edit menu toggles (wrap, invisibles, line numbers, occurrences,
/// auto-close, spelling, grammar) are only in those menus.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var shared: SettingsWindowController?

    static func show() {
        let c = shared ?? SettingsWindowController()
        shared = c
        c.refresh()
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    let theme = NSPopUpButton()
    let fontPopup = NSPopUpButton()
    let fontSize = NSTextField()
    let fontStepper = NSStepper()
    let gitChanges = NSButton(checkboxWithTitle: String(localized: "Show git changes in the gutter"), target: nil, action: nil)
    let quitOnLastClose = NSButton(checkboxWithTitle: String(localized: "Quit when the last window closes"), target: nil, action: nil)
    let owlChat = NSButton(checkboxWithTitle: String(localized: "Ask Cedric"), target: nil, action: nil)
    let styleTips = NSButton(checkboxWithTitle: String(localized: "Style tips in code"), target: nil, action: nil)
    let indentKind = NSPopUpButton()
    let tabWidth = NSPopUpButton()
    /// View › Readable Width's column, in characters (ReadableWidthView.swift).
    let readableColumns = NSTextField()
    let readableStepper = NSStepper()
    private var observer: NSObjectProtocol?
    /// Default editor for… (0.3.0), below the form.
    private(set) var defaultEditor: DefaultEditorPane!

    /// The font menu's families: fixed-pitch fonts installed (read when the
    /// window is built). Tag 0 is the system's monospaced font.
    private var fontNames: [String?] = [nil]

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable],
                         backing: .buffered, defer: true)
        w.title = String(localized: "Settings")
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.identifier = NSUserInterfaceItemIdentifier("CedricSettings")
        super.init(window: w)
        w.delegate = self
        build()
        observer = NotificationCenter.default.addObserver(forName: .cedricAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        for t in EditorTheme.allCases { theme.addItem(withTitle: t.displayName); theme.lastItem?.representedObject = t.rawValue }
        theme.target = self; theme.action = #selector(changed(_:))

        let fm = NSFontManager.shared
        let mono = (fm.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { NSFont(name: $0, size: 13) }
            .filter { ($0.fontDescriptor.symbolicTraits.contains(.monoSpace)) }
        // One entry per family: its regular face.
        var byFamily: [String: NSFont] = [:]
        for f in mono {
            let fam = f.familyName ?? f.fontName
            if let cur = byFamily[fam], cur.fontName.count <= f.fontName.count { continue }
            byFamily[fam] = f
        }
        fontPopup.addItem(withTitle: String(localized: "SF Mono (System)"))
        for fam in byFamily.keys.sorted() where fam != "SF Mono" {
            fontPopup.addItem(withTitle: fam)
            fontNames.append(byFamily[fam]!.fontName)
        }
        // A font chosen elsewhere (or no longer fixed-pitch) still shows.
        if let cur = Settings.shared.fontName, !fontNames.contains(cur) {
            fontPopup.addItem(withTitle: NSFont(name: cur, size: 13)?.displayName ?? cur)
            fontNames.append(cur)
        }
        fontPopup.target = self; fontPopup.action = #selector(changed(_:))
        fontSize.alignment = .right
        fontSize.target = self; fontSize.action = #selector(changed(_:))
        fontSize.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fontStepper.minValue = 6; fontStepper.maxValue = 72; fontStepper.increment = 1
        fontStepper.target = self; fontStepper.action = #selector(stepped(_:))
        let fontRow = NSStackView(views: [fontPopup, fontSize, fontStepper, NSTextField(labelWithString: "pt")])
        fontRow.spacing = 6

        for b in [gitChanges, owlChat, styleTips, quitOnLastClose] { b.target = self; b.action = #selector(changed(_:)) }
        indentKind.addItems(withTitles: [String(localized: "Spaces"), String(localized: "Tabs")])
        indentKind.target = self; indentKind.action = #selector(changed(_:))
        for wdt in Indentation.widths { tabWidth.addItem(withTitle: "\(wdt)"); tabWidth.lastItem?.tag = wdt }
        tabWidth.target = self; tabWidth.action = #selector(changed(_:))
        let indentRow = NSStackView(views: [indentKind, NSTextField(labelWithString: String(localized: "width")), tabWidth])
        indentRow.spacing = 6
        let note = NSTextField(wrappingLabelWithString: String(localized: "For new files and files that don't indent yet; a file's own indentation wins. Format › Indentation changes one tab."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300

        readableColumns.alignment = .right
        readableColumns.target = self; readableColumns.action = #selector(changed(_:))
        readableColumns.widthAnchor.constraint(equalToConstant: 44).isActive = true
        readableColumns.toolTip = String(localized: "How wide View › Readable Width's column is, in characters (\(ReadableWidth.columnRange.lowerBound)–\(ReadableWidth.columnRange.upperBound)).")
        readableStepper.minValue = Double(ReadableWidth.columnRange.lowerBound)
        readableStepper.maxValue = Double(ReadableWidth.columnRange.upperBound)
        readableStepper.increment = 1
        readableStepper.target = self; readableStepper.action = #selector(stepped(_:))
        let readableRow = NSStackView(views: [readableColumns, readableStepper, NSTextField(labelWithString: String(localized: "characters"))])
        readableRow.spacing = 6

        let elsewhere = NSTextField(wrappingLabelWithString: String(localized: "Wrap lines, invisibles, line numbers and occurrences are in the View menu; auto-close, spelling and grammar in the Edit menu."))
        elsewhere.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        elsewhere.textColor = .secondaryLabelColor
        elsewhere.preferredMaxLayoutWidth = 300

        let grid = NSGridView(views: [
            [label(String(localized: "Theme:")), theme],
            [label(String(localized: "Font:")), fontRow],
            [label(String(localized: "Default indent:")), indentRow],
            [NSGridCell.emptyContentView, note],
            [label(String(localized: "Readable width:")), readableRow],
            [label(String(localized: "Gutter:")), gitChanges],
            [label(String(localized: "Cedric:")), owlChat],
            [NSGridCell.emptyContentView, styleTips],
            [label(String(localized: "App:")), quitOnLastClose],
            [NSGridCell.emptyContentView, elsewhere],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        defaultEditor = DefaultEditorPane()
        let pane = defaultEditor.view
        pane.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rule)
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rule.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            pane.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 12),
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            pane.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            pane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
        // As tall as the form (the rows keep their natural spacing).
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(content.fittingSize)
    }

    /// Shows the current settings.
    func refresh() {
        let s = Settings.shared
        theme.selectItem(at: EditorTheme.allCases.firstIndex(of: s.theme) ?? 0)
        fontPopup.selectItem(at: fontNames.firstIndex(of: s.fontName) ?? 0)
        fontSize.integerValue = Int(s.fontSize)
        fontStepper.integerValue = Int(s.fontSize)
        gitChanges.state = s.showGitChanges ? .on : .off
        quitOnLastClose.state = s.quitWhenLastWindowCloses ? .on : .off
        owlChat.state = s.owlChat ? .on : .off
        styleTips.state = s.owlStyleTips ? .on : .off
        styleTips.toolTip = String(localized: "Cedric’s style suggestions for code, on top of his checks for code that breaks or does the wrong thing (those are always on). Off by default.")
        let autoGrammar = s.checkGrammar && OwlHub.shared.ai.isActive && OwlHub.shared.ai.isAutomatic
        owlChat.toolTip = String(localized: "Ask Cedric… (⌥⌘/, or click the owl): questions, quick actions and proposed edits from a local AI engine (Apple Intelligence, the built-in model, or your LM Studio / Ollama). On by default when one is ready.")
            + " " + AskCedricEngine.privacy(autoGrammar: autoGrammar).settingsSentence
        let ind = s.defaultIndentation
        indentKind.selectItem(at: ind.usesTabs ? 1 : 0)
        tabWidth.selectItem(withTag: ind.width)
        readableColumns.integerValue = s.readableColumns
        readableStepper.integerValue = s.readableColumns
        defaultEditor?.refresh()
    }

    /// Back from Finder's Get Info (or another app): show the defaults as they are now.
    func windowDidBecomeKey(_ notification: Notification) { defaultEditor?.refresh() }

    @objc private func stepped(_ sender: NSStepper) {
        if sender === readableStepper {
            readableColumns.integerValue = sender.integerValue
            changed(readableColumns)
            return
        }
        fontSize.integerValue = sender.integerValue
        changed(fontSize)
    }

    @objc func changed(_ sender: Any?) {
        let s = Settings.shared
        switch sender as? NSObject {
        case theme: if let raw = theme.selectedItem?.representedObject as? String, let t = EditorTheme(rawValue: raw) { s.theme = t }
        case fontPopup: s.fontName = fontNames[max(0, fontPopup.indexOfSelectedItem)]
        case fontSize: if fontSize.integerValue >= 6 { s.fontSize = CGFloat(fontSize.integerValue) }
        case readableColumns: if readableColumns.integerValue > 0 { s.readableColumns = readableColumns.integerValue }
        case gitChanges: s.showGitChanges = gitChanges.state == .on
        case quitOnLastClose: s.quitWhenLastWindowCloses = quitOnLastClose.state == .on
        case owlChat: s.owlChat = owlChat.state == .on
        case styleTips: s.owlStyleTips = styleTips.state == .on
        case indentKind, tabWidth:
            s.defaultIndentation = Indentation(usesTabs: indentKind.indexOfSelectedItem == 1, width: tabWidth.selectedTag() > 0 ? tabWidth.selectedTag() : 4)
        default: break
        }
        refresh()
    }
}

extension AppDelegate {
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show() }
}
