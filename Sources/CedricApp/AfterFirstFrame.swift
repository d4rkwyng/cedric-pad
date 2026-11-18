import AppKit

/// Launch work that can wait until the first frame is on screen: the
/// Open Recent items (a LaunchServices icon per file), the owl hub, the
/// restored tabs that aren't selected. A one-shot run-loop observer fires
/// when the main run loop is about to sleep with a window on screen
/// (after AppKit's display and Core Animation commit, which run in the
/// same phase with lower orders); each queued block then runs in its own
/// run-loop turn, so a keystroke waits for at most one of them.
///
/// Work queued after that point runs on the next turn. A main-queue block
/// queued during launch would run before the first frame (the main queue
/// drains before the run loop's display phase).
@MainActor
enum AfterFirstFrame {
    private static var queue: [@MainActor () -> Void] = []
    private static var observer: CFRunLoopObserver?
    private static var draining = false
    private(set) static var passed = false

    static func run(_ work: @escaping @MainActor () -> Void) {
        queue.append(work)
        if passed { drain(); return }
        guard observer == nil else { return }
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                if NSApp.windows.contains(where: { $0.isVisible }) { pass() }
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        // No window on screen (launched hidden): don't wait for one.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in MainActor.assumeIsolated { pass() } }
    }

    private static func pass() {
        guard !passed else { return }
        passed = true
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        drain()
    }

    /// One block per run-loop turn (default, modal and tracking modes).
    private static func drain() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
            MainActor.assumeIsolated {
                draining = false
                guard !queue.isEmpty else { return }
                queue.removeFirst()()
                drain()
            }
        }
    }
}
