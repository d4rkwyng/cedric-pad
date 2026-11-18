import AppKit

/// CEDRIC_CHECK=help (Scripts/tools-check.sh): the Help menu is the
/// system's help menu (menu search), with Cedric Pad Help and Keyboard
/// Shortcuts, and the shortcuts window lists the menus' shortcuts.
@MainActor
extension DevChecks {
    static func helpCheck(_ app: AppDelegate) {
        let tab = app.open(write("help.txt", "help\n"))!
        sized(tab)
        run([
            sync {
                let help = NSApp.mainMenu?.items.last
                expect(help?.title == "Help" && NSApp.helpMenu === help?.submenu, "Help is the last menu and the system's help menu")
                let titles = help?.submenu?.items.map(\.title) ?? []
                expect(titles.contains("Cedric Pad Help") && titles.contains("Keyboard Shortcuts"), "with Cedric Pad Help and Keyboard Shortcuts",
                       "\(titles)")
                expect(AppDelegate.helpURL.absoluteString == "https://github.com/d4rkwyng/cedric-pad#readme", "Help opens the README")
                if let i = help?.submenu?.items.firstIndex(where: { $0.title == "Keyboard Shortcuts" }) {
                    help?.submenu?.performActionForItem(at: i)
                }
            },
            sync {
                let w = ShortcutsWindow.shared
                let text = ((w?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
                expect(w?.isVisible == true, "Keyboard Shortcuts opens a window")
                expect(text.contains("⇧⌘T") && text.contains("File › Reopen Closed Tab") && text.contains("⌘S"),
                       "listing the menus' shortcuts", String(text.prefix(120)))
                expect(text.split(separator: "\n").count == MenuShortcuts.list().count, "every one of them")
            },
            { next in snapshot("keyboard-shortcuts.png", window: ShortcutsWindow.shared)(next) },
        ])
    }
}
