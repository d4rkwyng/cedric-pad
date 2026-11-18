import AppKit
import CedricCore

/// Cedric › Settings… (⌘,): the app-wide preferences in one window. Built
/// the first time it is opened, never at launch. Every control writes
/// straight to `Settings` (which restyles the open tabs); the View and
/// Edit menu toggles stay, and the window follows them while it is open.
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
    let wrap = NSButton(checkboxWithTitle: String(localized: "Wrap lines"), target: nil, action: nil)
    let invisibles = NSButton(checkboxWithTitle: String(localized: "Show invisibles"), target: nil, action: nil)
    let lineNumbers = NSButton(checkboxWithTitle: String(localized: "Show line numbers"), target: nil, action: nil)
    let occurrences = NSButton(checkboxWithTitle: String(localized: "Highlight occurrences"), target: nil, action: nil)
    let gitChanges = NSButton(checkboxWithTitle: String(localized: "Show git changes in the gutter"), target: nil, action: nil)
    let autoClose = NSButton(checkboxWithTitle: String(localized: "Auto-close brackets and quotes"), target: nil, action: nil)
    let spelling = NSButton(checkboxWithTitle: String(localized: "Check spelling while typing"), target: nil, action: nil)
    let indentKind = NSPopUpButton()
    let tabWidth = NSPopUpButton()
    private var observer: NSObjectProtocol?

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

        for b in [wrap, invisibles, lineNumbers, occurrences, gitChanges, autoClose, spelling] { b.target = self; b.action = #selector(changed(_:)) }
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

        let grid = NSGridView(views: [
            [label(String(localized: "Theme:")), theme],
            [label(String(localized: "Font:")), fontRow],
            [label(String(localized: "View:")), wrap],
            [NSGridCell.emptyContentView, invisibles],
            [NSGridCell.emptyContentView, lineNumbers],
            [NSGridCell.emptyContentView, occurrences],
            [NSGridCell.emptyContentView, gitChanges],
            [label(String(localized: "Editing:")), autoClose],
            [NSGridCell.emptyContentView, spelling],
            [label(String(localized: "Indent with:")), indentRow],
            [NSGridCell.emptyContentView, note],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
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
        wrap.state = s.wrapLines ? .on : .off
        invisibles.state = s.showInvisibles ? .on : .off
        lineNumbers.state = s.showLineNumbers ? .on : .off
        occurrences.state = s.highlightOccurrences ? .on : .off
        gitChanges.state = s.showGitChanges ? .on : .off
        autoClose.state = s.autoCloseBrackets ? .on : .off
        spelling.state = s.checkSpellingWhileTyping ? .on : .off
        let ind = s.defaultIndentation
        indentKind.selectItem(at: ind.usesTabs ? 1 : 0)
        tabWidth.selectItem(withTag: ind.width)
    }

    @objc private func stepped(_ sender: NSStepper) {
        fontSize.integerValue = sender.integerValue
        changed(fontSize)
    }

    @objc func changed(_ sender: Any?) {
        let s = Settings.shared
        switch sender as? NSObject {
        case theme: if let raw = theme.selectedItem?.representedObject as? String, let t = EditorTheme(rawValue: raw) { s.theme = t }
        case fontPopup: s.fontName = fontNames[max(0, fontPopup.indexOfSelectedItem)]
        case fontSize: if fontSize.integerValue >= 6 { s.fontSize = CGFloat(fontSize.integerValue) }
        case wrap: s.wrapLines = wrap.state == .on
        case invisibles: s.showInvisibles = invisibles.state == .on
        case lineNumbers: s.showLineNumbers = lineNumbers.state == .on
        case occurrences: s.highlightOccurrences = occurrences.state == .on
        case gitChanges: s.showGitChanges = gitChanges.state == .on
        case autoClose: s.autoCloseBrackets = autoClose.state == .on
        case spelling: s.checkSpellingWhileTyping = spelling.state == .on
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
