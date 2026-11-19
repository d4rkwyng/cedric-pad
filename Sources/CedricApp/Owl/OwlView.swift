import AppKit
import CedricCore

/// The owl art from Resources/Owl (made by tools/icon/cedric_icon.py):
/// loaded once, from OwlInk.app/Contents/Resources/Owl, else
/// CEDRIC_OWL_DIR, else the source tree (swift run).
@MainActor
enum OwlArt {
    enum Pose: String, CaseIterable { case idle, talking, blink, polish, flap, sleepy, thinking }

    static let directory: URL? = {
        var candidates: [URL] = []
        if let d = ProcessInfo.processInfo.environment["CEDRIC_OWL_DIR"] { candidates.append(URL(fileURLWithPath: d)) }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Owl")) }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Resources/Owl").standardizedFileURL)
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("owl-idle.png").path) }
    }()

    /// An image with its 1x and 2x representations.
    private static func load(_ name: String) -> NSImage? {
        guard let dir = directory else { return nil }
        let img = NSImage()
        for (file, scale) in [("\(name).png", 1.0), ("\(name)@2x.png", 2.0)] {
            guard let rep = NSImageRep(contentsOf: dir.appendingPathComponent(file)) else { continue }
            rep.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
            img.addRepresentation(rep)
        }
        guard let first = img.representations.first else { return nil }
        img.size = first.size
        return img
    }

    static let poses: [Pose: NSImage] = {
        var out: [Pose: NSImage] = [:]
        for p in Pose.allCases { out[p] = load("owl-\(p.rawValue)") }
        return out
    }()

    /// Frames cut from a horizontal strip of square frames.
    private static func frames(_ name: String, count: Int) -> [NSImage] {
        guard let strip = load(name) else { return [] }
        let side = strip.size.height
        return (0..<count).map { i in
            NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
                strip.draw(in: r, from: NSRect(x: CGFloat(i) * side, y: 0, width: side, height: side), operation: .sourceOver, fraction: 1)
                return true
            }
        }
    }

    static let blink = frames("owl-blink-strip", count: 3)
    static let flap = frames("owl-flap-strip", count: 4)

    /// The v1 animation strips (tools/icon/cedric_icon.py), each loaded the
    /// first time it plays, never at launch.
    enum Strip: String, CaseIterable {
        /// 8 gaze directions: right, up-right, up, up-left, left, down-left, down, down-right.
        case look, wave, nod
        /// right, up, left, down.
        case point
        case think, search, write
        var count: Int {
            switch self {
            case .look: return 8
            case .wave, .point: return 4
            case .nod, .think, .search, .write: return 3
            }
        }
    }
    private static var loaded: [Strip: [NSImage]] = [:]
    static func strip(_ s: Strip) -> [NSImage] {
        if let f = loaded[s] { return f }
        let f = frames("owl-\(s.rawValue)-strip", count: s.count)
        loaded[s] = f
        return f
    }
    /// Strips loaded so far (the launch check: none before the first frame).
    static var loadedStrips: Int { loaded.count }

    static func gazeIndex(dx: CGFloat, dy: CGFloat) -> Int? { OwlMotion.gazeIndex(dx: Double(dx), dy: Double(dy)) }
    static func pointIndex(dx: CGFloat, dy: CGFloat) -> Int { OwlMotion.pointIndex(dx: Double(dx), dy: Double(dy)) }
}

/// The owl itself: draws one image. Poses are set by `OwlController`;
/// blinks and flaps are short frame sequences on a timer that exists only
/// while the sequence plays.
@MainActor
final class OwlView: NSView, NSViewToolTipOwner {
    var onClick: (() -> Void)?
    /// Extra tooltip lines, asked for when the tooltip shows (the AI's
    /// "Last checked … ago" status), so the age is always current.
    nonisolated(unsafe) static var statusProvider: (@MainActor () -> String?)?
    private(set) var pose: OwlArt.Pose = .idle
    private var frame0: NSImage?
    private var sequence: [NSImage] = []
    private var sequenceTimer: Timer?
    /// The frame being drawn (tests, snapshots).
    private(set) var current: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addToolTip(bounds, owner: self, userData: nil)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Cedric the owl"))
        current = OwlArt.poses[.idle]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// "Cedric", plus the AI status line when an AI engine is on.
    var toolTipText: String {
        let name = String(localized: "Cedric")
        guard let status = Self.statusProvider?() else { return name }
        return name + "\n" + status
    }

    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                          userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { toolTipText }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override var isOpaque: Bool { false }

    func setPose(_ p: OwlArt.Pose) {
        guard p != pose || sequenceTimer != nil || inState else { return }
        pose = p
        stopSequence()
        current = OwlArt.poses[p]
        needsDisplay = true
    }

    var isPlaying: Bool { sequenceTimer != nil }

    /// Open, half, closed, half, open.
    func blink() {
        let f = OwlArt.blink
        guard pose == .idle, f.count == 3 else { return }
        gesture([f[1], f[2], f[2], f[1]], every: 0.05)
    }

    /// The monocle polish: the pose for a moment, then back.
    func polish() {
        guard pose == .idle, let img = OwlArt.poses[.polish] else { return }
        gesture([img], every: 1.6)
    }

    /// Two wing beats (on save).
    func flap() {
        let f = OwlArt.flap
        guard f.count == 4, pose != .talking else { return }
        gesture([f[1], f[2], f[3], f[0], f[1], f[2], f[3]], every: 0.07)
    }

