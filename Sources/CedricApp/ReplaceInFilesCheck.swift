import AppKit

/// CEDRIC_CHECK=replaceinfiles (Scripts/tools-check.sh). Phase 0 stub:
/// the scaffolding is in place (Edit › Replace in Files… ⌥⇧⌘F, Edit ›
/// Undo Replace in Files, both disabled). The feature's subunit replaces
/// this with the real check (plan-0.2.0.md §2, Tests).
@MainActor
extension DevChecks {
    static func replaceInFilesCheck(_ app: AppDelegate) {
        let tab = app.open(write("replace.txt", "replace\n"))!
        sized(tab)
        run([
            sync {
                focus(tab)
                expectScaffold(app, #selector(AppDelegate.replaceInFilesMenu(_:)), "Edit › Replace in Files…", "f", [.command, .option, .shift])
                expectScaffold(app, #selector(AppDelegate.undoReplaceInFilesMenu(_:)), "Edit › Undo Replace in Files")
            },
        ])
    }

    /// A Phase 0 menu item: it exists, has its shortcut (if any) and
    /// validates to disabled until its feature lands.
    static func expectScaffold(_ app: AppDelegate, _ action: Selector, _ name: String,
                               _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
        guard let i = menuItem(action: action) else { expect(false, "\(name) is in the menu"); return }
        let ok = i.keyEquivalent == key && (key.isEmpty || i.keyEquivalentModifierMask == mods)
        expect(ok, "\(name) is in the menu" + (key.isEmpty ? "" : " as \(MenuShortcuts.name(i))"),
               "\(MenuShortcuts.name(i)) \(i.keyEquivalent.unicodeScalars.map { $0.value })")
        expect(!app.validateMenuItem(i), "\(name) is disabled (scaffold)")
    }
}
