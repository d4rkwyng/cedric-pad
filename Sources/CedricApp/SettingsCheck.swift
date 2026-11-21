import AppKit
import CedricCore

/// CEDRIC_CHECK=settings: the tabbed, instant-apply Settings window
/// (0.4.1, UX review #1). Not built at launch, and each tab only when first
/// shown; ⌘, opens it on General the first time; four toolbar tabs whose
/// titles name the window; every popup, field and stepper has a VoiceOver
/// name; each View/Edit menu toggle and its checkbox move together (the
/// menu updates the box, the box updates the menu); Tab moves between the
/// fields; the window reopens on the tab it was left on; Cedric › Cedric AI
/// Settings… opens the Cedric tab, which has no Save or Cancel. Snapshots:
/// settings-general/editor/writing/cedric.png.
@MainActor
extension DevChecks {
    static let toggleActions: [MenuToggleSetting: Selector] = [
        .wrapLines: #selector(AppDelegate.toggleWrap(_:)),
        .showInvisibles: #selector(AppDelegate.toggleInvisibles(_:)),
        .showLineNumbers: #selector(AppDelegate.toggleLineNumbers(_:)),
        .highlightOccurrences: #selector(AppDelegate.toggleHighlightOccurrences(_:)),
        .autoCloseBrackets: #selector(AppDelegate.toggleAutoCloseBrackets(_:)),
        .checkSpellingWhileTyping: #selector(AppDelegate.toggleSpellingWhileTyping(_:)),
        .checkGrammar: #selector(AppDelegate.toggleGrammar(_:)),
    ]

    static func menuItem(_ action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }

    /// What the menu shows for the toggle once validated: a checkmark, or Hide X (on) / Show X (off).
    static func menuShowsOn(_ item: NSMenuItem, _ app: AppDelegate) -> Bool {
        _ = app.validateMenuItem(item)
        return item.title.hasPrefix("Hide ") || (!item.title.hasPrefix("Show ") && item.state == .on)
    }