    /// A glance in gaze direction `i` (look strip), held ~1.2 s.
    func glance(_ i: Int) {
        let f = OwlArt.strip(.look)
        guard pose == .idle, f.indices.contains(i) else { return }
        hold(f[i], seconds: 1.2)
    }

    /// Hello, once per launch: the wing waves twice.
    func wave() {
        let f = OwlArt.strip(.wave)
        guard pose == .idle, f.count == 4 else { return }
        gesture([f[0], f[1], f[2], f[3], f[2], f[3]], every: 0.16)
    }

    /// An acknowledging nod (an edit applied).
    func nod() {
        let f = OwlArt.strip(.nod)
        guard f.count == 3 else { return }
        gesture([f[0], f[1], f[1], f[2]], every: 0.11)
    }

    /// Points in direction `i` (right, up, left, down) for a moment.
    func point(_ i: Int) {
        let f = OwlArt.strip(.point)
        guard f.indices.contains(i) else { return }
        hold(f[i], seconds: 0.9)
    }

    /// System Settings › Accessibility › Display › Reduce Motion
    /// (CEDRIC_REDUCE_MOTION=0/1 for checks): no gestures, no idle
    /// animation, states shown as single still frames. Kept up to date by
    /// `OwlController` from NSWorkspace's display-options notification.
    static var reduceMotion: Bool = currentReduceMotion()
    static func currentReduceMotion() -> Bool {
        if let v = ProcessInfo.processInfo.environment["CEDRIC_REDUCE_MOTION"] { return v == "1" }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Frames played once, then back to the pose. Skipped under Reduce Motion.
    func gesture(_ frames: [NSImage], every interval: TimeInterval) {
        guard OwlMotion.render(.blink, reduceMotion: Self.reduceMotion) == .play, !frames.isEmpty else { return }
        play(frames, every: interval)
    }

    /// A state that lasts (thinking, searching, writing): its frames on a
    /// loop while it lasts, or its first frame, still, under Reduce Motion.
    func loop(_ frames: [NSImage], every interval: TimeInterval) {
        guard !frames.isEmpty else { return }
        stopSequence()
        if OwlMotion.render(.think, reduceMotion: Self.reduceMotion) == .still || frames.count == 1 {
            still = frames[0]
            current = frames[0]
            needsDisplay = true
            return
        }
        looping = frames
        play(frames, every: interval)
    }

    /// The still frame shown for a lasting state under Reduce Motion.
    private var still: NSImage?
    private var looping: [NSImage] = []
    /// A lasting state is shown (looping or still).
    var inState: Bool { !looping.isEmpty || still != nil }

    /// One frame for `seconds`, then back to the pose (a glance). Skipped under Reduce Motion.
    func hold(_ frame: NSImage, seconds: TimeInterval) {
        guard !Self.reduceMotion else { return }
        play([frame], every: seconds)
    }

    private func play(_ frames: [NSImage], every interval: TimeInterval) {
        stopSequence(keepLoop: true)
        sequence = frames
        step()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        sequenceTimer = t
    }

    private func step() {
        if sequence.isEmpty, !looping.isEmpty {
            sequence = looping
        }
        if sequence.isEmpty {
            stopSequence()
            current = OwlArt.poses[pose]
        } else {
            current = sequence.removeFirst()
        }
        needsDisplay = true
    }

    func stopSequence() { stopSequence(keepLoop: false) }

    private func stopSequence(keepLoop: Bool) {
        sequenceTimer?.invalidate()
        sequenceTimer = nil
        sequence = []
        if !keepLoop {
            looping = []
            if still != nil { still = nil; current = OwlArt.poses[pose]; needsDisplay = true }
        }
    }

    /// The editor behind him is dark: a soft light rim around the sprite
    /// (no backdrop disc), so the navy owl reads on dark themes.
    var onDarkBackground = false { didSet { if oldValue != onDarkBackground { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let current else { return }
        NSGraphicsContext.saveGraphicsState()
        // The rim follows the sprite's own outline: a tight light glow on
        // dark editors, a faint drop shadow on light ones.
        let rim = NSShadow()
        if onDarkBackground {
            rim.shadowBlurRadius = 2.5
            rim.shadowOffset = .zero
            rim.shadowColor = NSColor(white: 1, alpha: 0.75)
        } else {
            rim.shadowBlurRadius = 2
            rim.shadowOffset = NSSize(width: 0, height: -1)
            rim.shadowColor = NSColor(white: 0, alpha: 0.18)
        }
        rim.set()
        if pose == .talking {
            // The app's own bubble does the talking: hide the little "…"
            // bubble drawn in the top right of the talking art.
            let clip = NSBezierPath(rect: bounds)
            clip.append(NSBezierPath(rect: NSRect(x: bounds.width * 0.6, y: bounds.height * 0.64, width: bounds.width * 0.4, height: bounds.height * 0.36)))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        // Inset a little so the rim isn't cut off at the view's edge.
        current.draw(in: bounds.insetBy(dx: 2, dy: 2), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Click and drag

    /// A press that moves less than `OwlPlacement.dragThreshold` is a click.
    var onDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    /// The pointer's movement since the press, in the superview's coordinates.
    var onDragMoved: ((NSSize) -> Void)?
    var onDragEnded: (() -> Void)?
    private var pressPoint: NSPoint?
    private(set) var isDragging = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = superview?.convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard OwlPlacement.isDrag(from: start, to: p) else { return }
            isDragging = true
            NSCursor.closedHand.push()
            window?.invalidateCursorRects(for: self)
            onDragBegan?()
        }
        onDragMoved?(NSSize(width: p.x - start.x, height: p.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil }
        if isDragging {
            isDragging = false
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
            onDragEnded?()
            return
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
