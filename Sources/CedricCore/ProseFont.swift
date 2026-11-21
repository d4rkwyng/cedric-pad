import Foundation

/// Settings › Writing › "Use a prose font for Markdown and plain text"
/// (0.4.1, UX review #9): a separate, usually proportional, font for prose
/// tabs, off by default. Code tabs keep the monospaced editor font. The
/// AppKit side (the font itself, its menu) is in Appearance.swift and
/// SettingsWindow.swift; the rules are here.
public enum ProseFont {
    /// The prose font's size at 100% zoom, by default: a little larger
    /// than the editor's 13 pt, as proportional text reads smaller.
    public static let defaultSize: Double = 15
    public static let sizeRange: ClosedRange<Double> = 6...72
    /// The saved name for the system's serif face (New York), which has
    /// no public PostScript name; nil is the system font (SF Pro).
    public static let systemSerif = "@system-serif"

    /// Markdown and plain text, the prose languages, and only when it is on.
    public static func applies(to language: Language, enabled: Bool) -> Bool {
        enabled && (language == .markdown || language == .plain)
    }

    public static func clamp(_ size: Double) -> Double {
        min(sizeRange.upperBound, max(sizeRange.lowerBound, size))
    }

    /// The prose font's point size: its own size, scaled by the editor's
    /// zoom (View › Zoom In/Out and the status bar's percentage change the
    /// editor font size; prose follows by the same ratio), clamped to 6–72.
    public static func size(prose: Double, editor: Double, editorDefault: Double) -> Double {
        guard editorDefault > 0, editor > 0 else { return clamp(prose) }
        return clamp((prose * editor / editorDefault * 2).rounded() / 2)
    }

    /// The width of one "character" for Readable Width's column: a
    /// fixed-pitch font's "0", a proportional font's average lowercase
    /// letter (a proportional "0" is wider than most letters, so the
    /// column would hold more characters of prose than the setting says).
    public static func characterWidth(fixedPitch: Bool, zeroWidth: Double, lowercaseAlphabetWidth: Double) -> Double {
        fixedPitch || lowercaseAlphabetWidth <= 0 ? zeroWidth : lowercaseAlphabetWidth / 26
    }

    /// Whether replacing a tab's whole text should re-apply the appearance
    /// (the text view's font, the gutter, Readable Width). The storage
    /// already carries the editor font. The view's font lags when the
    /// replacement crosses the large-document boundary, either way: a
    /// prose face gives way to the monospaced one, or comes back.
    ///
    /// `didApplyAppearance` is false only on the initial load, which
    /// applies the appearance once immediately afterwards. Applying it
    /// here as well would do that work twice before the first frame.
    public static func replacementNeedsAppearance(viewFontMatchesEditor: Bool, didApplyAppearance: Bool) -> Bool {
        didApplyAppearance && !viewFontMatchesEditor
    }
}
