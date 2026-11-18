import AppKit
import CedricCore

// Indent and outdent (Tab / ⇧Tab on several lines, ⌘] / ⌘[), and the
// per-tab indentation: Format › Indentation, else what the file already
// uses (read from its first lines the first time it matters, not at
// launch), else Settings' default.

extension EditorWindowController {
    /// The indentation this tab uses now.
    var indentation: Indentation {
        if let manual = doc.indentation { return manual }
        let def = Settings.shared.defaultIndentation
        if doc.detectedIndentation == nil {
            doc.detectedIndentation = .some(Indentation.detect(textView.string as NSString))
        }
        if let found = doc.detectedIndentation ?? nil {
            // A tab's width isn't in the file: the default's.
            return found.usesTabs ? Indentation(usesTabs: true, width: def.width) : found
        }
        // Nothing to go by: YAML and Ruby indent by 2 by convention.
        if !def.usesTabs, def.width == 4, doc.language == .yaml || doc.language == .ruby {
            return Indentation(usesTabs: false, width: 2)
        }
        return def
    }

    /// Whether the Tab key types spaces: only when spaces were chosen
    /// (this tab's pick, the file's own indentation, or a default saved in
    /// Settings). Untouched, Tab types a tab character, as it always has.
    var tabKeyInsertsSpaces: Bool {
        let ind = indentation
        guard !ind.usesTabs else { return false }
        if doc.indentation != nil { return true }
        if case .some(.some) = doc.detectedIndentation { return true }
        return UserDefaults.standard.object(forKey: "indentWithTabs") != nil
    }

    /// How wide a tab is drawn: the tab's own choice, else the default
    /// (needs no detection, so building a tab never scans its text).
    var tabWidth: Int { doc.indentation?.width ?? Settings.shared.defaultIndentation.width }

    /// Indents (⌘], Tab on several lines) or outdents (⌘[, ⇧Tab) every
    /// line the selection touches, as one undo step.
    func shiftLines(right: Bool) {
        guard textView.isEditable, !textView.hasMarkedText() else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let ind = indentation
        let edit = right ? LineOperations.indent(sel, in: ns, unit: ind.unit) : LineOperations.outdent(sel, in: ns, width: ind.width)
        guard let edit else { NSSound.beep(); return }
        apply(edit, actionName: right ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    /// Format › Indentation › Indent Using Spaces / Tabs, Tab Width: for this tab.
    func setIndentation(_ ind: Indentation) {
        doc.indentation = ind
        tabWidthChanged()
        onChange?(self) // kept with the session
    }

    /// Format › Indentation › Convert…: rewrites every line's leading
    /// whitespace to `usesTabs`, as one undo step, and indents that way
    /// from now on.
    func convertIndentation(toTabs: Bool) {
        guard textView.isEditable else { NSSound.beep(); return }
        let from = indentation
        let to = Indentation(usesTabs: toTabs, width: from.width)
        let text = textView.string
        let converted = LineOperations.convertIndentation(text, from: from, to: to)
        doc.indentation = to
        tabWidthChanged()
        guard converted != text else { onChange?(self); return }
        let sel = textView.selectedRange()
        let len = (converted as NSString).length
        apply(TextEdit(range: NSRange(location: 0, length: (text as NSString).length), replacement: converted,
                       selection: NSRange(location: min(sel.location, len), length: 0)),
              actionName: toTabs ? String(localized: "Convert Indentation to Tabs") : String(localized: "Convert Indentation to Spaces"))
    }

    /// The tab stops follow the width: restyle when it changed.
    func tabWidthChanged() {
        let attrs = baseAttributes()
        textView.typingAttributes = attrs
        guard let storage = textView.textStorage, storage.length > 0,
              let para = attrs[.paragraphStyle] as? NSParagraphStyle,
              (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.defaultTabInterval != para.defaultTabInterval
        else { return }
        // One attribute over the whole text, as a theme change does; the
        // colours come back from the highlighter.
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.needsDisplay = true
    }
}

extension AppDelegate {
    @objc func indentLinesMenu(_ sender: Any?) { currentTab?.shiftLines(right: true) }
    @objc func outdentLinesMenu(_ sender: Any?) { currentTab?.shiftLines(right: false) }
    @objc func indentUsingSpacesMenu(_ sender: Any?) {
        guard let t = currentTab else { return }
        t.setIndentation(Indentation(usesTabs: false, width: t.indentation.width))
    }
    @objc func indentUsingTabsMenu(_ sender: Any?) {
        guard let t = currentTab else { return }
        t.setIndentation(Indentation(usesTabs: true, width: t.indentation.width))
    }
    @objc func tabWidthMenu(_ sender: NSMenuItem) {
        guard let t = currentTab, let w = sender.representedObject as? Int else { return }
        t.setIndentation(Indentation(usesTabs: t.indentation.usesTabs, width: w))
    }
    @objc func convertIndentationToSpacesMenu(_ sender: Any?) { currentTab?.convertIndentation(toTabs: false) }
    @objc func convertIndentationToTabsMenu(_ sender: Any?) { currentTab?.convertIndentation(toTabs: true) }

    func validateIndentationItem(_ item: NSMenuItem) -> Bool? {
        let tab = currentTab
        switch item.action {
        case #selector(indentLinesMenu(_:)), #selector(outdentLinesMenu(_:)),
             #selector(convertIndentationToSpacesMenu(_:)), #selector(convertIndentationToTabsMenu(_:)):
            return tab?.textView.isEditable == true
        case #selector(indentUsingSpacesMenu(_:)):
            item.state = tab?.indentation.usesTabs == false ? .on : .off
            return tab != nil
        case #selector(indentUsingTabsMenu(_:)):
            item.state = tab?.indentation.usesTabs == true ? .on : .off
            return tab != nil
        case #selector(tabWidthMenu(_:)):
            item.state = tab.map { (item.representedObject as? Int) == $0.indentation.width } == true ? .on : .off
            return tab != nil
        default: return nil
        }
    }
}
