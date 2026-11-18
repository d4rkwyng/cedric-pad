import AppKit
import CedricCore

/// Spell checking while typing, with the system's own checker
/// (NSSpellChecker: nothing downloaded, nothing sent anywhere).
///
/// NSTextView's continuous checking does the work (and gives the standard
/// right-click suggestions, Learn Spelling and Ignore Spelling), but every
/// batch of results passes through `EditorTextView.handleTextCheckingResults`,
/// which keeps only misspellings inside `SpellScope`: prose in Plain Text
/// and Markdown (not code spans or links), only comments and strings in
/// code, never identifiers. The marks are the text view's spelling state,
/// a drawing attribute: the text's colours are never touched.
@MainActor
final class EditorSpelling {
    /// Weak: a timer can fire after the tab is gone.
    private weak var tab: EditorWindowController?
    private var timer: Timer?

    init(tab: EditorWindowController) {
        self.tab = tab
    }

    /// The parts of `range` the checker may flag.
    func scope(for range: NSRange) -> [NSRange] {
        guard let tab else { return [] }
        let ns = tab.textView.string as NSString
        let range = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let index = tab.lineIndex
        guard index.lineCount > 0 else { return [] }
        let first = index.line(containing: range.location)
        let last = index.line(containing: NSMaxRange(range))
        let tokens = tab.colorizer.engine.tokens(forLines: first..<(last + 1), in: ns, index: index)
        return SpellScope.ranges(language: tab.doc.language, tokens: tokens, in: range)
    }

    func scopeContains(_ r: NSRange, in scope: [NSRange]) -> Bool {
        scope.contains { $0.location <= r.location && NSMaxRange(r) <= NSMaxRange($0) }
    }

    /// Turns checking on or off for the tab (View › Check Spelling While Typing).
    func apply() {
        // Large mode: no checking passes over a huge line.
        guard let tab else { return }
        let on = Settings.shared.checkSpellingWhileTyping && !tab.extrasPaused && checksThisDocument
        let tv = tab.textView
        tv.spelling = self
        if tv.isContinuousSpellCheckingEnabled != on { tv.isContinuousSpellCheckingEnabled = on }
    }

    /// Not data (JSON, YAML, TOML/INI/.env, XML, CSV/TSV): no underlines, no typo hints there.
    private var checksThisDocument: Bool {
        guard let tab else { return false }
        return SpellScope.checks(language: tab.doc.language, fileName: tab.doc.fileURL?.lastPathComponent)
    }

    /// The text changed or the language did: the owl looks again shortly.
    func schedule(after delay: TimeInterval = 1.0) {
        guard let tab, tab.owl != nil, !tab.extrasPaused, SpellScope.isProse(tab.doc.language), checksThisDocument, Settings.shared.checkSpellingWhileTyping else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerTypoFix() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Misspellings in scope within `range` (the visible lines by default).
    func misspellings(in range: NSRange? = nil) -> [NSRange] {
        guard checksThisDocument, let tv = tab?.textView else { return [] }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return [] }
        let r = range ?? tv.visibleCharacterRange ?? NSRange(location: 0, length: min(ns.length, 20_000))
        var found: [NSRange] = []
        for s in scope(for: r) where s.length > 0 {
            let results = NSSpellChecker.shared.check(tv.string, range: s, types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                                      options: nil, inSpellDocumentWithTag: tv.spellCheckerDocumentTag,
                                                      orthography: nil, wordCount: nil)
            found += results.map(\.range).filter { $0.length > 0 && NSMaxRange($0) <= NSMaxRange(s) }
        }
        return found
    }

    /// The owl's "Fix N typos?": the fixable misspellings with a first
    /// suggestion, as one replacement over the span they cover.
    func typoFix(_ ranges: [NSRange]) -> (range: NSRange, replacement: String, count: Int)? {
        guard let tv = tab?.textView else { return nil }
        let ns = tv.string as NSString
        var fixes: [(range: NSRange, replacement: String)] = []
        for r in ranges where NSMaxRange(r) <= ns.length {
            let word = ns.substring(with: r)
            guard SpellScope.isFixable(word, in: ns, at: r),
                  let guess = NSSpellChecker.shared.guesses(forWordRange: r, in: tv.string, language: nil,
                                                            inSpellDocumentWithTag: tv.spellCheckerDocumentTag)?.first else { continue }
            fixes.append((r, guess))
        }
        guard fixes.count >= 3, let c = SpellScope.combinedFix(ns, fixes) else { return nil }
        return (c.range, c.replacement, fixes.count)
    }

    private func offerTypoFix() {
        timer = nil
        guard let tab, let owl = tab.owl, SpellScope.isProse(tab.doc.language), checksThisDocument else { return }
        owl.offerTypoFix(self, tab: tab)
    }

    /// Edit › Spelling and Grammar › Check Document Now: the next
    /// misspelling after the selection (in scope), selected and shown in
    /// the spelling panel. The system's own checkSpelling: would stop on
    /// identifiers.
    func selectNext() {
        guard let tv = tab?.textView else { return }
        let ns = tv.string as NSString
        let all = misspellings(in: NSRange(location: 0, length: min(ns.length, 500_000)))
        let after = NSMaxRange(tv.selectedRange())
        guard let next = all.first(where: { $0.location >= after }) ?? all.first else { NSSound.beep(); return }
        tv.setSelectedRange(next)
        tv.scrollRangeToVisible(next)
        NSSpellChecker.shared.updateSpellingPanel(withMisspelledWord: ns.substring(with: next))
    }
}

extension EditorTextView {
    /// Every batch of continuous-checking results: only misspellings in
    /// scope are kept (see EditorSpelling). Recorded for the checks.
    override func handleTextCheckingResults(_ results: [NSTextCheckingResult], forRange range: NSRange,
                                            types checkingTypes: NSTextCheckingTypes,
                                            options: [NSSpellChecker.OptionKey: Any] = [:],
                                            orthography: NSOrthography, wordCount: Int) {
        guard let spelling else {
            super.handleTextCheckingResults(results, forRange: range, types: checkingTypes, options: options,
                                            orthography: orthography, wordCount: wordCount)
            return
        }
        let scope = spelling.scope(for: range)
        let kept = results.filter { r in
            r.resultType != .spelling || spelling.scopeContains(r.range, in: scope)
        }
        markedMisspellings.removeAll { NSIntersectionRange($0, range).length > 0 || NSMaxRange($0) > (string as NSString).length }
        markedMisspellings += kept.filter { $0.resultType == .spelling }.map(\.range)
        super.handleTextCheckingResults(kept, forRange: range, types: checkingTypes, options: options,
                                        orthography: orthography, wordCount: wordCount)
    }
}
