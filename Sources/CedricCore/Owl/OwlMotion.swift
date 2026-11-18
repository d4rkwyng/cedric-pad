import Foundation

/// How the owl moves, as pure rules (the app's OwlView/OwlController follow
/// them): which animation plays, which becomes a still frame under
/// System Settings › Accessibility › Reduce Motion, how long until the next
/// idle tick, and which gaze or pointing frame faces a direction.
public enum OwlMotion {
    public enum Animation: String, Sendable, CaseIterable {
        // Gestures: short, once.
        case blink, glance, lookAtCaret, polish, flap, wave, nod, point
        // Lasting states: shown while they last.
        case think, search, write
    }

    public enum Render: Sendable, Equatable { case play, still, skip }

    /// Reduce Motion: gestures are skipped, states are one still frame.
    public static func render(_ a: Animation, reduceMotion: Bool) -> Render {
        switch a {
        case .think, .search, .write: return reduceMotion ? .still : .play
        default: return reduceMotion ? .skip : .play
        }
    }

    /// Seconds until the next idle tick: a blink or glance every 4–9 s,
    /// never past the time he falls asleep; under Reduce Motion only the
    /// one timer that puts him to sleep.
    public static func idleDelay(untilSleep: TimeInterval, reduceMotion: Bool, random: Double) -> TimeInterval {
        reduceMotion ? max(0.5, untilSleep) : max(0.5, min(4 + 5 * min(max(random, 0), 1), untilSleep))
    }

    /// The look-strip frame (right, up-right, up, up-left, left, down-left,
    /// down, down-right) nearest the direction (y up); nil for none.
    public static func gazeIndex(dx: Double, dy: Double) -> Int? {
        guard dx != 0 || dy != 0 else { return nil }
        let i = Int((atan2(dy, dx) / (Double.pi / 4)).rounded())
        return (i + 8) % 8
    }

    /// The point-strip frame (right, up, left, down) for a direction (y up).
    public static func pointIndex(dx: Double, dy: Double) -> Int {
        abs(dx) >= abs(dy) ? (dx >= 0 ? 0 : 2) : (dy >= 0 ? 1 : 3)
    }
}
