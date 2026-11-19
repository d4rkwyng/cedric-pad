import Foundation

/// View › Split Editor, as the session keeps it: two panes on one
/// document. Nil in a `SessionTab` when the tab isn't split (and in
/// sessions saved before 0.3.0).
public struct SplitEditorState: Codable, Equatable, Sendable {
    /// Side by side (true) or top and bottom (false, the default).
    public var sideBySide: Bool
    /// The first pane's share of the room, 0…1 (clamped on use).
    public var ratio: Double
    /// The second pane's first visible line (0-based).
    public var topLine: Int
    /// The second pane had the focus.
    public var secondFocused: Bool?

    public init(sideBySide: Bool = false, ratio: Double = 0.5, topLine: Int = 0, secondFocused: Bool? = nil) {
        self.sideBySide = sideBySide
        self.ratio = ratio
        self.topLine = topLine
        self.secondFocused = secondFocused
    }

    /// Neither pane smaller than this (points), when the room allows.
    public static let minPane: Double = 60

    /// A ratio from a saved or dragged value: finite, within 0.05…0.95.
    public static func clampRatio(_ r: Double) -> Double {
        guard r.isFinite else { return 0.5 }
        return min(0.95, max(0.05, r))
    }

    /// Where the divider goes (the first pane's length) in `total` points
    /// with a divider `thickness` thick, keeping both panes at least
    /// `minPane` long when there is room for that.
    public static func dividerPosition(ratio: Double, total: Double, thickness: Double) -> Double {
        let room = max(0, total - thickness)
        let want = (room * clampRatio(ratio)).rounded()
        guard room >= 2 * minPane else { return (room / 2).rounded() }
        return min(room - minPane, max(minPane, want))
    }

    /// The ratio a divider at `position` gives (the inverse of dividerPosition).
    public static func ratio(position: Double, total: Double, thickness: Double) -> Double {
        let room = total - thickness
        guard room > 0 else { return 0.5 }
        return clampRatio(position / room)
    }
}

/// Which pane the editor's commands act on. The focused pane while one
/// of the two text views is first responder; when focus moves to
/// something else in the window (the find bar, a side panel, a sheet),
/// the last focused pane stays the target, so Find in the find bar acts
/// on the pane it was opened from.
public struct PaneFocus: Equatable, Sendable {
    public enum Pane: Equatable, Sendable { case first, second }

    public private(set) var isSplit = false
    public private(set) var active: Pane = .first

    public init() {}

    /// A pane's text view became first responder; nil: something else did.
    public mutating func focused(_ pane: Pane?) {
        guard let pane else { return }
        active = isSplit ? pane : .first
    }

    /// The split was made: the new pane takes the focus or not.
    public mutating func split(focusSecond: Bool) {
        isSplit = true
        active = focusSecond ? .second : .first
    }

    /// Unsplit: only the first pane is left.
    public mutating func unsplit() {
        isSplit = false
        active = .first
    }

    /// View › Move Focus to Other Pane: the pane to focus (nil unsplit).
    public var other: Pane? {
        guard isSplit else { return nil }
        return active == .first ? .second : .first
    }
}
