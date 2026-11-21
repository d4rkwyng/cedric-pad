import Foundation

/// File › Print… line-number column. The editor's gutter measures a digit
/// (`EditorTextView.requiredWidth`); print used to measure a space, which
/// matches a digit only in a monospaced face. A proportional prose font's
/// digits are wider, and the numbers then collide with the text.
public enum PrintMetrics {
    /// Places reserved for the line number: at least two, so 1–9 don't
    /// sit in a one-wide column.
    public static func digitPlaces(lineCount: Int) -> Int {
        max(2, String(max(0, lineCount)).count)
    }

    /// The widest of the measured digit widths (0–9). Zero when none were measured.
    public static func widestDigit(_ widths: some Sequence<Double>) -> Double {
        widths.max() ?? 0
    }

    /// The line-number column: `digitPlaces` times the widest digit, never
    /// a space. `lineCount` is the document's line count (the same count
    /// the column used to take its number of places from).
    public static func lineNumberColumnWidth(widestDigit: Double, lineCount: Int) -> Double {
        widestDigit * Double(digitPlaces(lineCount: lineCount))
    }
}
