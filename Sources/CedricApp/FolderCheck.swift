import AppKit

/// CEDRIC_CHECK=folder (Scripts/tools-check.sh). Phase 0 stub: the
/// scaffolding is in place (File › Open Folder… ⇧⌘O, View › Show Folder
/// Sidebar ⌃⌘1, both disabled). The feature's subunit replaces this with
/// the real check (plan-0.2.0.md §6, Tests).
@MainActor
extension DevChecks {
    static func folderCheck(_ app: AppDelegate) {
        let tab = app.open(write("folder.txt", "folder\n"))!
        sized(tab)
        run([
            sync {
                focus(tab)
                expectScaffold(app, #selector(AppDelegate.openFolderMenu(_:)), "File › Open Folder…", "o", [.command, .shift])
                expectScaffold(app, #selector(AppDelegate.toggleFolderSidebarMenu(_:)), "View › Show Folder Sidebar", "1", [.control, .command])
            },
        ])
    }
}
