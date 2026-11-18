import AppKit
import CedricCore

/// The owl art from Resources/Owl (made by tools/icon/cedric_icon.py):
/// loaded once, from Cedric.app/Contents/Resources/Owl, else
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
        guard p != pose || sequenceTimer != nil else { return }
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
        play([f[1], f[2], f[2], f[1]], every: 0.05)
    }

    /// The monocle polish: the pose for a moment, then back.
    func polish() {
        guard pose == .idle, let img = OwlArt.poses[.polish] else { return }
        play([img], every: 1.6)
    }

    /// Two wing beats (on save).
    func flap() {
        let f = OwlArt.flap
        guard f.count == 4, pose != .talking else { return }
        play([f[1], f[2], f[3], f[0], f[1], f[2], f[3]], every: 0.07)
    }

    private func play(_ frames: [NSImage], every interval: TimeInterval) {
        stopSequence()
        sequence = frames
        step()
        sequenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        if sequence.isEmpty {
            stopSequence()
            current = OwlArt.poses[pose]
        } else {
            current = sequence.removeFirst()
        }
        needsDisplay = true
    }

    func stopSequence() {
        sequenceTimer?.invalidate()
        sequenceTimer = nil
        sequence = []
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let current else { return }
        // A soft light disc behind the navy owl on dark themes, so it reads.
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            let d = bounds.width * 0.62
            let r = NSRect(x: bounds.midX - d / 2, y: bounds.height * 0.02, width: d, height: d)
            NSColor(white: 1, alpha: 0.13).setFill()
            NSBezierPath(ovalIn: r).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        if pose == .talking {
            // The app's own bubble does the talking: hide the little "…"
            // bubble drawn in the top right of the talking art.
            let clip = NSBezierPath(rect: bounds)
            clip.append(NSBezierPath(rect: NSRect(x: bounds.width * 0.6, y: bounds.height * 0.64, width: bounds.width * 0.4, height: bounds.height * 0.36)))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        current.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
