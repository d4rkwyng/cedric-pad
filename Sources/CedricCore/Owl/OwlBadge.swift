import Foundation

/// The iOS owl's state beside the hints: shown or not, the count badge,
/// whether he pulses for a new hint, and what VoiceOver says. Pure, so the
/// rules are tested (OwlBadgeTests).
public struct OwlBadge: Equatable, Sendable {
    public var hidden: Bool
    /// The number on the badge; 0: no badge.
    public var count: Int
    /// Play the attention pulse now (a hint arrived that wasn't there).
    public var pulse: Bool
    public var accessibilityLabel: String

    public init(hidden: Bool, count: Int, pulse: Bool, accessibilityLabel: String) {
        self.hidden = hidden
        self.count = count
        self.pulse = pulse
        self.accessibilityLabel = accessibilityLabel
    }

    /// - hints: hints waiting now; previous: before this change.
    /// - bubbleOpen: one is showing in his bubble (no badge, no pulse then).
    /// - hintsOn: the offline hints setting; off hides him.
    /// - largeDocument: large mode keeps him out of the way.
    /// - reduceMotion: no pulse; the badge alone says it.
    public static func make(hints: Int, previous: Int, bubbleOpen: Bool, hintsOn: Bool,
                            largeDocument: Bool, reduceMotion: Bool) -> OwlBadge {
        let hidden = !hintsOn || largeDocument
        let count = hidden || bubbleOpen ? 0 : max(0, hints)
        let pulse = count > 0 && hints > previous && !reduceMotion
        return OwlBadge(hidden: hidden, count: count, pulse: pulse, accessibilityLabel: label(count))
    }

    public static func label(_ count: Int) -> String {
        switch count {
        case 0: return String(localized: "Cedric")
        case 1: return String(localized: "Cedric, 1 hint")
        default: return String(localized: "Cedric, \(count) hints")
        }
    }
}
