import AppKit

/// CEDRIC_CHECK=help (Scripts/tools-check.sh): the Help menu is the
/// system's help menu (menu search), with OwlInk Help and Keyboard
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
                expect(titles.contains("OwlInk Help") && titles.contains("Keyboard Shortcuts"), "with OwlInk Help and Keyboard Shortcuts",
                       "\(titles)")
                expect(AppDelegate.helpURL.absoluteString == "https://github.com/d4rkwyng/owlink/blob/main/docs/MANUAL.md", "Help opens the manual")
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
                expect(text.split(separator: "\n").count == MenuShortcuts.list().count + MenuShortcuts.extraRows.count,
                       "every one of them, and the non-menu ones (⌥-drag, ⌘-click, ⎋)")
            },
            { next in snapshot("keyboard-shortcuts.png", window: ShortcutsWindow.shared)(next) },
        ])
    }
}

/// CEDRIC_CHECK=menus: no duplicate items (one visible New Tab, Check
/// Spelling While Typing only in Edit), ⌘N and ⌘T both open a tab, and
/// Wrap Lines is ⌥⌘Z (bare ⌥Z types Ω).
@MainActor
extension DevChecks {
    static func menusCheck(_ app: AppDelegate) {
        let tab = app.open(write("menus.txt", "menus\n"))!
        sized(tab)
        func menu(_ t: String) -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == t }?.submenu }
        func press(_ ch: String) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: ch,
                                           charactersIgnoringModifiers: ch, isARepeat: false, keyCode: keyCodes[Character(ch)] ?? 0)
            else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: e) == true
        }
        run([
            sync {
                let file = menu("File")?.items.filter { !$0.isHidden }.map(\.title) ?? []
                expect(file.filter { $0 == "New Tab" }.count == 1, "File shows New Tab once", "\(file)")
                let view = menu("View")?.items.map(\.title) ?? []
                expect(!view.contains("Check Spelling While Typing"), "View no longer repeats Check Spelling While Typing")
                let wrap = menu("View")?.items.first { $0.title == "Wrap Lines" }
                expect(wrap?.keyEquivalent == "z" && wrap?.keyEquivalentModifierMask == [.command, .option], "Wrap Lines is ⌥⌘Z")
                let before = app.tabs.count
                expect(press("n") && app.tabs.count == before + 1, "⌘N opens a tab", "\(app.tabs.count)")
                expect(press("t") && app.tabs.count == before + 2, "⌘T (hidden alias) still opens a tab", "\(app.tabs.count)")
            },
        ])
    }
}
