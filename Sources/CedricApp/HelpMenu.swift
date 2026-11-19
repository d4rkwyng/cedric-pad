import AppKit

/// Every key equivalent in the main menu, as "⇧⌘T" and its menu path
/// ("File › Reopen Closed Tab"). Used by Help › Keyboard Shortcuts and by
/// CEDRIC_DUMP_SHORTCUTS (which fails on a clash).
@MainActor
enum MenuShortcuts {
    static func name(_ i: NSMenuItem) -> String {
        var s = ""
        let m = i.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || i.keyEquivalent != i.keyEquivalent.lowercased() { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch i.keyEquivalent.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey?: s += "↑"
        case NSDownArrowFunctionKey?: s += "↓"
        case NSLeftArrowFunctionKey?: s += "←"
        case NSRightArrowFunctionKey?: s += "→"
        case 32?: s += "␣"
        case NSF2FunctionKey?: s += "F2"
        default: s += i.keyEquivalent.uppercased()
        }
        return s
    }

    static func list(_ menu: NSMenu? = NSApp.mainMenu) -> [(String, String)] {
        var out: [(String, String)] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for i in menu.items {
                let p = path.isEmpty ? i.title : "\(path) › \(i.title)"
                // Items AppKit adds to Edit (Emoji & Symbols, Dictation) are the system's own.
                let systemAdded = [Selector(("orderFrontCharacterPalette:")), Selector(("startDictation:"))].contains { $0 == i.action }
                if !i.keyEquivalent.isEmpty && !systemAdded { out.append((name(i), p)) }
                if let sub = i.submenu { walk(sub, p) }
            }
        }
        if let menu { walk(menu, "") }
        return out
    }

    /// Shortcuts that aren't menu key equivalents (mouse gestures, and ⎋,
    /// which stays the text view's unless there are several carets):
    /// listed after the menus' in Help › Keyboard Shortcuts.
    static let extraRows: [(String, String)] = [
        ("⌥-drag", String(localized: "Edit › Selection: column selection")),
        ("⌘-click", String(localized: "Edit › Selection: add or remove a caret")),
        ("⎋", String(localized: "Edit › Selection › Single Caret (with several carets)")),
        ("click ▾ / ▸", String(localized: "View › Folding: fold or unfold (the triangles beside the line numbers)")),
    ]
}

/// Help › OwlInk Help (the manual, docs/MANUAL.md on GitHub) and Help › Keyboard
/// Shortcuts (a window listing every menu shortcut). NSApp.helpMenu is
/// set, so macOS adds its menu search field to Help.
extension AppDelegate {
    static let helpURL = URL(string: "https://github.com/d4rkwyng/owlink/blob/main/docs/MANUAL.md")!

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        if let w = ShortcutsWindow.shared { w.makeKeyAndOrderFront(nil); return }
        let rows = MenuShortcuts.list() + MenuShortcuts.extraRows
        let width = rows.map(\.0.count).max() ?? 4
        let body = rows.map { k, p in k.padding(toLength: max(width, 6) + 2, withPad: " ", startingAt: 0) + p }.joined(separator: "\n")
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        w.title = String(localized: "Keyboard Shortcuts")
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            tv.textContainerInset = NSSize(width: 10, height: 10)
            tv.string = body
            tv.setAccessibilityLabel(String(localized: "Keyboard Shortcuts"))
        }
        w.contentView = scroll
        w.center()
        ShortcutsWindow.shared = w
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum ShortcutsWindow {
    static var shared: NSWindow?
}
