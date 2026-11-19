import Foundation
import CoreGraphics

/// Where the Ask Cedric panel opens: next to the owl, wherever he sits.
///
/// Beside him, on the side (left or right) with more room on the screen,
/// `gap` points away; its bottom level with his feet when he sits low on
/// the screen, its top level with his head when he sits high. When
/// neither side has room for the panel, above or below him instead
/// (whichever has more room). Always kept inside `screen` (the screen's
/// visible frame), `margin` from its edges.
///
/// The app uses it only when the owl is on screen and the user hasn't
/// moved the panel this session (`OwlChatPanel.show`); otherwise the
/// panel keeps its place, or opens at the window's bottom-right corner.
///
/// Coordinates are y-up screen points (AppKit), origin bottom-left.
public enum OwlChatPlacement {
    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 4

    public static func panelOrigin(owl: CGRect, panel size: CGSize, screen: CGRect,
                                   gap: CGFloat = gap, margin: CGFloat = margin) -> CGPoint {
        let inner = screen.insetBy(dx: margin, dy: margin)
        let roomRight = inner.maxX - (owl.maxX + gap)
        let roomLeft = (owl.minX - gap) - inner.minX
        var o: CGPoint
        if max(roomLeft, roomRight) >= size.width {
            // Beside him.
            let right = roomRight >= roomLeft
            let x = right ? owl.maxX + gap : owl.minX - gap - size.width
            let low = (owl.midY - inner.minY) <= (inner.maxY - owl.midY)
            let y = low ? owl.minY : owl.maxY - size.height
            o = CGPoint(x: x, y: y)
        } else {
            // A narrow screen: above or below him.
            let roomAbove = inner.maxY - (owl.maxY + gap)
            let roomBelow = (owl.minY - gap) - inner.minY
            let y = roomAbove >= roomBelow ? owl.maxY + gap : owl.minY - gap - size.height
            o = CGPoint(x: owl.midX - size.width / 2, y: y)
        }
        return clamp(o, size: size, in: inner)
    }

    /// Inside `bounds` (pinned to its top-left when the panel is larger:
    /// the title bar stays reachable).
    static func clamp(_ o: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: max(bounds.minX, min(o.x, bounds.maxX - size.width)),
                y: min(bounds.maxY - size.height, max(o.y, bounds.minY)))
    }
}
