import AppKit
import CedricCore

/// `CEDRIC_LAUNCH_TRACE=1`: launch-phase timings for Scripts/launch-speed-check.sh.
/// Prints `launch <phase>=<ms>` lines, each the time since the process
/// started (from the kernel, so dyld and static initialisers are included):
///
///   main             top of main.swift (everything before it is dyld + static init)
///   will_finish      applicationWillFinishLaunching
///   did_finish       applicationDidFinishLaunching entered
///   restored         session restored (tabs built, windows ordered in)
///   did_finish_end   applicationDidFinishLaunching returned its work
///   first_frame      the run loop went idle with a window on screen: first frame committed
///   key_dequeued     a keyDown posted at first_frame came off the event queue
///   key_drawn        ...was inserted by the text view and the window redrawn
///   idle             the main queue drained all deferred launch work
///
/// The keystroke goes through the real event queue (NSApp.postEvent), so
/// it waits for whatever the main thread is still doing, as a user's would.
/// It is then delivered to the frontmost tab's window with `sendEvent`
/// (the app may not be active when launched from a script). Then the app
/// exits without saving the session. Off unless the variable is set.
@MainActor
enum LaunchTrace {
    static let enabled = DevEnvironment.values["CEDRIC_LAUNCH_TRACE"] == "1"
    private static var start = 0.0
    private static var probeWindow: NSWindow?
    private static var probeChars = "\u{0078}"

    static func mark(_ name: String) {
        guard enabled else { return }
        if start == 0 { start = DevHooks.processStart(); PerfTrace.enabled = true; PerfTrace.start() }
        print(String(format: "launch %@=%.1f", name, (DevHooks.now() - start) * 1000))
        fflush(stdout)
    }

    /// Called at the end of applicationDidFinishLaunching.
    static func afterLaunch(_ app: AppDelegate) {
        guard enabled else { return }
        mark("did_finish_end")
        // After AppKit's own display/commit observers (their order is below Int.max).
        var fired = false
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { obs, _ in
            MainActor.assumeIsolated {
                guard !fired, NSApp.windows.contains(where: { $0.isVisible }) else { return }
                fired = true
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes)
                mark("first_frame")
                postKey(app)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func postKey(_ app: AppDelegate) {
        guard let window = (app.currentTab ?? app.tabs.last)?.window else { mark("no_window"); exit(1) }
        probeWindow = window
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let w = probeWindow, e.characters == probeChars else { return false }
                probeWindow = nil
                if let monitor { NSEvent.removeMonitor(monitor) }
                mark("key_dequeued")
                let tab = app.tabs.first { $0.window === w }
                let before = tab?.textView.textStorage?.length ?? 0
                w.sendEvent(e)
                let after = tab?.textView.textStorage?.length ?? 0
                w.displayIfNeeded()
                mark(after == before + 1 ? "key_drawn" : "key_not_inserted")
                // The rest of the launch work that was deferred behind the keystroke.
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        mark("idle")
                        fflush(stdout)
                        exit(0)
                    }
                }
                return true
            }
            return consumed ? nil : event
        }
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: probeChars,
                                       charactersIgnoringModifiers: probeChars, isARepeat: false, keyCode: 7) else { return }
        NSApp.postEvent(e, atStart: false)
    }
}
