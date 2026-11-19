import AppKit
import CedricCore
import QuartzCore

/// `CEDRIC_LAYER_DUMP=/out/dir`: a diagnostic of what the window server is
/// given, not what `cacheDisplay` redraws. Turns the owl on through the
/// real menu action, types through real key events, then writes:
///
///   tree.txt        every view: frame, hidden/alpha, layer state, opacity,
///                   z-order among siblings, overlap with the text view
///   cache.png       the window drawn with cacheDisplay (what our checks saw)
///   layer.png       the frame view's CALayer tree via `render(in:)`
///   window.png      CGWindowListCreateImage of the window (fails when locked)
///
/// and prints "layerdump: …" lines comparing the three.
@MainActor
enum RenderDump {
    static func run(_ app: AppDelegate, out: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        guard let tab = app.currentTab ?? app.tabs.last, let window = tab.window else { print("layerdump: no tab"); exit(1) }
        window.makeKeyAndOrderFront(nil)
        TypingCheck.settle(0.2)
        if DevEnvironment.values["CEDRIC_LAYER_DUMP_OWL"] == "1", !Settings.shared.showOwl {
            NSApp.sendAction(#selector(AppDelegate.toggleOwl(_:)), to: nil, from: nil)
            TypingCheck.settle(0.2)
        }
        window.makeFirstResponder(tab.textView)
        TypingCheck.type(window, "Hello owl\nsecond line")
        TypingCheck.settle(0.5)
        window.displayIfNeeded()
        CATransaction.flush()
        TypingCheck.settle(0.2)

        var lines: [String] = []
        let root = window.contentView!.superview ?? window.contentView!
        let tvFrame = tab.textView.convert(tab.textView.visibleRect, to: root)
        lines.append("window occlusionVisible=\(window.occlusionState.contains(.visible)) appActive=\(NSApp.isActive) key=\(window.isKeyWindow) backing=\(window.backingScaleFactor)")
        lines.append("contentView.wantsLayer=\(window.contentView!.wantsLayer) layer=\(window.contentView!.layer != nil)")
        lines.append("textView visible rect in root=\(tvFrame)")
        walk(root, depth: 0, index: 0, siblings: 1, tvFrame: tvFrame, root: root, into: &lines)
        let tree = lines.joined(separator: "\n")
        try? tree.write(toFile: out + "/tree.txt", atomically: true, encoding: .utf8)

        // Same bounds, three ways.
        let cache = DevHooks.render(root, root.bounds)
        save(cache, out + "/cache.png")
        let layerRep = renderLayer(root)
        save(layerRep, out + "/layer.png")
        let winRep = windowImage(window)
        save(winRep, out + "/window.png")

        // Ink in the typed text's rect, in each image.
        let typed = (tab.text as NSString).range(of: "Hello owl")
        let rects = TypingCheck.glyphRects(tab.textView, typed).map { tab.textView.convert($0, to: root) }
        let bg = NSColor(hex: tab.palette.background)
        for (name, rep) in [("cache", cache), ("layer", layerRep), ("window", winRep)] {
            guard let rep else { print("layerdump: \(name) unavailable"); continue }
            print("layerdump: \(name) typed-text ink=\(ink(rep, rects, root: root, bg: bg))")
            if let owl = tab.owl?.owl, owl.window != nil {
                let r = owl.convert(owl.bounds, to: root)
                print("layerdump: \(name) owl ink=\(ink(rep, [r], root: root, bg: bg))")
            }
        }
        print("layerdump: wrote \(out)")
        fflush(stdout)
        exit(0)
    }

    // MARK: Render check

    /// `CEDRIC_RENDER_CHECK=/out/dir` (Scripts/render-check.sh): for every
    /// theme, a new tab at 900×670 (Derek's window), the owl turned on the
    /// way the menu does it, text typed with key events, then the WHOLE
    /// window is rendered from its CALayer tree and with cacheDisplay on
    /// the frame view (never a view on its own, which is how the checks
    /// missed the status bar painting over the editor). Checks: the typed
    /// text, the line numbers and the owl have ink; the editor area is the
    /// theme background, not another view's colour. Runs without
    /// CEDRIC_OWL_ASSUME_VISIBLE, so the owl's default (occluded, inactive
    /// when the screen is locked) path is what's checked.
    static func check(_ app: AppDelegate, out: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        var failures = 0
        func report(_ ok: Bool, _ name: String, _ detail: String) {
            if !ok { failures += 1 }
            print("rendercheck: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
            fflush(stdout)
        }
        Settings.shared.owlOverride = false
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        for c in TypingCheck.themes {
            TypingCheck.apply(c)
            app.newTab(nil)
            guard let tab = app.tabs.last, let window = tab.window else { report(false, c.name, "no tab"); continue }
            window.setContentSize(NSSize(width: 900, height: 670))
            window.makeKeyAndOrderFront(nil)
            TypingCheck.settle(0.1)
            // View › Show Cedric the Owl: the same notification the menu's setter posts.
            Settings.shared.owlOverride = true
            NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
            TypingCheck.settle(0.1)
            let owlNow = tab.owl.map { o in o.owl.alphaValue > 0.99 && !o.owl.isHidden && o.owl.window != nil } ?? false
            report(owlNow, "\(c.name)/owl-shown-on-toggle", "alpha=\(tab.owl?.owl.alphaValue ?? -1) occlusionVisible=\(window.occlusionState.contains(.visible)) active=\(NSApp.isActive)")
            window.makeFirstResponder(tab.textView)
            TypingCheck.type(window, "Hello owl\nsecond line")
            TypingCheck.settle(0.4)
            window.displayIfNeeded()
            CATransaction.flush()
            let root = window.contentView!.superview ?? window.contentView!
            let p = tab.palette
            let typed = (tab.text as NSString).range(of: "Hello owl")
            let textRects = TypingCheck.glyphRects(tab.textView, typed).map { tab.textView.convert($0, to: root) }
            let gutterRect = tab.gutter.convert(NSRect(x: 0, y: 0, width: tab.gutter.bounds.width, height: 40), to: root)
            let bg = NSColor(hex: p.background)
            // An empty patch of the editor, well below the text and left of the owl.
            let tvVis = tab.textView.convert(tab.textView.visibleRect, to: root)
            let empty = NSRect(x: tvVis.minX + 200, y: tvVis.minY + 150, width: 100, height: 100)
            for (how, rep) in [("layer", renderLayer(root)), ("cache", DevHooks.render(root, root.bounds))] {
                guard let rep else { report(false, "\(c.name)/\(how)", "no image"); continue }
                save(rep, "\(out)/\(c.name)-\(how).png")
                let t = inkCount(rep, textRects, root: root, bg: bg)
                report(t >= 30, "\(c.name)/\(how)/typed-text", "ink=\(t)")
                let g = inkCount(rep, [gutterRect], root: root, bg: NSColor(hex: p.gutterBackground))
                report(g >= 10, "\(c.name)/\(how)/line-numbers", "ink=\(g)")
                if let owl = tab.owl?.owl {
                    let o = inkCount(rep, [owl.convert(owl.bounds, to: root)], root: root, bg: bg)
                    report(o >= 200, "\(c.name)/\(how)/owl", "ink=\(o)")
                } else {
                    report(false, "\(c.name)/\(how)/owl", "no owl")
                }
                let stray = inkCount(rep, [empty], root: root, bg: bg, threshold: 1.25)
                report(stray == 0, "\(c.name)/\(how)/editor-background", "pixels unlike the theme background=\(stray)")
            }
            Settings.shared.owlOverride = false
            NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
            tab.doc.markSaved()
            window.close()
            TypingCheck.settle(0.05)
        }
        // The owl dragged with mouse events; language detection with key events.
        PolishCheck.owl(app, out: out, report: report)
        PolishCheck.language(app, out: out, report: report)
        PolishCheck.themeShowcase(app, out: out, report: report)
        PolishCheck.spelling(app, out: out, report: report)
        // A PDF tab (PDFCheck.swift): white page, themed chrome.
        PDFRenderCheck.run(app, out: out, report: report)
        // The folder sidebar beside the editor (FolderCheck.swift).
        FolderRenderCheck.run(app, out: out, report: report)
        // Untitled numbering: the lowest free number among open untitled tabs.
        for t in app.tabs { t.doc.markSaved(); t.window?.close() }
        TypingCheck.settle(0.05)
        app.newTab(nil)
        let first = app.tabs.last
        app.newTab(nil)
        let second = app.tabs.last
        report(first?.doc.displayName == "Untitled" && second?.doc.displayName == "Untitled 2", "untitled/first-two",
               "\(first?.doc.displayName ?? "-"), \(second?.doc.displayName ?? "-")")
        first?.window?.close()
        TypingCheck.settle(0.05)
        app.newTab(nil)
        report(app.tabs.last?.doc.displayName == "Untitled", "untitled/reuses-closed-number", app.tabs.last?.doc.displayName ?? "-")
        app.newTab(nil)
        report(app.tabs.last?.doc.displayName == "Untitled 3", "untitled/next-free", app.tabs.last?.doc.displayName ?? "-")
        print("rendercheck: done failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    static func inkCount(_ rep: NSBitmapImageRep, _ rects: [NSRect], root: NSView, bg: NSColor, threshold: Double = 2) -> Int {
        let bgL = TypingCheck.luminance(bg)
        let sx = Double(rep.pixelsWide) / root.bounds.width, sy = Double(rep.pixelsHigh) / root.bounds.height
        var n = 0
        for r in rects {
            let x0 = Int(r.minX * sx), x1 = Int(r.maxX * sx)
            let y0 = Int((root.bounds.height - r.maxY) * sy), y1 = Int((root.bounds.height - r.minY) * sy)
            for y in max(0, y0)..<min(rep.pixelsHigh, max(y0, y1)) {
                for x in max(0, x0)..<min(rep.pixelsWide, max(x0, x1)) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if TypingCheck.contrast(TypingCheck.luminance(c), bgL) >= threshold { n += 1 }
                }
            }
        }
        return n
    }

    static func describe(_ c: CGColor?) -> String {
        guard let c, let comps = c.components else { return "nil" }
        return "(" + comps.map { String(format: "%.2f", $0) }.joined(separator: ",") + ")"
    }

    static func walk(_ v: NSView, depth: Int, index: Int, siblings: Int, tvFrame: NSRect, root: NSView, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        var s = "\(pad)[\(index)/\(siblings)] \(type(of: v)) frame=\(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue) opaque=\(v.isOpaque)"
        s += " wantsLayer=\(v.wantsLayer) wantsUpdateLayer=\(v.wantsUpdateLayer)"
        if let l = v.layer {
            s += " layer=\(type(of: l)) l.opaque=\(l.isOpaque) l.bg=\(describe(l.backgroundColor)) l.contents=\(l.contents.map { "\(type(of: $0))" } ?? "nil")"
            s += " l.z=\(l.zPosition) l.hidden=\(l.isHidden) l.opacity=\(l.opacity) l.masks=\(l.masksToBounds) l.frame=\(l.frame)"
            s += " l.sublayers=\(l.sublayers?.count ?? 0) policy=\(v.layerContentsRedrawPolicy.rawValue)"
        } else {
            s += " layer=nil"
        }
        if let t = v as? NSTextView { s += " drawsBg=\(t.drawsBackground) bg=\(describe(t.backgroundColor.cgColor)) tlm=\(t.textLayoutManager != nil)" }
        if let t = v as? NSScrollView { s += " drawsBg=\(t.drawsBackground) bg=\(describe(t.backgroundColor.cgColor))" }
        if let t = v as? NSClipView { s += " drawsBg=\(t.drawsBackground) bg=\(describe(t.backgroundColor.cgColor))" }
        let inRoot = v.convert(v.bounds, to: root)
        if inRoot.intersects(tvFrame) { s += " OVERLAPS-TEXT" }
        if v.window == nil { s += " NO-WINDOW" }
        lines.append(s)
        guard depth < 14 else { return }
        for (i, sub) in v.subviews.enumerated() {
            walk(sub, depth: depth + 1, index: i, siblings: v.subviews.count, tvFrame: tvFrame, root: root, into: &lines)
        }
        // Sublayers that aren't any subview's layer (added by hand).
        if let l = v.layer {
            let viewLayers = Set(v.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
            for sl in l.sublayers ?? [] where !viewLayers.contains(ObjectIdentifier(sl)) {
                lines.append("\(pad)  + sublayer \(type(of: sl)) frame=\(sl.frame) z=\(sl.zPosition) hidden=\(sl.isHidden) opacity=\(sl.opacity) bg=\(describe(sl.backgroundColor)) contents=\(sl.contents.map { "\(type(of: $0))" } ?? "nil")")
            }
        }
    }

    /// The view's layer tree, as composited from layer contents (not a redraw).
    static func renderLayer(_ v: NSView) -> NSBitmapImageRep? {
        guard let layer = v.layer else { print("layerdump: root has no layer"); return nil }
        let scale: CGFloat = 2
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        rep.size = v.bounds.size
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped == false && v.isFlipped {
            ctx.translateBy(x: 0, y: v.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        return rep
    }

    /// CGWindowListCreateImage, looked up at run time (removed from the
    /// macOS 15 SDK headers, still in the library).
    static func windowImage(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { print("layerdump: no CGWindowListCreateImage"); return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        guard let img = fn(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { print("layerdump: CGWindowListCreateImage returned nil"); return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        // Content area only: the frame view is the image's size.
        rep.size = window.frame.size
        return rep
    }

    static func save(_ rep: NSBitmapImageRep?, _ path: String) {
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// Pixels in `rects` (root coordinates) that differ clearly from `bg`.
    static func ink(_ rep: NSBitmapImageRep, _ rects: [NSRect], root: NSView, bg: NSColor) -> String {
        let bgL = TypingCheck.luminance(bg)
        let sx = Double(rep.pixelsWide) / root.bounds.width, sy = Double(rep.pixelsHigh) / root.bounds.height
        var n = 0, total = 0, black = 0
        for r in rects {
            // Root (frame view) isn't flipped: bitmap rows run top-down.
            let x0 = Int(r.minX * sx), x1 = Int(r.maxX * sx)
            let y0 = Int((root.bounds.height - r.maxY) * sy), y1 = Int((root.bounds.height - r.minY) * sy)
            for y in max(0, y0)..<min(rep.pixelsHigh, max(y0, y1)) {
                for x in max(0, x0)..<min(rep.pixelsWide, max(x0, x1)) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    total += 1
                    if c.alphaComponent < 0.05 { black += 1; continue }
                    if TypingCheck.contrast(TypingCheck.luminance(c), bgL) >= 2 { n += 1 }
                }
            }
        }
        return "\(n)/\(total) transparent=\(black)"
    }
}