    static func settingsCheck(_ app: AppDelegate) {
        let restore = keepDefaults(MenuToggleSetting.allCases.map(\.defaultsKey) + ["styleCheck", SettingsPane.defaultsKey])
        let a = app.open(write("a.md", "# Notes\n\nSome text.\n"))!
        sized(a)
        var s: SettingsWindowController? { SettingsWindowController.shared }
        func all(_ v: NSView?) -> [NSView] { guard let v else { return [] }; return v.subviews + v.subviews.flatMap { all($0) } }
        func steps(for pane: SettingsPane) -> [(@escaping () -> Void) -> Void] {
            [
                sync {
                    guard let s else { return }
                    s.select(pane)
                    let title = SettingsWindowController.paneTitle(pane)
                    expect(s.selectedPane == pane && s.window?.title == title, "\(title): selected, and the window is titled \(title)", s.window?.title ?? "-")
                    let content = all(s.panes[pane]?.view)
                    let named = content.filter { $0 is NSPopUpButton || $0 is NSStepper || (($0 as? NSTextField)?.isEditable == true) }
                    let unnamed = named.filter { ($0.accessibilityLabel() ?? "").isEmpty && $0.accessibilityTitleUIElement() == nil }
                    expect(!named.isEmpty || pane == .general, "\(title): has controls (\(named.count) popups, fields, steppers)")
                    expect(unnamed.isEmpty, "\(title): each popup, field and stepper has a VoiceOver name", "\(unnamed.map { String(describing: Swift.type(of: $0)) })")
                    // (Default editor for…'s list scrolls: its boxes may be out of view.)
                    let boxes = content.compactMap { $0 as? NSButton }.filter { $0.bezelStyle != .push && !$0.title.isEmpty && $0.enclosingScrollView == nil }
                    let visible = s.window.map { w in boxes.allSatisfy { NSContainsRect(w.contentView!.bounds, $0.convert($0.bounds, to: w.contentView)) || $0.isHiddenOrHasHiddenAncestor } } ?? false
                    expect(visible, "\(title): the window fits the tab (no control cut off)", "\(s.window?.frame.size ?? .zero)")
                },
                { next in snapshot("settings-\(pane.rawValue).png", window: SettingsWindowController.shared?.window)(next) },
            ]
        }
        var plan: [(@escaping () -> Void) -> Void] = [
            sync {
                expect(SettingsWindowController.shared == nil, "the Settings window isn't built at launch")
                focus(a)
                key(",", [.command])
            },
            sync {
                guard let s else { expect(false, "⌘, opens Settings"); return }
                expect(s.window?.isVisible == true && s.selectedPane == .general, "⌘, opens Settings on General the first time")
                expect(s.window?.toolbar != nil && s.tabs.tabStyle == .toolbar, "the tabs are toolbar items")
                let labels = s.tabs.tabViewItems.map(\.label)
                expect(labels == ["General", "Editor", "Writing", "Cedric"], "four tabs: General, Editor, Writing, Cedric", "\(labels)")
                expect(s.tabs.tabViewItems.allSatisfy { $0.image != nil }, "each tab has an icon")
                expect(s.panes[.cedric]?.isViewLoaded == false && s.ai == nil, "the Cedric tab (and its AI engine list) isn't built until shown")
                expect(s.panes[.editor]?.isViewLoaded == false, "nor is the Editor tab")
            },
        ]
        for p in SettingsPane.allCases { plan += steps(for: p) }
        plan += [
            sync {
                guard let s else { return }
                s.select(.editor)
                // Menu → box, box → menu, for every toggle.
                for t in MenuToggleSetting.allCases {
                    guard let box = s.toggles[t], let sel = toggleActions[t], let item = menuItem(sel) else {
                        expect(false, "\(t.rawValue): box and menu item exist"); continue
                    }
                    if t.pane != s.selectedPane { s.select(t.pane) }
                    let before = Settings.shared[toggle: t]
                    expect((box.state == .on) == before && menuShowsOn(item, app) == before, "\(box.title): box and menu agree (\(before ? "on" : "off"))")
                    NSApp.sendAction(sel, to: app, from: item)
                    expect(Settings.shared[toggle: t] == !before && (box.state == .on) == !before,
                           "\(item.title): the menu item changes the setting and the box follows")
                    box.performClick(nil)
                    expect(Settings.shared[toggle: t] == before && menuShowsOn(item, app) == before,
                           "\(box.title): the box changes it back and the menu shows it")
                    expect(box.window != nil && !box.isHiddenOrHasHiddenAncestor, "\(box.title): on the \(t.pane.rawValue) tab")
                }
            },
            sync {
                // Keyboard: Tab moves through the Writing tab's fields.
                guard let s, let w = s.window else { return }
                s.select(.writing)
                Settings.shared.styleCheck = true
                w.recalculateKeyViewLoop()
                expect(w.makeFirstResponder(s.readableColumns), "the readable width field takes focus")
                var seen: [NSView] = [s.readableColumns]
                var v: NSView? = s.readableColumns.nextValidKeyView
                while let cur = v, !seen.contains(where: { $0 === cur }), seen.count < 30 { seen.append(cur); v = cur.nextValidKeyView }
                expect(seen.contains { $0 === s.styleExtra } && seen.contains { $0 === s.styleExceptions },
                       "Tab reaches Also flag and Never flag", "\(seen.map { String(describing: Swift.type(of: $0)) })")
                Settings.shared.styleCheck = false
            },
            sync {
                guard let s else { return }
                s.select(.writing)
                s.window?.close()
                SettingsWindowController.show()
                expect(s.selectedPane == .writing, "Settings reopens on the tab it was left on (Writing)")
                expect(SettingsWindowController.savedPane == .writing, "…which it remembers")
                s.window?.close()
                NSApp.sendAction(#selector(AppDelegate.showAISettings(_:)), to: app, from: nil)
                expect(s.window?.isVisible == true && s.selectedPane == .cedric, "Cedric › Cedric AI Settings… opens Settings on the Cedric tab")
                let titles = all(s.window?.contentView).compactMap { ($0 as? NSButton)?.title }
                expect(s.ai != nil && titles.contains("Test Connection"), "the Cedric tab holds the AI settings", "\(titles)")
                expect(!titles.contains("Save") && !titles.contains("Cancel"), "no Save or Cancel")
                let windows = NSApp.windows.filter { $0.isVisible && $0.title == "Cedric AI" }
                expect(windows.isEmpty, "no separate Cedric AI window")
                let item = menuItem(#selector(AppDelegate.showAISettings(_:)))
                expect(item?.title == "Cedric AI Settings…", "the Cedric menu keeps Cedric AI Settings…")
            },
            sync {
                s?.window?.close()
                restore()
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
            },
        ]
        run(plan)
    }
}
