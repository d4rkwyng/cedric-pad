import AppKit
import CedricCore

/// Phase timings for the perf hooks: off unless a perf run turns it on.
@MainActor
enum PerfTrace {
    static var enabled = false
    private static var last = 0.0

    static func start() { last = DevHooks.now() }

    /// Prints the time since the previous mark.
    static func mark(_ name: String) {
        guard enabled else { return }
        let t = DevHooks.now()
        print(String(format: "trace %@=%.1f ms", name, (t - last) * 1000))
        fflush(stdout)
        last = t
    }
}

/// `CEDRIC_PERF_BIG=/file`: the long-line / large-file measurement
/// (Scripts/perf-check.sh). Opens the file the way File › Open does, then
/// times the first window, first paint, keystrokes at the start, middle
/// and end, a scripted scroll and the idle CPU with the owl on, and prints
/// `metric name=value` lines.
///
///   CEDRIC_PERF_TYPE=60        keystrokes per position (default 60)
///   CEDRIC_PERF_SCROLL=120     scroll steps (default 120)
///   CEDRIC_PERF_IDLE=10        seconds of idle CPU measurement (default 10; 0 skips)
///   CEDRIC_PERF_WRAP=0|1       force wrapping for this run (experiments; ignores large mode)
///   CEDRIC_PERF_TRACE=1        print phase timings of the open
@MainActor
enum LargeDocPerf {
    static let env = DevEnvironment.values

    static func run(_ app: AppDelegate, _ path: String) {
        PerfTrace.enabled = env["CEDRIC_PERF_TRACE"] == "1"
        let url = URL(fileURLWithPath: path)
        let t0 = DevHooks.now()
        PerfTrace.start()
        guard let tab = app.open(url) else { print("perf: can't open \(path)"); exit(1) }
        let t1 = DevHooks.now()
        DevHooks.metric("open_window_ms", (t1 - t0) * 1000)
        tab.window?.displayIfNeeded()
        let t2 = DevHooks.now()
        DevHooks.metric("first_paint_ms", (t2 - t1) * 1000)
        DevHooks.metric("open_total_ms", (t2 - t0) * 1000)
        PerfTrace.enabled = false
        if let w = env["CEDRIC_PERF_WRAP"] { tab.forceWrapForPerf(w == "1") }
        // View › Writing Mode on (typewriter and Focus) for the whole run.
        let writing = env["CEDRIC_PERF_WRITING"] == "1"
        if writing { tab.setWriting(WritingModeState(typewriter: true, focus: true)) }
        let maxLine = tab.lineIndex.longestLine
        print("perf: lines=\(tab.lineIndex.lineCount) utf16=\(tab.lineIndex.length) longest_line=\(maxLine) large=\(tab.isLargeDocument) wrap=\(tab.wrapsLines)")

        // Let deferred work (colouring, the owl, the session) settle first.
        spin(0.5)

        let n = env["CEDRIC_PERF_TYPE"].flatMap(Int.init) ?? 60
        let keys = Array("abc xyz 42+")
        var all: [Double] = []
        for (name, at) in [("start", 0), ("middle", tab.lineIndex.length / 2), ("end", tab.lineIndex.length)] {
            tab.textView.setSelectedRange(NSRange(location: min(at, tab.textView.textStorage!.length), length: 0))
            tab.reveal(tab.textView.selectedRange())
            tab.window?.displayIfNeeded()
            spin(0.1)
            var samples: [Double] = []
            for k in 0..<n {
                let s = DevHooks.now()
                tab.textView.insertText(String(keys[k % keys.count]), replacementRange: tab.textView.selectedRange())
                tab.colorizer.colorViewport()
                if writing { tab.applyFocusNow() }   // its deferred pass, timed with the key
                tab.window?.displayIfNeeded()
                samples.append((DevHooks.now() - s) * 1000)
            }
            report("type_\(name)", samples)
            if writing { DevHooks.metric("typewriter_scrolls_\(name)", Double(tab.editing.typewriterScrolls)) }
            all += samples
        }
        report("type", all)

        // Scripted scroll: page-sized steps down (and, without wrapping,
        // across) the text, each followed by the deferred work and a draw.
        let steps = env["CEDRIC_PERF_SCROLL"].flatMap(Int.init) ?? 120
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        tab.scrollView.contentView.scroll(to: .zero)
        tab.window?.displayIfNeeded()
        var frames: [Double] = []
        let clip = tab.scrollView.contentView
        // Steps where the view ended up above where it was: a scroll
        // that snaps back (TextKit re-anchoring the viewport).
        var backsteps = 0, lastY = clip.bounds.minY
        for i in 0..<steps {
            let s = DevHooks.now()
            let page = clip.bounds.size
            var p = clip.bounds.origin
            let docSize = tab.textView.frame.size
            if !tab.wrapsLines, docSize.width > page.width * 2 {
                p.x = min(docSize.width - page.width, p.x + page.width * 0.8)
                if i % 10 == 9 { p.y = min(max(0, docSize.height - page.height), p.y + page.height * 0.8) }
            } else {
                p.y = min(max(0, docSize.height - page.height), p.y + page.height * 0.8)
            }
            clip.scroll(to: p)
            tab.scrollView.reflectScrolledClipView(clip)
            spin(0)
            tab.window?.displayIfNeeded()
            frames.append((DevHooks.now() - s) * 1000)
            if clip.bounds.minY < lastY - 1 { backsteps += 1 }
            lastY = clip.bounds.minY
            if env["CEDRIC_PERF_SCROLL_LOG"] == "1" { print(String(format: "scroll step %d: wanted y=%.0f now y=%.0f", i, p.y, clip.bounds.minY)) }
        }
        report("scroll", frames)
        DevHooks.metric("scroll_backsteps", Double(backsteps))
        print(String(format: "perf: scrolled to x=%.0f y=%.0f of %.0fx%.0f", clip.bounds.minX, clip.bounds.minY, tab.textView.frame.width, tab.textView.frame.height))

        // Idle CPU with the owl on (and assumed visible).
        let idle = env["CEDRIC_PERF_IDLE"].flatMap(Double.init) ?? 10
        if idle > 0 {
            Settings.shared.owlOverride = true
            OwlController.assumeVisible = true
            tab.setOwlVisible(true)
            OwlHub.shared.activity(in: tab)
            spin(1)
            let c0 = cpuSeconds(), w0 = DevHooks.now()
            spin(idle)
            let cpu = (cpuSeconds() - c0) / (DevHooks.now() - w0) * 100
            DevHooks.metric("idle_cpu_pct", cpu)
            print("perf: owl_thinking=\(tab.owl?.owl.pose == .thinking) owl_queries=\(OwlHub.shared.coordinator.queryCount)")
        }
        exit(0)
    }

    static func report(_ name: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        let s = samples.sorted()
        DevHooks.metric("\(name)_median_ms", s[s.count / 2])
        DevHooks.metric("\(name)_p95_ms", s[min(s.count - 1, Int(Double(s.count) * 0.95))])
        DevHooks.metric("\(name)_max_ms", s.last!)
    }

    /// Runs the run loop (timers, main-queue work, notifications).
    static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01)))
        } while Date() < end
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
}

