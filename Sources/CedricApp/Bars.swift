import AppKit
import CedricCore

/// The find/replace bar above the editor: a find field, an optional
/// replace field, Regex / Match Case / Whole Word toggles, and the match
/// count. Searching is done by the window controller through `FindEngine`.
final class FindBar: NSView, NSSearchFieldDelegate {
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let regexBox = NSButton(checkboxWithTitle: String(localized: "Regex"), target: nil, action: nil)
    let caseBox = NSButton(checkboxWithTitle: String(localized: "Match Case"), target: nil, action: nil)
    let wordBox = NSButton(checkboxWithTitle: String(localized: "Whole Word"), target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    private var replaceRow: NSStackView!

    var onFind: ((_ backwards: Bool) -> Void)?
    var onChange: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?

    var options: FindOptions {
        FindOptions(regex: regexBox.state == .on, caseSensitive: caseBox.state == .on, wholeWord: wordBox.state == .on)
    }

    var showsReplace: Bool {
        get { !replaceRow.isHidden }
        set { replaceRow.isHidden = !newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        findField.placeholderString = String(localized: "Find")
        findField.sendsSearchStringImmediately = true
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldAction)
        replaceField.placeholderString = String(localized: "Replace")
        replaceField.delegate = self
        for b in [regexBox, caseBox, wordBox] {
            b.target = self
            b.action = #selector(optionChanged)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        let prev = button("‹", #selector(previous))
        prev.toolTip = String(localized: "Find Previous (⇧⌘G)")
        let next = button("›", #selector(nextMatch))
        next.toolTip = String(localized: "Find Next (⌘G)")
        let done = button(String(localized: "Done"), #selector(close))
        let findRow = NSStackView(views: [findField, prev, next, regexBox, caseBox, wordBox, status, done])
        findRow.spacing = 8
        let replaceOne = button(String(localized: "Replace"), #selector(replace))
        let replaceAll = button(String(localized: "Replace All"), #selector(replaceAllAction))
        replaceRow = NSStackView(views: [replaceField, replaceOne, replaceAll])
        replaceRow.spacing = 8
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let column = NSStackView(views: [findRow, replaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Only now: the two fields share an ancestor.
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
        ])
        showsReplace = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func findFieldAction() { onChange?() }
    @objc private func optionChanged() { onChange?() }
    @objc private func previous() { onFind?(true) }
    @objc private func nextMatch() { onFind?(false) }
    @objc private func replace() { onReplace?() }
    @objc private func replaceAllAction() { onReplaceAll?() }
    @objc private func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField { onReplace?() } else { onFind?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The status bar: caret position, selection, and pop-up menus for the
/// language, encoding and line ending.
final class StatusBar: NSView {
    let position = NSTextField(labelWithString: "")
    let languageButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let encodingButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let lineEndingButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let zoom = NSTextField(labelWithString: "")
    var background: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        position.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        position.textColor = .secondaryLabelColor
        zoom.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        zoom.textColor = .secondaryLabelColor
        for b in [languageButton, encodingButton, lineEndingButton] {
            b.isBordered = false
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            (b.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [position, spacer, zoom, languageButton, encodingButton, lineEndingButton])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Fills a pull-down: the first item is the title shown.
    static func fill(_ b: NSPopUpButton, title: String, items: [(String, Any?, Bool)], target: AnyObject, action: Selector) {
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for (t, rep, checked) in items {
            if t == "-" { menu.addItem(.separator()); continue }
            if rep == nil, !checked {
                let header = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                continue
            }
            let item = NSMenuItem(title: t, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = rep
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        b.menu = menu
        b.title = title
    }
}
