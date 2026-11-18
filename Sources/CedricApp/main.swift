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

/// Edit › Text Tools, with their key equivalents (⌃⌘ + a letter; ⇧ for
/// the inverse). `CEDRIC_DUMP_SHORTCUTS=1` lists every shortcut and fails
/// on a clash.
let textToolShortcuts: [(TextTool?, String, NSEvent.ModifierFlags)] = [
    (.sortAscending, "s", [.control, .command]),
    (.sortDescending, "s", [.control, .command, .shift]),
    (.sortNumeric, "s", [.control, .command, .option]),
    (.removeDuplicateLines, "r", [.control, .command]),
    (.reverseLines, "r", [.control, .command, .shift]),
    (.joinLines, "j", [.control, .command]),
    (.trimTrailingWhitespace, "w", [.control, .command]),
    (nil, "", []),
    (.uppercase, "u", [.control, .command]),
    (.lowercase, "l", [.control, .command]),
    (.titleCase, "t", [.control, .command]),
    (nil, "", []),
    (.jsonPrettyPrint, "j", [.control, .command, .option]),
    (.jsonMinify, "j", [.control, .command, .option, .shift]),
    (.xmlPrettyPrint, "x", [.control, .command, .option]),
    (nil, "", []),
    (.base64Encode, "b", [.control, .command]),
    (.base64Decode, "b", [.control, .command, .shift]),
    (.urlEncode, "e", [.control, .command]),
    (.urlDecode, "e", [.control, .command, .shift]),
]

