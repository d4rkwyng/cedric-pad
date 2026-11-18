import AppKit
import CedricCore

// Format › Markdown: bold, italic, strikethrough, inline code and link
// (MarkdownFormat in CedricCore). Each is one undo step, and only for
// Markdown tabs.

extension EditorWindowController {
    var markdownEditable: Bool { doc.language == .markdown && textView.isEditable && !textView.hasMarkedText() }

    func toggleMarkdown(_ style: MarkdownFormat.Style) {
        guard markdownEditable else { NSSound.beep(); return }
        let e = MarkdownFormat.toggle(style, in: textView.string as NSString, selection: textView.selectedRange())
        let names: [MarkdownFormat.Style: String] = [.bold: String(localized: "Bold"), .italic: String(localized: "Italic"),
                                                     .strikethrough: String(localized: "Strikethrough"), .code: String(localized: "Inline Code")]
        apply(e, actionName: names[style] ?? "")
    }

    /// ⌘↩: checks or unchecks the task boxes on the selected lines.
    func toggleCheckboxes() {
        guard markdownEditable,
              let e = MarkdownLists.toggleTasks(in: textView.string as NSString, selection: textView.selectedRange()) else { NSSound.beep(); return }
        apply(e, actionName: String(localized: "Toggle Checkbox"))
    }

    func markdownLink() {
        guard markdownEditable else { NSSound.beep(); return }
        let clip = NSPasteboard.general.string(forType: .string)
        apply(MarkdownFormat.link(in: textView.string as NSString, selection: textView.selectedRange(), clipboard: clip),
              actionName: String(localized: "Link"))
    }
}

extension AppDelegate {
    @objc func markdownBoldMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.bold) }
    @objc func markdownItalicMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.italic) }
    @objc func markdownStrikethroughMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.strikethrough) }
    @objc func markdownCodeMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.code) }
    @objc func markdownLinkMenu(_ sender: Any?) { currentTab?.markdownLink() }
    @objc func toggleCheckboxMenu(_ sender: Any?) { currentTab?.toggleCheckboxes() }

    static let markdownActions: Set<Selector> = [
        #selector(markdownBoldMenu(_:)), #selector(markdownItalicMenu(_:)), #selector(markdownStrikethroughMenu(_:)),
        #selector(markdownCodeMenu(_:)), #selector(markdownLinkMenu(_:)), #selector(toggleCheckboxMenu(_:)),
    ]

    func validateMarkdownItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action, Self.markdownActions.contains(action) else { return nil }
        guard let tab = currentTab else { return false }
        return tab.doc.language == .markdown && tab.textView.isEditable
    }
}

/// Format › Markdown, built with the main menu.
@MainActor
func markdownMenu() -> NSMenuItem {
    submenu(String(localized: "Markdown"), [
        item(String(localized: "Bold"), #selector(AppDelegate.markdownBoldMenu(_:)), "b"),
        item(String(localized: "Italic"), #selector(AppDelegate.markdownItalicMenu(_:)), "i"),
        item(String(localized: "Strikethrough"), #selector(AppDelegate.markdownStrikethroughMenu(_:)), "x", [.command, .shift]),
        item(String(localized: "Inline Code"), #selector(AppDelegate.markdownCodeMenu(_:)), "`", [.control]),
        item(String(localized: "Link"), #selector(AppDelegate.markdownLinkMenu(_:)), "k"),
        .separator(),
        item(String(localized: "Toggle Checkbox"), #selector(AppDelegate.toggleCheckboxMenu(_:)), "\r"),
    ])
}
