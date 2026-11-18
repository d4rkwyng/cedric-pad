import AppKit

// `cedric -w`: the command-line script passes a marker file it created in
// the temp folder (`cedric://open?path=…&wait=<marker>`) and waits while it
// exists; Cedric deletes it when that file's tab closes, or on quit. Only
// files named cedric-wait.* in a temp folder are ever deleted.

extension AppDelegate {
    private static var waiters: [UUID: [String]] = [:]

    static func isWaitMarker(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        let name = (std as NSString).lastPathComponent
        let dir = (std as NSString).deletingLastPathComponent
        let temps = [NSTemporaryDirectory(), "/tmp", "/private/tmp"].map { ($0 as NSString).standardizingPath }
            + [(("/private" + NSTemporaryDirectory()) as NSString).standardizingPath]
        return name.hasPrefix("cedric-wait.") && temps.contains(dir)
    }

    func addWaiter(_ marker: String, for tab: EditorWindowController) { addWaiter(marker, forID: tab.doc.id) }

    /// A tab by its id (a PDF tab's, too).
    func addWaiter(_ marker: String, forID id: UUID) {
        guard Self.isWaitMarker(marker), FileManager.default.fileExists(atPath: marker) else { return }
        Self.waiters[id, default: []].append(marker)
    }

    func releaseWaiters(for id: UUID) {
        for m in Self.waiters.removeValue(forKey: id) ?? [] { try? FileManager.default.removeItem(atPath: m) }
    }

    func releaseAllWaiters() {
        for id in Array(Self.waiters.keys) { releaseWaiters(for: id) }
    }

    /// Who is waiting on a tab (for the checks).
    func waitMarkers(for tab: EditorWindowController) -> [String] { Self.waiters[tab.doc.id] ?? [] }
}
