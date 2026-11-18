import Foundation

/// A tab's language and who decided it.
///
/// - `.auto`: an untitled tab nobody has chosen a language for. Typing and
///   pasting sniff the content and may switch it (shown as "HTML (auto)").
/// - `.manual`: picked from the language menu. Never switched again
///   automatically, not by typing, pasting or saving.
/// - `.file`: the tab has a file. Its extension decided (or, without a
///   known extension, the content did once); content no longer switches it.
public struct LanguageChoice: Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case auto, manual, file }

    public private(set) var language: Language
    public private(set) var source: Source

    public init(language: Language = .plain, source: Source = .auto) {
        self.language = language
        self.source = source
    }

    /// For a file being opened (or restored).
    public static func forFile(named name: String, content: String) -> LanguageChoice {
        LanguageChoice(language: LanguageDetector.detect(fileName: name, content: content), source: .file)
    }

    /// For untitled text (restored or handed in): auto, with a first guess.
    public static func untitled(content: String) -> LanguageChoice {
        LanguageChoice(language: LanguageDetector.sniff(content), source: .auto)
    }

    public var isAuto: Bool { source == .auto }
    public var isManual: Bool { source == .manual }

    /// The status bar's title: "HTML (auto)" while auto-detected.
    public var displayTitle: String {
        isAuto && language != .plain ? String(localized: "\(language.displayName) (auto)") : language.displayName
    }

    /// Typed or pasted text changed the buffer. Sniffs only while the tab
    /// is untitled and auto. Returns true when the language changed.
    @discardableResult
    public mutating func textChanged(_ text: String, isUntitled: Bool) -> Bool {
        guard isUntitled, source == .auto else { return false }
        let guess = LanguageDetector.sniff(text)
        // A guess replaces the current one; "no idea" only goes back to
        // plain once the text is empty, so a half-typed line doesn't flap.
        let next: Language
        if guess != .plain {
            next = guess
        } else if text.allSatisfy(\.isWhitespace) {
            next = .plain
        } else {
            next = language
        }
        guard next != language else { return false }
        language = next
        return true
    }

    /// Picked from the language menu.
    public mutating func choose(_ l: Language) {
        language = l
        source = .manual
    }

    /// Saved to (or renamed as) `fileName`. A manual choice stands; else the
    /// extension decides, and the content once if it has none.
    @discardableResult
    public mutating func saved(fileName: String, content: String) -> Bool {
        guard source != .manual else { return false }
        let old = language
        if let l = LanguageDetector.language(forFileName: fileName) {
            language = l
        } else if source == .auto {
            language = LanguageDetector.sniff(content)
        }
        source = .file
        return language != old
    }
}
