import AppKit
import CedricCore

// Cedric: a fast, simple native text editor. AppKit, no storyboard: the
// menus are built here.

@MainActor
func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
          represented: Any? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    i.representedObject = represented
    return i
}

@MainActor
func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    parent.submenu = menu
    return parent
}

@MainActor
func buildMainMenu() -> NSMenu {
    let main = NSMenu()
    let app = "Cedric"

    main.addItem(submenu(app, [
        item(String(localized: "About Cedric"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
        .separator(),
        item(String(localized: "Hide Cedric"), #selector(NSApplication.hide(_:)), "h"),
        item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item(String(localized: "Quit Cedric"), #selector(NSApplication.terminate(_:)), "q"),
    ]))

    main.addItem(submenu(String(localized: "File"), [
        item(String(localized: "New Tab"), #selector(AppDelegate.newTab(_:)), "n"),
        item(String(localized: "New Tab"), #selector(AppDelegate.newTab(_:)), "t"),
        item(String(localized: "New Window"), #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift]),
        item(String(localized: "Open…"), #selector(AppDelegate.openDocument(_:)), "o"),
        .separator(),
        item(String(localized: "Close Tab"), #selector(NSWindow.performClose(_:)), "w"),
        item(String(localized: "Save"), #selector(AppDelegate.saveDocument(_:)), "s"),
        item(String(localized: "Save As…"), #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift]),
    ]))

    let findItems = [
        item(String(localized: "Find…"), #selector(AppDelegate.showFind(_:)), "f"),
        item(String(localized: "Find and Replace…"), #selector(AppDelegate.showReplace(_:)), "f", [.command, .option]),
        item(String(localized: "Find Next"), #selector(AppDelegate.findNextMatch(_:)), "g"),
        item(String(localized: "Find Previous"), #selector(AppDelegate.findPreviousMatch(_:)), "g", [.command, .shift]),
        item(String(localized: "Use Selection for Find"), #selector(AppDelegate.useSelectionForFind(_:)), "e"),
    ]
    main.addItem(submenu(String(localized: "Edit"), [
        item(String(localized: "Undo"), Selector(("undo:")), "z"),
        item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
        item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
        item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
        item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        submenu(String(localized: "Find"), findItems),
        item(String(localized: "Go to Line…"), #selector(AppDelegate.goToLine(_:)), "l"),
    ]))

    main.addItem(submenu(String(localized: "View"), [
        item(String(localized: "Show Preview"), #selector(AppDelegate.togglePreview(_:)), "p", [.command, .option]),
        item(String(localized: "Allow JavaScript in Preview"), #selector(AppDelegate.togglePreviewJavaScript(_:))),
        item(String(localized: "Allow Network in Preview"), #selector(AppDelegate.togglePreviewNetwork(_:))),
        .separator(),
        item(String(localized: "Wrap Lines"), #selector(AppDelegate.toggleWrap(_:)), "z", [.option]),
        item(String(localized: "Show Invisibles"), #selector(AppDelegate.toggleInvisibles(_:)), "i", [.command, .option]),
        item(String(localized: "Show Line Numbers"), #selector(AppDelegate.toggleLineNumbers(_:))),
        .separator(),
        item(String(localized: "Show Cedric the Owl"), #selector(AppDelegate.toggleOwl(_:))),
        submenu(String(localized: "Owl Hint Source"), OwlHintSource.allCases.map {
            item($0 == .rules ? String(localized: "Rules") : String(localized: "Rules + AI"),
                 #selector(AppDelegate.pickOwlHintSource(_:)), represented: $0.rawValue)
        }),
        .separator(),
        item(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn(_:)), "="),
        item(String(localized: "Zoom Out"), #selector(AppDelegate.zoomOut(_:)), "-"),
        item(String(localized: "Actual Size"), #selector(AppDelegate.zoomReset(_:)), "0"),
        .separator(),
        submenu(String(localized: "Theme"), EditorTheme.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickTheme(_:)), represented: $0.rawValue)
        }),
        .separator(),
        item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ]))

    main.addItem(submenu(String(localized: "Format"), [
        submenu(String(localized: "Language"), Language.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickLanguageMenu(_:)), represented: $0.rawValue)
        }),
        submenu(String(localized: "Encoding"), TextEncoding.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickEncodingMenu(_:)), represented: $0.rawValue)
        }),
        submenu(String(localized: "Line Endings"), LineEnding.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickLineEndingMenu(_:)), represented: $0.rawValue)
        }),
    ]))

    let window = submenu(String(localized: "Window"), [
        item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
        .separator(),
        item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
    ])
    main.addItem(window)
    NSApp.windowsMenu = window.submenu
    return main
}

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = buildMainMenu()
    // NSApp.delegate is weak: keep the delegate alive for the whole run
    // (a release build may otherwise free it right after the assignment).
    withExtendedLifetime(delegate) { app.run() }
}

MainActor.assumeIsolated { runApp() }
