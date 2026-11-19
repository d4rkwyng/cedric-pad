import AppKit
import CedricCore

/// Cedric in the Ask Cedric panel's header: the owl art at 64 pt, reacting
/// to the conversation (`OwlChatMood` holds the rules; the panel sends the
/// cues). He waves when the panel opens, glances at the question field while
/// you type, thinks while the model works, searches, talks while the answer
/// streams, nods when it's done, flaps on Apply, and looks sleepy after an
/// error. Idle, he blinks every few seconds.
///
/// Cost: at most one frame timer (only while a gesture or a working state
/// plays) and one one-shot blink timer (only while idle), both on main and
/// each tick just swaps an image in a 64 pt view. Nothing at all runs while
/// the panel is hidden, closed, occluded or the app is hidden, and under
/// Reduce Motion he only ever changes still poses.
@MainActor
final class OwlChatFace: NSView {
    /// The art's square frames, drawn this tall; the empty margin at their
    /// left is cut off (the owl and his bubbles sit right of it).
    static let size: CGFloat = 64
    static let cropLeft: CGFloat = 0.18
    static var width: CGFloat { (size * (1 - cropLeft)).rounded() }

    private(set) var mood: OwlChatMood = .idle
    /// Every mood he went through (checks).
    private(set) var moodLog: [OwlChatMood] = []
    /// The image drawn now (checks).
    private(set) var current: NSImage?
    /// Images shown so far (checks: a still pose under Reduce Motion is one).
    private(set) var framesShown = 0
    /// Whether the panel has an engine ready, asked when it opens.
    var engineReady: () -> Bool = { true }

    private var frameTimer: Timer?
    private var blinkTimer: Timer?
    private var sequence: [NSImage] = []
    private var looping: [NSImage] = []
    private var lastListen: Date?
    private var lastWave: Date?
    private var live = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Cedric the owl"))
        show(OwlArt.poses[.idle])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    /// A timer is scheduled (checks: none while hidden, none idle under Reduce Motion).
    var isAnimating: Bool { frameTimer != nil }
    var blinkScheduled: Bool { blinkTimer != nil }

    // MARK: Cues

    func cue(_ c: OwlChatMood.Cue) {
        let next = OwlChatMood.next(c, from: mood)
        if c == .typed {
            // Throttled: one listen per `listenInterval`, never every keystroke.
            guard next == .listen, OwlChatMood.listenDue(lastListen: lastListen, now: Date()) else { return }
            lastListen = Date()
        }
        if case .opened(true) = c {
            // A wave when the panel opens, not on every return to the app.
            guard OwlChatMood.waveDue(lastWave: lastWave, now: Date()) else {
                if !mood.isWorking, mood != .idle { enter(.idle) }
                return
            }
            lastWave = Date()
        }
        // The same lasting state again (another text piece): nothing to redo.
        if next == mood, !next.isGesture { return }
        enter(next)
    }

    /// A key in the question field.
    func typed() { cue(.typed) }

    private func enter(_ m: OwlChatMood) {
        mood = m
        moodLog.append(m)
        if moodLog.count > 64 { moodLog.removeFirst(moodLog.count - 64) }
        render()
    }

    /// Draws the mood: a still, a gesture, or a loop; only while on screen.
    private func render() {
        stopFrames()
        stopBlink()
        let display = OwlChatMood.display(mood, reduceMotion: OwlView.reduceMotion)
        guard live else {
            // Off screen: no timers. A gesture is over before anyone sees it.
            if mood.isGesture { mood = .idle }
            show(still(for: OwlChatMood.display(mood, reduceMotion: true)))
            return
        }
        switch display {
        case .still(let s):
            show(image(s))
            scheduleBlink()
        case .gesture(let strip, let idx, let every):
            let f = frames(strip)
            let pick = idx.compactMap { f.indices.contains($0) ? f[$0] : nil }
            guard !pick.isEmpty else { cue(.settled); return }
            play(pick, every: every, loop: false)
        case .loop(let strip, let every):
            let f = frames(strip)
            guard !f.isEmpty else { show(OwlArt.poses[.thinking]); return }
            play(f, every: every, loop: true)
        }
    }

    private func still(for d: OwlChatMood.Display) -> NSImage? {
        if case .still(let s) = d { return image(s) }
        return OwlArt.poses[.idle]
    }

