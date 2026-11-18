import AppKit
import CedricCore

// `cedric -w`: the command-line script passes a marker file it created in
// the temp folder (`cedric://open?path=…&wait=<marker>`) and waits while it
// exists; Cedric deletes it when that file's tab closes, or on quit. Only
// files named cedric-wait.* in a temp folder are ever deleted.

extension AppDelegate {
    private static var waiters: [UUID: [CLIHandoff.Handoff]] = [:]
    /// At most this many markers held at once (a flood of URLs can't grow it).
    static let waiterLimit = 64

    /// A marker the script made (CLIHandoff: cedric-wait.* in the user's
    /// temp folder, after resolving `..` and symlinks; a regular file with
    /// one link, this user's).
    static func isWaitMarker(_ path: String) -> Bool { CLIHandoff.inspect(path, kind: .wait) != nil }

    func addWaiter(_ marker: String, for tab: EditorWindowController) { addWaiter(marker, forID: tab.doc.id) }

    /// A tab by its id (a PDF tab's, too).
    func addWaiter(_ marker: String, forID id: UUID) {
        guard Self.waiters.values.reduce(0, { $0 + $1.count }) < Self.waiterLimit,
              let h = CLIHandoff.inspect(marker, kind: .wait),
              !Self.waiters.values.contains(where: { $0.contains(h) }) else { return }
        Self.waiters[id, default: []].append(h)
    }

    /// Deletes the tab's markers, each only if it is still the inode checked.
    func releaseWaiters(for id: UUID) {
        for h in Self.waiters.removeValue(forKey: id) ?? [] { CLIHandoff.remove(h) }
    }

    func releaseAllWaiters() {
        for id in Array(Self.waiters.keys) { releaseWaiters(for: id) }
    }

    /// Who is waiting on a tab (for the checks): the markers' resolved paths.
    func waitMarkers(for tab: EditorWindowController) -> [String] { (Self.waiters[tab.doc.id] ?? []).map(\.url.path) }
}
