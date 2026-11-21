import AppKit
import CedricCore

/// View › Readable Width (0.4.0): the text in a centred column of
/// Settings › Readable width characters (72 by default), iA Writer-style.
/// Per tab, off until the tab turns it on or Settings › Writing's
/// checkbox is checked; only while lines wrap.
///
/// The column is the text view's horizontal inset (EditorTextView
/// `readableColumnWidth`), set again only when the view's width, the font
/// or the switch changes: typing never touches it, and nothing else moves.
/// With the column on, the gutter (line numbers, folds, git bars) is drawn
/// in the margin just left of the text (EditorContainer). Typewriter
/// Scrolling and Focus work on lines and the vertical scroll, so they act
/// the same in the column.
extension EditorWindowController {
    /// The tab's switch (its own, else the Writing default, which is off).
    var readableWidthOn: Bool { editing.readableWidth ?? Settings.shared.readableWidthDefault }
    /// On, and lines wrap (without wrapping there is no column to keep).
    var readableWidthActive: Bool { readableWidthOn && wrapsLines }

    func setReadableWidth(_ on: Bool) {
        editing.readableWidth = on
        applyReadableWidth()
    }

    func applyReadableWidth() {
        for pane in panes { applyReadableWidth(to: pane) }
    }

    func applyReadableWidth(to pane: EditorPane) {
        let tv = pane.textView
        guard readableWidthActive else { tv.readableColumnWidth = nil; return }
        let font = tv.font ?? Settings.shared.font
        let charWidth = font.readableCharacterWidth
        let padding = tv.textContainer?.lineFragmentPadding ?? 0
        tv.readableColumnWidth = CGFloat(ReadableWidth.columnWidth(columns: Settings.shared.readableColumns,
                                                                    charWidth: Double(charWidth), padding: Double(padding)))
    }
}

extension NSFont {
    /// One character of Readable Width's column: "0" in a fixed-pitch
    /// font, the average lowercase letter in a proportional (prose) font.
    var readableCharacterWidth: CGFloat {
        let zero = ("0" as NSString).size(withAttributes: [.font: self]).width
        if isFixedPitch { return zero }
        let letters = ("abcdefghijklmnopqrstuvwxyz" as NSString).size(withAttributes: [.font: self]).width
        return CGFloat(ProseFont.characterWidth(fixedPitch: false, zeroWidth: Double(zero), lowercaseAlphabetWidth: Double(letters)))
    }
}

extension AppDelegate {
    @objc func toggleReadableWidthMenu(_ sender: Any?) {
        guard let tab = currentTab else { NSSound.beep(); return }
        tab.setReadableWidth(!tab.readableWidthOn)
    }

    func validateReadableWidthItem(_ item: NSMenuItem) -> Bool? {
        guard item.action == #selector(toggleReadableWidthMenu(_:)) else { return nil }
        let tab = currentTab
        item.state = tab?.readableWidthOn == true ? .on : .off
        // Lines must wrap for a column (View › Wrap Lines).
        return tab != nil && Settings.shared.wrapLines
    }
}
