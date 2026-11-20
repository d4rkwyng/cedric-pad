import Foundation
import CoreGraphics

/// Layout rules for a foldable screen (iPhone Duo) and for rounded,
/// edge-to-edge displays, as pure geometry so they are tested without a
/// device. Rects are in one view's coordinates (y-down on iOS); a fold is
/// a reserved "division" region the system reports, a tall thin rect.
public enum FoldLayout {
    /// The folds that cross `content` vertically with at least `minPane`
    /// of content on each side (a fold at the very edge doesn't split it).
    public static func crossingFolds(_ folds: [CGRect], content: CGRect, minPane: CGFloat = 120) -> [CGRect] {
        folds.filter { f in
            f.height >= f.width && f.midX > content.minX + minPane && f.midX < content.maxX - minPane
                && f.minY < content.maxY && f.maxY > content.minY
        }
    }

    /// Two panes side by side (text and preview): the leading pane's width
    /// and the gap between them. On a fold the seam sits on it, the gap as
    /// wide as the fold region (at least `spacing`); otherwise equal halves.
    /// `rightToLeft`: the leading pane is on the right.
    public static func split(content: CGRect, folds: [CGRect], spacing: CGFloat = 1,
                             rightToLeft: Bool = false) -> (leading: CGFloat, gap: CGFloat) {
        guard let f = crossingFolds(folds, content: content).first else {
            return (max(0, (content.width - spacing) / 2), spacing)
        }
        let gap = max(spacing, f.width)
        let leading = rightToLeft ? content.maxX - f.maxX : f.minX - content.minX
        return (max(0, leading - max(0, gap - f.width) / 2), gap)
    }

    /// Where a floating element (a toast, a bubble) may go: `area`, or the
    /// half of it on one side of a fold crossing it. `trailing` picks the
    /// trailing half (Apple's alerts go there), else the leading one.
    public static func lane(in area: CGRect, folds: [CGRect], trailing: Bool, rightToLeft: Bool = false,
                            gap: CGFloat = 8) -> CGRect {
        guard let f = crossingFolds(folds, content: area).first else { return area }
        let right = trailing != rightToLeft
        if right {
            let x = f.maxX + gap
            return CGRect(x: x, y: area.minY, width: max(0, area.maxX - x), height: area.height)
        }
        return CGRect(x: area.minX, y: area.minY, width: max(0, f.minX - gap - area.minX), height: area.height)
    }

    /// The rect inside `bounds` left by `insets` (top, left, bottom, right):
    /// the safe area for given safe-area insets.
    public static func inset(_ bounds: CGRect, top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> CGRect {
        CGRect(x: bounds.minX + left, y: bounds.minY + top,
               width: max(0, bounds.width - left - right), height: max(0, bounds.height - top - bottom))
    }

    /// Every frame lies inside `safe` (to half a point): the check that no
    /// bar control sits under a rounded corner, a sensor or a vertical bar.
    public static func allInside(_ frames: [CGRect], _ safe: CGRect) -> Bool {
        let s = safe.insetBy(dx: -0.5, dy: -0.5)
        return frames.allSatisfy { $0.isEmpty || s.contains($0) }
    }
}

/// What survives a fold or unfold that hides the text (iPhone Duo closed
/// with the Markdown preview on): the selection, the scroll position and
/// whether the keyboard was up, put back when the text shows again.
public struct EditorContinuity: Equatable, Sendable {
    public var selection: NSRange
    public var contentOffset: CGPoint
    public var wasEditing: Bool

    public init(selection: NSRange, contentOffset: CGPoint, wasEditing: Bool) {
        self.selection = selection
        self.contentOffset = contentOffset
        self.wasEditing = wasEditing
    }

    /// The selection to restore in a text now `length` long (it may have
    /// changed meanwhile, e.g. reloaded from iCloud): clamped inside it.
    public func restoredSelection(length: Int) -> NSRange {
        let loc = max(0, min(selection.location, length))
        return NSRange(location: loc, length: max(0, min(selection.length, length - loc)))
    }

    /// The scroll offset to restore, clamped to what the content allows
    /// (`maxOffset`: content height minus visible height, at least 0).
    public func restoredOffset(maxOffset: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(contentOffset.x, max(0, maxOffset.x))),
                y: max(0, min(contentOffset.y, max(0, maxOffset.y))))
    }
}

/// The iOS editor's default font size: bigger on large screens (an iPad,
/// or an unfolded iPhone Duo, which is regular in both directions) than on
/// a phone-sized one. Size classes, not the device idiom: the Duo reports
/// "phone" either way.
public enum EditorDefaults {
    public static func fontSize(regularWidth: Bool, regularHeight: Bool) -> Double {
        regularWidth && regularHeight ? 15 : 13
    }
}
