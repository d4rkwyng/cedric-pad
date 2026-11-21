import Foundation

/// View › Readable Width (0.4.0): the editor's text in a centred column of
/// about `columns` characters, iA Writer-style, by widening the text view's
/// horizontal inset (no relayout while typing: only a width change moves
/// it). Per tab. Off for every language until the tab or the Writing
/// setting turns it on.
public enum ReadableWidth {
    public static let columnRange = 60...100
    public static let defaultColumns = 72
    /// The editor's normal horizontal inset.
    public static let minimumInset: Double = 4

    public static func clamp(_ columns: Int) -> Int {
        min(columnRange.upperBound, max(columnRange.lowerBound, columns))
    }

    /// Off for every language. A tab's own switch, or Settings › Writing,
    /// turns it on; there is no language that starts centred.
    public static func defaultOn(for _: Language) -> Bool { false }

    /// The gutter's left edge when it is drawn in the margin just left of
    /// the text column (`textMinX` in the same coordinates). Nil when that
    /// would cover the sidebar or run off the left edge: the gutter stays
    /// at the window edge and consumes width instead.
    public static func overlaidGutterMinX(textMinX: Double, gutterWidth: Double, sidebarWidth: Double) -> Double? {
        guard gutterWidth > 0, textMinX.isFinite, gutterWidth.isFinite, sidebarWidth.isFinite else { return nil }
        let x = textMinX - gutterWidth
        guard x >= sidebarWidth - 0.5 else { return nil }
        return x
    }

    /// The text container's width for `columns` characters of `charWidth`
    /// points each, with the container's line fragment padding both sides.
    public static func columnWidth(columns: Int, charWidth: Double, padding: Double) -> Double {
        (Double(clamp(columns)) * charWidth + 2 * padding).rounded(.up)
    }

    /// The horizontal inset that centres a `column`-wide text container in
    /// a view `viewWidth` wide: never under the normal inset, so a window
    /// narrower than the column just wraps as before.
    public static func inset(viewWidth: Double, column: Double) -> Double {
        max(minimumInset, ((viewWidth - column) / 2).rounded(.down))
    }
}
