import AppKit
import CedricCore
import WebKit

/// Launch-time switches for screenshots, perf measurement and the launch
/// check. All off unless the variable is set; none is saved.
///
///   CEDRIC_SESSION_DIR=/path      session store location (keeps tests off the real session)
///   CEDRIC_NO_RESTORE=1           don't restore the saved session
///   CEDRIC_NO_SESSION_SAVE=1      don't write the session
///   CEDRIC_OPEN=a.md:b.swift      open these files at launch
///   CEDRIC_THEME=dark             theme for this run (system/light/dark/tankard/dracula)
///   CEDRIC_PREVIEW=1              show the preview in the frontmost tab
///   CEDRIC_PREVIEW_JS=1           and allow JavaScript in it
///   CEDRIC_FIND=text              open the find bar with this text (CEDRIC_REPLACE=1: replace too,
///                                 CEDRIC_FIND_REGEX=1: as a regular expression)
///   CEDRIC_GOTO=12                put the caret on this line
///   CEDRIC_INVISIBLES=1           show invisibles for this run
///   CEDRIC_SNAPSHOT=/out.png      write the front window as a PNG (drawn with
///                                 cacheDisplay, so it works with the screen locked)
///   CEDRIC_SNAPSHOT_DELAY=2       seconds after launch (default 2)
///   CEDRIC_SNAPSHOT_SIZE=1100x700 window content size first
///   CEDRIC_SNAPSHOT_QUIT=1        quit after writing
///   CEDRIC_TEST_TYPE=text         type this at the end of the frontmost tab (session tests)
///   CEDRIC_TEST_TYPE_UNTITLED=t   open a new untitled tab and type this
///   CEDRIC_SESSION_DUMP=1         print the restored tabs and quit
///   CEDRIC_TYPE_CHECK=1           run the typing check (TypingCheck.swift), print results, quit
///   CEDRIC_LAUNCH_METRICS=1       print "metric launch_ms=…" (process start → first window drawn)
///   CEDRIC_QUIT_AFTER_LAUNCH=1    quit right after that
///   CEDRIC_PERF_OPEN=/big.json    time open + colour + jump to end + typing, print metrics, quit
///   CEDRIC_PERF_TYPE=200          keystrokes for the typing measurement (default 200)
///   CEDRIC_PERF_LANGUAGE=shell    force a language for the perf file
///   CEDRIC_OWL=1                  show the owl for this run (CEDRIC_OWL=0: hide it)
///   CEDRIC_OWL_PAUSE=3            seconds of no typing before the owl asks for hints
///   CEDRIC_OWL_INTERVAL=30        at most one hint query per this many seconds
///   CEDRIC_OWL_SLEEP_AFTER=300    seconds without typing before the owl dozes off
///   CEDRIC_OWL_RESET=1            forget "Don't show again" choices
///   CEDRIC_OWL_LOG=1              print each hint shown
///   CEDRIC_OWL_ASSUME_VISIBLE=1   treat windows as visible and the app as active (screen locked)
///   CEDRIC_OWL_CHECK=/out/dir     run the owl's in-process check (OwlCheck.swift) and quit
///   CEDRIC_OWL_SOURCE=rulesAndAI  the owl's hint source for this run, not saved
///   CEDRIC_AI_CHECK=/out/dir      run the local-AI check (AICheck.swift) and quit; with
///                                 CEDRIC_AI_FAKE=1.5 (fake provider) or CEDRIC_AI_CHECK_MODEL=id (live)
///   CEDRIC_AI*                    run-only AI settings: see AIStore in Owl/OwlAISettings.swift
///   CEDRIC_DUMP_SHORTCUTS=1       print every menu shortcut, exit 1 on a clash
///   CEDRIC_LAYER_DUMP=/out/dir    dump the view/layer tree and render it three ways (RenderDump.swift);
///                                 CEDRIC_LAYER_DUMP_OWL=1 turns the owl on first via the menu action
///   CEDRIC_RENDER_CHECK=/out/dir  whole-window render check, every theme (Scripts/render-check.sh)
///   CEDRIC_CHECK=name             in-process checks of the editor tools (DevChecks.swift;
///                                 Scripts/tools-check.sh runs them all)
@MainActor
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    static func metric(_ name: String, _ value: Double) {
        print(String(format: "metric %@=%.1f", name, value))
        fflush(stdout)
    }

    /// Process start time, from the kernel.
    static func processStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }

    static func now() -> Double {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    static func afterLaunch(_ app: AppDelegate) {
        if let s = env["CEDRIC_SNAPSHOT_SIZE"]?.split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) {
            for t in app.tabs { t.window?.setContentSize(NSSize(width: w, height: h)) }
        }
        if let tab = app.currentTab ?? app.tabs.last {
            if env["CEDRIC_PREVIEW"] == "1" { tab.togglePreview() }
            if env["CEDRIC_PREVIEW_JS"] == "1" { tab.previewAllowsJavaScript = true }
            if let line = env["CEDRIC_GOTO"].flatMap(Int.init) { tab.goToLine(line) }
            if let f = env["CEDRIC_FIND"] {
                tab.showFindBar(replace: env["CEDRIC_REPLACE"] == "1")
                tab.findBar.findField.stringValue = f
                if env["CEDRIC_FIND_REGEX"] == "1" { tab.findBar.regexBox.state = .on }
                tab.findBar.onChange?()
            }
        }
        // Session tests: type into the frontmost tab and/or a new untitled
        // tab through the normal editing path, or print what was restored.
        if let t = env["CEDRIC_TEST_TYPE"], let tab = app.currentTab ?? app.tabs.last {
            tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
            tab.textView.insertText(t, replacementRange: tab.textView.selectedRange())
        }
        if let t = env["CEDRIC_TEST_TYPE_UNTITLED"] {
            app.newTab(nil)
            if let tab = app.tabs.last { tab.textView.insertText(t, replacementRange: NSRange(location: 0, length: 0)) }
        }
        if env["CEDRIC_SESSION_DUMP"] == "1" {
            DispatchQueue.main.async {
                for t in app.tabs {
                    let body = t.text.replacingOccurrences(of: "\n", with: "\\n")
                    print("tab: name=\(t.doc.displayName) file=\(t.doc.fileURL?.path ?? "-") dirty=\(t.doc.isDirty) language=\(t.doc.language.rawValue) text=\(body.prefix(60))")
                }
                exit(0)
            }
        }
        if env["CEDRIC_LAUNCH_METRICS"] == "1" {
            // The window has been ordered front; measure when it has drawn.
            DispatchQueue.main.async {
                NSApp.windows.filter(\.isVisible).forEach { $0.displayIfNeeded() }
                metric("launch_ms", (now() - processStart()) * 1000)
                if env["CEDRIC_QUIT_AFTER_LAUNCH"] == "1" { exit(0) }
            }
        }
        if env["CEDRIC_TYPE_CHECK"] == "1" {
            // From a timer, not a main-queue block: the check spins the run
            // loop, and main-queue work (deferred colouring) can't run
            // inside a main-queue block.
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in MainActor.assumeIsolated { TypingCheck.run(app) } }
        }
        if let path = env["CEDRIC_PERF_OPEN"] { DispatchQueue.main.async { perfOpen(app, path) } }
        if env["CEDRIC_OWL_ASSUME_VISIBLE"] == "1" {
            OwlController.assumeVisible = true
            for t in app.tabs { t.owl?.updateTimer() }
            OwlHub.shared.schedule()
        }
        if env["CEDRIC_OWL_LOG"] == "1" {
            OwlHub.shared.onPresent = { _, h in print("owl: shown \(h.id): \(h.title)"); fflush(stdout) }
        }
        if let out = env["CEDRIC_OWL_CHECK"], !out.isEmpty { OwlCheck.run(app, out: out) }
        if let out = env["CEDRIC_AI_CHECK"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { AICheck.run(app, out: out) } }
        }
        if let out = env["CEDRIC_SNAPSHOT"], !out.isEmpty { scheduleSnapshot(out) }
        if env["CEDRIC_DUMP_SHORTCUTS"] == "1" { exit(DevChecks.dumpShortcuts() ? 0 : 1) }
        if let check = env["CEDRIC_CHECK"] { DevChecks.start(check, app) }
        if let out = env["CEDRIC_LAYER_DUMP"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { RenderDump.run(app, out: out) } }
        }
        if let out = env["CEDRIC_RENDER_CHECK"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { RenderDump.check(app, out: out) } }
        }
    }

    // MARK: Perf

    static func perfOpen(_ app: AppDelegate, _ path: String) {
        let url = URL(fileURLWithPath: path)
        let t0 = now()
        guard let (d, _) = try? EditorDocument.read(url) else { print("perf: can't read \(path)"); exit(1) }
        let t1 = now()
        metric("read_decode_ms", (t1 - t0) * 1000)
        let doc = EditorDocument(fileURL: url, untitledName: url.lastPathComponent)
        doc.apply(d)
        doc.languageChoice = .forFile(named: url.lastPathComponent, content: d.text)
        if let l = env["CEDRIC_PERF_LANGUAGE"].flatMap(Language.init(rawValue:)) { doc.languageChoice.choose(l) }
        let tab = app.makeTab(doc, text: d.text)
        let t2 = now()
        metric("load_text_ms", (t2 - t1) * 1000)
        tab.window?.displayIfNeeded()
        let colored = tab.colorizer.colorViewport()
        tab.window?.displayIfNeeded()
        let t3 = now()
        metric("first_paint_ms", (t3 - t2) * 1000)
        metric("open_total_ms", (t3 - t0) * 1000)
        print("perf: language=\(doc.language.rawValue) lines=\(tab.lineIndex.lineCount) utf16=\(tab.lineIndex.length) first_colored_lines=\(colored)")

        // Jump to the end and colour there (stateful languages scan the whole file once).
        let t4 = now()
        tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.length, length: 0))
        tab.reveal(NSRange(location: tab.lineIndex.length, length: 0))
        tab.window?.displayIfNeeded()
        tab.colorizer.colorViewport()
        tab.window?.displayIfNeeded()
        metric("jump_to_end_ms", (now() - t4) * 1000)

        // Typing: keystrokes in the middle of the file, each followed by
        // the work a keystroke triggers before the next frame (index
        // update, recolour, layout and display).
        let mid = tab.lineIndex.starts[tab.lineIndex.lineCount / 2]
        tab.textView.setSelectedRange(NSRange(location: mid, length: 0))
        tab.reveal(NSRange(location: mid, length: 0))
        tab.window?.displayIfNeeded()
        tab.colorizer.colorViewport()
        let n = env["CEDRIC_PERF_TYPE"].flatMap(Int.init) ?? 200
        var samples: [Double] = []
        let keys = Array("let value = 42 // typing\n")
        for k in 0..<n {
            let s = now()
            tab.textView.insertText(String(keys[k % keys.count]), replacementRange: tab.textView.selectedRange())
            tab.colorizer.colorViewport()
            tab.window?.displayIfNeeded()
            samples.append((now() - s) * 1000)
        }
        samples.sort()
        metric("type_median_ms", samples[samples.count / 2])
        metric("type_p95_ms", samples[Int(Double(samples.count) * 0.95)])
        metric("type_max_ms", samples.last ?? 0)
        print("perf: textkit2=\(tab.textView.textLayoutManager != nil)")
        exit(0)
    }

    // MARK: Snapshot

    static func dump(_ v: NSView, _ depth: Int) {
        guard depth < 7 else { return }
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
        v.subviews.forEach { dump($0, depth + 1) }
    }

    static func scheduleSnapshot(_ out: String) {
        let delay = env["CEDRIC_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                print("snapshot: no window"); exit(1)
            }
            if env["CEDRIC_SNAPSHOT_LAYOUT"] == "1" {
                dump(window.contentView!, 0)
            }
            write(window: window, to: out) {
                print("snapshot: wrote \(out); textkit2=\(((window.windowController as? EditorWindowController)?.textView.textLayoutManager) != nil)")
                if env["CEDRIC_SNAPSHOT_QUIT"] == "1" { exit(0) }
            }
        }
    }

    /// Renders part of a view at 2x (also when the screen is locked and
    /// reports 1x).
    static func render(_ v: NSView, _ rect: NSRect, ignoringOpacity: Bool = false) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        if ignoringOpacity, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            v.displayIgnoringOpacity(rect, in: ctx)
        } else {
            v.cacheDisplay(in: rect, to: rep)
        }
        return rep
    }

    /// Draws the window (title bar and tabs included) into a PNG, whole:
    /// one cacheDisplay of the frame view, so a view painting over another
    /// shows up as it does on screen. (It used to render the text view,
    /// gutter and owl on their own and paste them on top, which hid the
    /// status bar painting over the whole editor in test build 2.) Web
    /// views draw out of process and are captured with takeSnapshot.
    static func write(window: NSWindow, to path: String, done: @escaping @MainActor () -> Void) {
        guard let content = window.contentView, let root = content.superview ?? window.contentView else { done(); return }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        guard let base = render(root, root.bounds) else { done(); return }
        var overlays: [(NSRect, NSImageRep, CGFloat)] = []
        var webs: [WKWebView] = []
        func collect(_ v: NSView) {
            guard !v.isHidden else { return }
            if let w = v as? WKWebView { webs.append(w); return }
            v.subviews.forEach(collect)
        }
        collect(content)
        var remaining = webs.count
        func finish() {
            let out = NSImage(size: root.bounds.size)
            out.lockFocus()
            base.draw(in: root.bounds)
            for (frame, rep, alpha) in overlays { rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil) }
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            done()
        }
        if webs.isEmpty { finish(); return }
        for w in webs {
            let frame = w.convert(w.bounds, to: root)
            w.takeSnapshot(with: nil) { img, _ in
                MainActor.assumeIsolated {
                    if let img, let rep = img.representations.first { overlays.append((frame, rep, 1)) }
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
        }
    }
}
