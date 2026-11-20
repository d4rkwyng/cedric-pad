import Foundation
import NaturalLanguage

/// View › Writing Mode (0.4.0): typewriter scrolling and Focus. The math
/// and the range finding are here, pure; the app applies them
/// (WritingMode.swift in CedricApp).

/// A tab's writing-mode switches, kept in the session with the tab.
public struct WritingModeState: Codable, Equatable, Sendable {
    public var typewriter: Bool
    public var focus: Bool
    public init(typewriter: Bool = false, focus: Bool = false) {
        self.typewriter = typewriter
        self.focus = focus
    }
    public var isOff: Bool { !typewriter && !focus }
}

/// What Focus keeps bright.
public enum FocusUnit: String, Codable, CaseIterable, Sendable {
    case paragraph, sentence
}

public enum Typewriter {
    /// The bottom inset that lets the last line scroll up to the middle.
    public static func bottomInset(visibleHeight: Double, lineHeight: Double) -> Double {
        max(0, (visibleHeight - lineHeight) / 2).rounded(.down)
    }

    /// The scroll offset (the visible rect's top) that puts the caret
    /// line's middle at the middle of the visible height, clamped to what
    /// can be scrolled (`documentHeight` plus the bottom inset). Nil when
    /// the view is there already (within half a point): no scroll at all.
    /// Near the top the caret line sits higher (nothing above the text to
    /// scroll into).
    public static func scrollTarget(caretMidY: Double, visibleHeight: Double, currentY: Double,
                                    documentHeight: Double, bottomInset: Double) -> Double? {
        let maxY = max(0, documentHeight + bottomInset - visibleHeight)
        let target = min(maxY, max(0, (caretMidY - visibleHeight / 2).rounded()))
        return abs(target - currentY) < 0.5 ? nil : target
    }
}

public enum FocusRange {
    /// Paragraphs and sentences are looked for at most this far either way
    /// from the caret (a longer paragraph is clipped to that): a 636 K-character
    /// line must not be scanned per key.
    public static let scanLimit = 5_000

    /// The paragraph holding `caret`: its lines, up to (not including) the
    /// blank lines around it, without the last newline. On a blank line,
    /// that line (so everything else dims). Lines are LF-ended (the
    /// editor's text); a CR before the LF is kept with its line.
    public static func paragraph(in text: NSString, caret: Int) -> NSRange {
        let n = text.length
        let c = max(0, min(caret, n))
        let lo = max(0, c - scanLimit), hi = min(n, c + scanLimit)
        // One copy of the window; lines are found in it (getLineStart would
        // walk the whole of a 636 K-character line on every key).
        var u = [unichar](repeating: 0, count: hi - lo)
        if hi > lo { u.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: lo, length: hi - lo)) } }
        // Window-relative: the line holding i runs from lineStart(i) to lineEnd(i) (its newline included).
        func lineStart(_ i: Int) -> Int {
            var j = i
            while j > 0, u[j - 1] != 10 { j -= 1 }
            return j
        }
        func lineEnd(_ i: Int) -> Int {
            var j = i
            while j < u.count, u[j] != 10 { j += 1 }
            return j < u.count ? j + 1 : j
        }
        func isBlank(_ a: Int, _ b: Int) -> Bool {
            var i = a
            while i < b {
                let x = u[i]
                if x != 32 && x != 9 && x != 10 && x != 13 { return false }
                i += 1
            }
            return true
        }
        let cc = c - lo
        var start = lineStart(cc), end = lineEnd(cc)
        if isBlank(start, end) { return trimNewline(NSRange(location: lo + start, length: end - start), in: text) }
        while start > 0 {
            let ps = lineStart(start - 1)
            if isBlank(ps, start) { break }
            start = ps
        }
        while end < u.count {
            let ne = lineEnd(end)
            if isBlank(end, ne) { break }
            end = ne
        }
        return trimNewline(NSRange(location: lo + start, length: end - start), in: text)
    }

    /// The sentence holding `caret`, inside its paragraph (NaturalLanguage's
    /// sentence tokenizer, so "Dr. Smith" and "3.5" don't end one), without
    /// the spaces after it. A caret just after a sentence's last character
    /// is in that sentence; in the spaces before the next, in the next.
    public static func sentence(in text: NSString, caret: Int) -> NSRange {
        let para = paragraph(in: text, caret: caret)
        guard para.length > 0 else { return para }
        let s = text.substring(with: para)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = s
        let local = max(0, min(caret, NSMaxRange(para))) - para.location
        var found: NSRange?
        var last: NSRange?
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in
            let ns = NSRange(r, in: s)
            let trimmed = trimTrailingSpace(ns, in: s as NSString)
            last = trimmed
            if local >= ns.location && local <= NSMaxRange(trimmed) { found = trimmed; return false }
            if local < ns.location { found = trimmed; return false }   // was in the spaces before this one
            return true
        }
        guard let hit = found ?? last else { return para }
        return NSRange(location: para.location + hit.location, length: hit.length)
    }

    public static func range(_ unit: FocusUnit, in text: NSString, caret: Int) -> NSRange {
        unit == .paragraph ? paragraph(in: text, caret: caret) : sentence(in: text, caret: caret)
    }

    /// The parts of `visible` outside `focus`: what Focus dims (at most two ranges).
    public static func dimmed(visible: NSRange, focus: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        let before = NSRange(location: visible.location, length: max(0, min(NSMaxRange(visible), focus.location) - visible.location))
        if before.length > 0 { out.append(before) }
        let afterStart = max(visible.location, NSMaxRange(focus))
        let after = NSRange(location: afterStart, length: max(0, NSMaxRange(visible) - afterStart))
        if after.length > 0 { out.append(after) }
        return out
    }

    private static func trimNewline(_ r: NSRange, in text: NSString) -> NSRange {
        var len = r.length
        while len > 0, text.character(at: r.location + len - 1) == 10 || text.character(at: r.location + len - 1) == 13 { len -= 1 }
        return NSRange(location: r.location, length: len)
    }

    private static func trimTrailingSpace(_ r: NSRange, in text: NSString) -> NSRange {
        var len = r.length
        while len > 0 {
            let u = text.character(at: r.location + len - 1)
            guard u == 32 || u == 9 || u == 10 || u == 13 || u == 0xA0 || u == 0x3000 else { break }
            len -= 1
        }
        return NSRange(location: r.location, length: len)
    }
}
