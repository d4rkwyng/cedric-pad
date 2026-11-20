import Foundation

/// View › Readable Width (0.4.0): the editor's text in a centred column of
/// about `columns` characters, iA Writer-style, by widening the text view's
/// horizontal inset (no relayout while typing: only a width change moves
/// it). Per tab; on by default for Markdown and plain text.
public enum ReadableWidth {
    public static let columnRange = 60...100
    public static let defaultColumns = 72
    /// The editor's normal horizontal inset.
    public static let minimumInset: Double = 4

    public static func clamp(_ columns: Int) -> Int {
        min(columnRange.upperBound, max(columnRange.lowerBound, columns))
    }

    /// On by default for prose (Markdown, plain text), off for code.
    public static func defaultOn(for language: Language) -> Bool {
        language == .markdown || language == .plain
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
