import Foundation

/// When a document is "large": big enough, or with a line long enough, that
/// the normal editing extras (colouring, the owl, spell check) cost more
/// than they give. In large mode the editor shows a slim info bar, cuts
/// long lines into chunks for TextKit (ChunkedContentStorage in the app),
/// pauses colouring and spell check, and the owl stays idle: no rules, no
/// AI, unless the user clicks him.
///
/// Thresholds, from measurements on an M4 Pro (Scripts/perf-check.sh,
/// docs/architecture.md › Large documents): TextKit 2 lays out a paragraph
/// as a whole, so a keystroke on one long line costs ~0.16 µs per
/// character of that line: 5 ms at 20,000 characters, 9 ms at 40,000,
/// 24 ms at 80,000 and 100–140 ms at 636,000 (Derek's file). 20,000 keeps
/// a keystroke well under a frame on slower Macs too. Many-line files stay
/// fast to far larger sizes (a 50 MB log types in 3 ms), so the size
/// threshold is only for the extras' sake.
public enum LargeDocument {
    /// Any line longer than this (UTF-16 code units) turns large mode on.
    public static let lineThreshold = 20_000
    /// So does a document longer than this (UTF-16 code units, ≈ 5 MB of ASCII).
    public static let sizeThreshold = 5_000_000
    /// The chunk length TextKit sees for lines longer than this.
    public static let chunkLength = 2_048

    public enum Reason: String, Sendable, Equatable {
        case longLine, size
    }

    /// Why `index`'s document is large, or nil.
    public static func reason(for index: LineIndex) -> Reason? {
        if index.length > sizeThreshold { return .size }
        // A line can only be that long if the document is.
        if index.length > lineThreshold, index.longestLine > lineThreshold { return .longLine }
        return nil
    }

    /// After an edit: lines `lines` changed. Cheap (the edited lines only),
    /// for typing and pasting into a document that wasn't large.
    public static func reason(afterEditOf lines: Range<Int>, in index: LineIndex) -> Reason? {
        if index.length > sizeThreshold { return .size }
        guard index.length > lineThreshold else { return nil }
        for i in lines where i < index.lineCount && index.lineLength(i) > lineThreshold { return .longLine }
        return nil
    }
}
