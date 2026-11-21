import AppKit

/// Window › Float on Top (`NSWindow.level = .floating`), per window.
///
/// The set is the user's choice. Full screen changes the live level on
/// its own, so a session saved while full screen must still remember the
/// toggle, and leaving full screen applies the set again: turning it off
/// during full screen has to win over the level AppKit restores.
extension AppDelegate {
    /// The user's choice, for every tab of a window. Not the live level.
    func windowFloats(_ window: NSWindow) -> Bool {
        floatingWindows.contains(ObjectIdentifier(window))
    }

    /// The window the menu acts on: the key document window, or the main
    /// one when the key window is a panel (the command palette is key but
    /// not main). A detached preview, Settings and other panels are not it.
    func floatTargetWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, isFloatableDocument(key) { return key }
        if let main = NSApp.mainWindow, isFloatableDocument(main) { return main }
        return nil
    }

    /// A text tab, a viewer tab, or a compare tab. Not a panel.
    func isFloatableDocument(_ window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        if tabs.contains(where: { $0.window === window }) { return true }
        if viewerTabs.contains(where: { $0.window === window }) { return true }
        if compareWindows.contains(where: { $0.window === window }) { return true }
        return false
    }

    /// Applies `.floating` or `.normal` from the set.
    ///
    /// Measured with AppKit: `.normal` is 0, `.floating` is 3, `.modalPanel`
    /// is 8. A child ordered above its parent (the command palette) and a
    /// sheet stay above a `.floating` parent, and they move with it when
    /// the parent changes level. Raising the palette above `.floating`
    /// puts it over a sheet. Do not use a higher level.
    func applyFloatLevel(_ window: NSWindow) {
        // Full screen sets the level itself. didExitFullScreen applies this again.
        guard !window.styleMask.contains(.fullScreen) else { return }
        let level: NSWindow.Level = windowFloats(window) ? .floating : .normal
        if window.level != level { window.level = level }
    }

    /// Every tab of `window` (a tab group is one window to the menu).
    func setWindowFloats(_ on: Bool, _ window: NSWindow) {
        let members = window.tabbedWindows ?? [window]
        for w in members {
            if on { floatingWindows.insert(ObjectIdentifier(w)) }
            else { floatingWindows.remove(ObjectIdentifier(w)) }
            applyFloatLevel(w)
        }
    }

    /// `window` just joined `host`'s tab group. It follows that group's choice.
    func adoptFloat(of host: NSWindow?, for window: NSWindow) {
        guard let host, host !== window else { return }
        let group = host.tabbedWindows ?? [host]
        guard group.contains(where: { windowFloats($0) }) else { return }
        for w in group {
            floatingWindows.insert(ObjectIdentifier(w))
            applyFloatLevel(w)
        }
        floatingWindows.insert(ObjectIdentifier(window))
        applyFloatLevel(window)
    }

    @objc func toggleFloatOnTop(_ sender: Any?) {
        guard let window = floatTargetWindow() else { return }
        setWindowFloats(!windowFloats(window), window)
    }

    /// AppKit may restore the pre-fullscreen level, including `.floating`
    /// after the user turned the toggle off. The set wins.
    @objc func windowExitedFullScreen(_ note: Notification) {
        guard let window = note.object as? NSWindow, isFloatableDocument(window) else { return }
        for w in window.tabbedWindows ?? [window] { applyFloatLevel(w) }
    }

    /// A closed window's address can be reused. Drop it so the next window there starts off.
    @objc func noteWindowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        floatingWindows.remove(ObjectIdentifier(window))
    }
}
