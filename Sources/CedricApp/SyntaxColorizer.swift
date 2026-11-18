import AppKit
import CedricCore

/// Colours the text view from the highlight engine: only the lines near
/// the viewport (the visible range plus a margin), as TextKit 2 rendering
/// attributes, which change drawing without touching the text storage
/// (no undo entries, no re-layout). Tracks which lines are coloured so
/// scrolling back is free; an edit uncolours from the edited line down
/// (or only the edited lines for languages without cross-line state).
@MainActor
final class SyntaxColorizer {
    private weak var textView: EditorTextView?
    let engine: HighlightEngine
    private var colored = IndexSet()
    private var colors: [TokenKind: NSColor] = [:]
    private var pending = false
    /// Lines beyond the viewport to colour, above and below.
    static let margin = 80

    init(textView: EditorTextView, language: Language) {
        self.textView = textView
        engine = HighlightEngine(language: language)
    }

    func setPalette(_ p: EditorPalette) {
        colors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { ($0, NSColor(hex: p.color(for: $0))) })
        recolorAll()
    }

    func setLanguage(_ l: Language) {
        engine.setLanguage(l)
        recolorAll()
    }

    func recolorAll() {
        guard let tv = textView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
        tlm.removeRenderingAttribute(.foregroundColor, for: tcm.documentRange)
        colored = IndexSet()
        engine.invalidateAll()
        colorViewport()
    }

    /// After an edit: `firstLine` changed; `lineDelta` lines were added (+) or removed (−).
    func textDidChange(firstLine: Int, lineDelta: Int, lineCount: Int) {
        engine.invalidate(fromLine: firstLine)
        let tokenizerCarriesState = Languages.tokenizer(for: engine.language).carriesState
        if tokenizerCarriesState || lineDelta != 0 {
            colored.remove(integersIn: firstLine..<Int.max)
        } else {
            colored.remove(firstLine)
        }
        scheduleViewport()
    }

    /// Coalesces requests to one pass per run-loop turn.
    func scheduleViewport() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.colorViewport()
        }
    }

    var lineIndexProvider: () -> LineIndex = { LineIndex() }

    /// Colours whatever near the viewport isn't coloured yet. Returns the
    /// number of lines coloured (for the perf hooks).
    @discardableResult
    func colorViewport() -> Int {
        guard let tv = textView, let tlm = tv.textLayoutManager, let storage = tv.textStorage else { return 0 }
        guard let vr = tv.visibleCharacterRange else { return 0 }
        let index = lineIndexProvider()
        let first = max(0, index.line(containing: vr.location) - Self.margin)
        let last = min(index.lineCount, index.line(containing: vr.location + vr.length) + Self.margin + 1)
        var todo = IndexSet(integersIn: first..<last)
        todo.subtract(colored)
        guard !todo.isEmpty else { return 0 }
        let text = storage.string as NSString
        var count = 0
        for r in todo.rangeView {
            // Clear old colours on these lines, then apply the new tokens.
            let start = index.starts[r.lowerBound]
            let end = r.upperBound < index.lineCount ? index.starts[r.upperBound] : index.length
            if let whole = tv.textRange(for: NSRange(location: start, length: end - start)) {
                tlm.removeRenderingAttribute(.foregroundColor, for: whole)
            }
            let tokens = engine.tokens(forLines: r, in: text, index: index)
            for t in tokens {
                guard let range = tv.textRange(for: NSRange(location: t.start, length: t.length)), let c = colors[t.kind] else { continue }
                tlm.addRenderingAttribute(.foregroundColor, value: c, for: range)
            }
            count += r.count
        }
        colored.formUnion(todo)
        return count
    }
}