@MainActor
func textToolItems() -> [NSMenuItem] {
    textToolShortcuts.map { tool, key, mods in
        guard let tool else { return .separator() }
        return item(tool.displayName, #selector(AppDelegate.textToolMenu(_:)), key, mods, represented: tool.rawValue)
    }
}

/// F2, as a key equivalent (bookmarks, as in Notepad++: F2 / ⇧F2 / ⌘F2).
let f2 = String(UnicodeScalar(UInt16(NSF2FunctionKey))!)

@MainActor
func buildMainMenu() -> NSMenu {
    let main = NSMenu()
    let app = "Cedric"

    // Filled by AppKit with the system's services (Cedric vends none).
    let services = submenu(String(localized: "Services"), [])
    main.addItem(submenu(app, [
        item(String(localized: "About Cedric"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
        .separator(),
        item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","),
        .separator(),
        services,
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
        // Filled by AppDelegate.rebuildRecentMenu from the system recent-documents list.
        submenu(AppDelegate.recentMenuTitle, []),
        // A PDF tab's text in a new editable tab (PDFTab.swift).
        item(String(localized: "Open as Text"), #selector(PDFTabController.openAsText(_:))),
        // Viewer tabs: the file in its default app ("Open in Preview"; ViewerTabs.swift).
        item(String(localized: "Open in Default App"), #selector(ImageTabController.openInDefaultApp(_:))),
        .separator(),
        item(String(localized: "Close Tab"), #selector(NSWindow.performClose(_:)), "w"),
        item(String(localized: "Close Window"), #selector(AppDelegate.closeWindow(_:)), "w", [.command, .shift]),
        item(String(localized: "Reopen Closed Tab"), #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
        item(String(localized: "Save"), #selector(AppDelegate.saveDocument(_:)), "s"),
        item(String(localized: "Save As…"), #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift]),
        item(String(localized: "Save All"), #selector(AppDelegate.saveAll(_:)), "s", [.command, .option]),
        item(String(localized: "Revert to Saved"), #selector(AppDelegate.revertToSaved(_:))),
        .separator(),
        // Files in a git repository with a GitHub remote (GitIntegration.swift).
        item(String(localized: "Open on GitHub"), #selector(AppDelegate.openOnGitHubMenu(_:))),
        item(String(localized: "Copy GitHub Link"), #selector(AppDelegate.copyGitHubLinkMenu(_:))),
        .separator(),
        item(String(localized: "Page Setup…"), #selector(AppDelegate.pageSetup(_:)), "p", [.command, .shift]),
        item(String(localized: "Print…"), #selector(AppDelegate.printDocument(_:)), "p"),
    ]))

    let findItems = [
        item(String(localized: "Find…"), #selector(AppDelegate.showFind(_:)), "f"),
        item(String(localized: "Find and Replace…"), #selector(AppDelegate.showReplace(_:)), "f", [.command, .option]),
        item(String(localized: "Find Next"), #selector(AppDelegate.findNextMatch(_:)), "g"),
        item(String(localized: "Find Previous"), #selector(AppDelegate.findPreviousMatch(_:)), "g", [.command, .shift]),
        item(String(localized: "Use Selection for Find"), #selector(AppDelegate.useSelectionForFind(_:)), "e"),
        .separator(),
        item(String(localized: "Mark All"), #selector(AppDelegate.markAllMenu(_:)), "m", [.control, .command]),
        item(String(localized: "Clear Marks"), #selector(AppDelegate.clearMarksMenu(_:)), "m", [.control, .command, .shift]),
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
        item(String(localized: "Find in Files…"), #selector(AppDelegate.findInFilesMenu(_:)), "f", [.command, .shift]),
        item(String(localized: "Go to Line…"), #selector(AppDelegate.goToLine(_:)), "l"),
        .separator(),
        submenu(String(localized: "Line"), [
            item(String(localized: "Duplicate Line"), #selector(AppDelegate.duplicateLineMenu(_:)), "d", [.command, .shift]),
            item(String(localized: "Move Line Up"), #selector(AppDelegate.moveLineUpMenu(_:)),
                 String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), [.control, .command]),
            item(String(localized: "Move Line Down"), #selector(AppDelegate.moveLineDownMenu(_:)),
                 String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), [.control, .command]),
            item(String(localized: "Delete Line"), #selector(AppDelegate.deleteLineMenu(_:)), "k", [.command, .shift]),
            item(String(localized: "Toggle Comment"), #selector(AppDelegate.toggleCommentMenu(_:)), "/"),
            .separator(),
            item(String(localized: "Indent"), #selector(AppDelegate.indentLinesMenu(_:)), "]"),
            item(String(localized: "Outdent"), #selector(AppDelegate.outdentLinesMenu(_:)), "["),
            .separator(),
            item(String(localized: "Keep Lines Matching…"), #selector(AppDelegate.keepLinesMatchingMenu(_:))),
            item(String(localized: "Delete Lines Matching…"), #selector(AppDelegate.deleteLinesMatchingMenu(_:))),
        ]),
        submenu(String(localized: "Bookmarks"), [
            item(String(localized: "Toggle Bookmark"), #selector(AppDelegate.toggleBookmarkMenu(_:)), f2, [.command]),
            item(String(localized: "Next Bookmark"), #selector(AppDelegate.nextBookmarkMenu(_:)), f2, []),
            item(String(localized: "Previous Bookmark"), #selector(AppDelegate.previousBookmarkMenu(_:)), f2, [.shift]),
            item(String(localized: "Bookmark All Matches"), #selector(AppDelegate.bookmarkAllMatchesMenu(_:)), f2, [.command, .option]),
            item(String(localized: "Clear Bookmarks"), #selector(AppDelegate.clearBookmarksMenu(_:)), f2, [.command, .shift]),
            .separator(),
            item(String(localized: "Copy Bookmarked Lines"), #selector(AppDelegate.copyBookmarkedLinesMenu(_:))),
            item(String(localized: "Delete Bookmarked Lines"), #selector(AppDelegate.deleteBookmarkedLinesMenu(_:))),
        ]),
        submenu(String(localized: "Text Tools"), textToolItems()),
        item(String(localized: "Auto-Close Brackets and Quotes"), #selector(AppDelegate.toggleAutoCloseBrackets(_:))),
        submenu(String(localized: "Spelling and Grammar"), [
            item(String(localized: "Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:)), ":"),
            item(String(localized: "Check Document Now"), #selector(AppDelegate.checkDocumentNow(_:)), ";"),
            item(String(localized: "Fix Typos…"), #selector(AppDelegate.fixTyposMenu(_:)), ";", [.command, .option]),
            .separator(),
            item(String(localized: "Check Spelling While Typing"), #selector(AppDelegate.toggleSpellingWhileTyping(_:))),
        ]),
    ]))

    main.addItem(submenu(String(localized: "View"), [
        item(String(localized: "Show Preview"), #selector(AppDelegate.togglePreview(_:)), "p", [.command, .option]),
        // "Attach Preview" while detached (AppDelegate.validateMenuItem).
        item(String(localized: "Detach Preview"), #selector(AppDelegate.toggleDetachPreview(_:)), "p", [.command, .option, .shift]),
        item(String(localized: "Allow JavaScript in Preview"), #selector(AppDelegate.togglePreviewJavaScript(_:))),
        item(String(localized: "Allow Network in Preview"), #selector(AppDelegate.togglePreviewNetwork(_:))),
        .separator(),
        item(String(localized: "Wrap Lines"), #selector(AppDelegate.toggleWrap(_:)), "z", [.option]),
        item(String(localized: "Show Invisibles"), #selector(AppDelegate.toggleInvisibles(_:)), "i", [.command, .option]),
        item(String(localized: "Show Line Numbers"), #selector(AppDelegate.toggleLineNumbers(_:))),
        item(String(localized: "Highlight Occurrences"), #selector(AppDelegate.toggleHighlightOccurrences(_:))),
        item(String(localized: "Check Spelling While Typing"), #selector(AppDelegate.toggleSpellingWhileTyping(_:))),
        .separator(),
        item(String(localized: "Show Cedric the Owl"), #selector(AppDelegate.toggleOwl(_:))),
        submenu(String(localized: "Owl Hint Source"), OwlHintSource.allCases.map {
            item($0 == .rules ? String(localized: "Rules") : String(localized: "Rules + AI"),
                 #selector(AppDelegate.pickOwlHintSource(_:)), represented: $0.rawValue)
        }),
        item(String(localized: "Cedric AI Settings…"), #selector(AppDelegate.showAISettings(_:))),
        .separator(),
        item(String(localized: "Compare With…"), #selector(AppDelegate.compareWithMenu(_:)), "c", [.command, .option]),
        item(String(localized: "Compare with Last Commit"), #selector(AppDelegate.compareWithLastCommitMenu(_:))),
        item(String(localized: "Next Difference"), #selector(CompareWindowController.nextDifference(_:)),
             String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), [.command, .option]),
        item(String(localized: "Previous Difference"), #selector(CompareWindowController.previousDifference(_:)),
             String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), [.command, .option]),
        item(String(localized: "Follow File"), #selector(AppDelegate.followFileMenu(_:)), "t", [.command, .option]),
        .separator(),
        item(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn(_:)), "="),
        item(String(localized: "Zoom Out"), #selector(AppDelegate.zoomOut(_:)), "-"),
        item(String(localized: "Actual Size"), #selector(AppDelegate.zoomReset(_:)), "0"),
        // PDF tabs only (PDFTab.swift).
        item(String(localized: "Zoom to Fit"), #selector(PDFTabController.zoomToFit(_:)), "9"),
        item(String(localized: "Show Page Thumbnails"), #selector(PDFTabController.togglePDFThumbnails(_:)), "b", [.command, .option]),
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
        submenu(String(localized: "Indentation"), [
            item(String(localized: "Indent Using Spaces"), #selector(AppDelegate.indentUsingSpacesMenu(_:))),
            item(String(localized: "Indent Using Tabs"), #selector(AppDelegate.indentUsingTabsMenu(_:))),
            .separator(),
        ] + Indentation.widths.map {
            item(String(localized: "Tab Width: \($0)"), #selector(AppDelegate.tabWidthMenu(_:)), represented: $0)
        } + [
            .separator(),
            item(String(localized: "Convert Indentation to Spaces"), #selector(AppDelegate.convertIndentationToSpacesMenu(_:))),
            item(String(localized: "Convert Indentation to Tabs"), #selector(AppDelegate.convertIndentationToTabsMenu(_:))),
        ]),
    ]))

    let window = submenu(String(localized: "Window"), [
        item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
        .separator(),
        item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
    ])
    main.addItem(window)
    NSApp.windowsMenu = window.submenu
    NSApp.servicesMenu = services.submenu
    return main
}

@MainActor
func runApp() {
    LaunchTrace.mark("main")
    let app = NSApplication.shared
    LaunchTrace.mark("nsapp")
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    LaunchTrace.mark("policy")
    app.mainMenu = buildMainMenu()
    LaunchTrace.mark("menu_built")
    // NSApp.delegate is weak: keep the delegate alive for the whole run
    // (a release build may otherwise free it right after the assignment).
    withExtendedLifetime(delegate) { app.run() }
}

MainActor.assumeIsolated { runApp() }
