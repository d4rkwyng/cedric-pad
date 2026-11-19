import CoreServices
import Foundation

/// FSEvents on the folder sidebar's root (plan-0.2.0.md §6). Directory
/// level only (no per-file events): enough to know which folder changed,
/// coalesced by a 0.3 s latency. Runs only while a folder is open and the
/// sidebar shows; `stop()` (or deinit) ends the stream.
final class FolderWatcher: @unchecked Sendable {
    enum Change: Sendable {
        /// The contents of this folder (a real path) changed.
        case folder(String)
        /// Events were dropped or coalesced under this folder: re-list
        /// everything loaded below it.
        case subtree(String)
        /// The root itself was moved or deleted.
        case rootChanged
    }

    let root: String
    private var stream: FSEventStreamRef?
    /// What the C callback gets: the handler, retained by the stream's
    /// context until the stream is gone (never `self`, which may be going).
    private final class Box { let handler: @Sendable ([Change]) -> Void; init(_ h: @escaping @Sendable ([Change]) -> Void) { handler = h } }
    private var box: Unmanaged<Box>?
    private let queue = DispatchQueue(label: "cedric.folder-watcher", qos: .utility)
    private let handler: @Sendable ([Change]) -> Void
    /// Streams started (the check asserts the stream stops when hidden).
    nonisolated(unsafe) static var running = 0

    /// `handler` is called on the main queue.
    init(root: String, handler: @escaping @Sendable ([Change]) -> Void) {
        self.root = root
        self.handler = handler
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        let b = Unmanaged.passRetained(Box(handler))
        var ctx = FSEventStreamContext(version: 0, info: b.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes: [Change] = []
            for i in 0..<min(count, list.count) {
                let f = Int(eventFlags[i])
                let p = list[i].hasSuffix("/") && list[i].count > 1 ? String(list[i].dropLast()) : list[i]
                if f & kFSEventStreamEventFlagRootChanged != 0 {
                    changes.append(.rootChanged)
                } else if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    changes.append(.subtree(p))
                } else {
                    changes.append(.folder(p))
                }
            }
            guard !changes.isEmpty else { return }
            let h = me.handler
            DispatchQueue.main.async { h(changes) }
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(flags)) else {
            b.release()
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            b.release()
            return
        }
        stream = s
        box = b
        Self.running += 1
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        // A callback already running on the queue finishes before the box goes.
        queue.sync {}
        box?.release()
        box = nil
        Self.running -= 1
    }

    deinit { stop() }
}