    private func image(_ s: OwlChatMood.Still) -> NSImage? {
        switch s {
        case .idle: return OwlArt.poses[.idle]
        case .talking: return OwlArt.poses[.talking]
        case .thinking: return OwlArt.poses[.thinking]
        case .sleepy: return OwlArt.poses[.sleepy]
        }
    }

    private func frames(_ s: OwlChatMood.Strip) -> [NSImage] {
        switch s {
        case .wave: return OwlArt.strip(.wave)
        case .look: return OwlArt.strip(.look)
        case .think: return OwlArt.strip(.think)
        case .search: return OwlArt.strip(.search)
        case .write: return OwlArt.strip(.write)
        case .nod: return OwlArt.strip(.nod)
        case .flap: return OwlArt.flap
        case .blink: return OwlArt.blink
        }
    }

    private func show(_ img: NSImage?) {
        guard let img, img !== current else { return }
        current = img
        framesShown += 1
        needsDisplay = true
    }

    // MARK: Frames

    private func play(_ f: [NSImage], every: TimeInterval, loop: Bool) {
        looping = loop ? f : []
        sequence = f
        step()
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        t.tolerance = every * 0.1
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func step() {
        if sequence.isEmpty, !looping.isEmpty { sequence = looping }
        guard !sequence.isEmpty else {
            stopFrames()
            if mood.isGesture { cue(.settled) } else { render() }
            return
        }
        show(sequence.removeFirst())
    }

    private func stopFrames() {
        frameTimer?.invalidate()
        frameTimer = nil
        sequence = []
        looping = []
    }

    // MARK: Blinking

    private func scheduleBlink() {
        guard live, let delay = OwlChatMood.blinkDelay(mood, reduceMotion: OwlView.reduceMotion, random: .random(in: 0...1)) else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.blinkNow() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    /// The idle blink, now (checks).
    func blinkNow() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard live, mood == .idle, case .gesture(let strip, let idx, let every) = OwlChatMood.blink,
              !OwlView.reduceMotion else { return }
        let f = frames(strip)
        let pick = idx.compactMap { f.indices.contains($0) ? f[$0] : nil }
        guard !pick.isEmpty else { return }
        // Ends back on the idle still, which schedules the next blink.
        play(pick, every: every, loop: false)
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    /// Reduce Motion changed: the mood redrawn the new way.
    func reduceMotionChanged() { render() }

    // MARK: On screen or not

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let w = window else { setLive(false); return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLive() }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLive(false) }
        })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLive() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                OwlView.reduceMotion = OwlView.currentReduceMotion()
                self?.reduceMotionChanged()
            }
        })
        updateLive()
    }

    /// The panel can be seen (the checks run with the screen locked:
    /// `OwlController.assumeVisible`).
    var canAnimate: Bool {
        guard let w = window, w.isVisible, !w.isMiniaturized, !NSApp.isHidden else { return false }
        if OwlController.assumeVisible { return true }
        return w.occlusionState.contains(.visible)
    }

    /// Re-reads whether he's on screen (the panel calls it after showing and hiding).
    func updateLive() { setLive(canAnimate) }

    private func setLive(_ on: Bool) {
        guard on != live else { return }
        live = on
        if on {
            // Back on screen: carry on with the work, else say hello.
            if mood.isWorking { render() } else { cue(.opened(engineReady: engineReady())) }
        } else {
            stopFrames()
            stopBlink()
            render()
        }
    }

    var isLive: Bool { live }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let current else { return }
        NSGraphicsContext.saveGraphicsState()
        // A soft light rim in dark mode, so the navy owl reads on a dark panel.
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            let rim = NSShadow()
            rim.shadowBlurRadius = 2
            rim.shadowOffset = .zero
            rim.shadowColor = NSColor(white: 1, alpha: 0.7)
            rim.set()
        }
        let side = current.size.height
        let from = NSRect(x: side * Self.cropLeft, y: 0, width: side * (1 - Self.cropLeft), height: side)
        current.draw(in: bounds.insetBy(dx: 1, dy: 1), from: from, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension OwlChatPanel {
    /// A key in the question field: Cedric listens (throttled in `OwlChatFace`).
    @objc func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === input else { return }
        face.typed()
    }
}
