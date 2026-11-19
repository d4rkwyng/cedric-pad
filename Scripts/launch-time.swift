// Measures launch-to-first-window for any app, the same way for each, so
// Owlink can be compared with TextEdit and VS Code:
//
//   swift Scripts/launch-time.swift [--runs 5] APP.app [APP.app ...]
//
// For each run: launch a new instance with NSWorkspace, poll the window
// server (CGWindowList, which works with the screen locked) every 5 ms
// until the app owns a normal-level window at least 200 points tall, record
// the time, quit the app, wait for it to exit, pause. Prints each run and
// the median. "Cold" here means the app isn't running; the file cache is
// warm after the first run (purging it needs root).
import AppKit
import CoreGraphics

var runs = 5
var apps: [String] = []
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    if a == "--runs", let n = args.popFirst().flatMap(Int.init) { runs = n } else { apps.append(a) }
}

func now() -> Double { Date().timeIntervalSince1970 }

func hasWindow(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let b = w[kCGWindowBounds as String] as? [String: Double], (b["Height"] ?? 0) >= 200 { return true }
    }
    return false
}

func launchOnce(_ path: String) -> Double? {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    cfg.activates = true
    // AppKit apps: don't offer to reopen windows after a killed run.
    // Electron apps (VS Code) treat any argument as a path, so none there.
    if !FileManager.default.fileExists(atPath: path + "/Contents/Frameworks/Electron Framework.framework") {
        cfg.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    }
    var app: NSRunningApplication?
    let t0 = now()
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { a, e in
        app = a
        if let e { print("launch error: \(e)") }
        done.signal()
    }
    while done.wait(timeout: .now() + 0.001) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
    guard let pid = app?.processIdentifier else { return nil }
    var t1: Double?
    let deadline = t0 + 30
    while now() < deadline {
        if hasWindow(pid) { t1 = now(); break }
        usleep(5000)
    }
    app?.terminate()
    for _ in 0..<100 where !(app?.isTerminated ?? true) { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    if !(app?.isTerminated ?? true) { app?.forceTerminate(); sleep(1) }
    sleep(2)
    return t1.map { ($0 - t0) * 1000 }
}

for path in apps {
    var samples: [Double] = []
    for i in 1...runs {
        if let ms = launchOnce(path) {
            samples.append(ms)
            print(String(format: "%@ run %d: %.0f ms", (path as NSString).lastPathComponent, i, ms))
        } else {
            print("\((path as NSString).lastPathComponent) run \(i): no window within 30 s")
        }
    }
    samples.sort()
    if !samples.isEmpty {
        print(String(format: "%@ median: %.0f ms (min %.0f, max %.0f, n=%d)", (path as NSString).lastPathComponent,
                     samples[samples.count / 2], samples.first!, samples.last!, samples.count))
    }
}
