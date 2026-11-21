import UIKit
import CedricCore

/// Colours the text view from the core's `HighlightEngine`, as the Mac's
/// SyntaxColorizer does: only the lines near the viewport, as
/// foreground-colour attributes on the text storage. Tracks which lines are
/// coloured so scrolling back is free; an edit uncolours from the edited
/// line down (or only the edited lines for languages without cross-line
/// state).
@MainActor
final class SyntaxColorizer {
    private weak var textView: UITextView?
    let engine: HighlightEngine
    private var colored = IndexSet()
    private var colors: [TokenKind: UIColor] = [:]
    private(set) var foreground: UIColor = .label
    private var pending = false
    static let margin = 80
    var lineIndex: () -> LineIndex = { LineIndex() }

    init(textView: UITextView, language: Language) {
        self.textView = textView
        engine = HighlightEngine(language: language)
    }

    func setPalette(_ p: EditorPalette) {
        colors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { ($0, UIColor(hex: p.color(for: $0))) })
        foreground = UIColor(hex: p.foreground)
        recolorAll()
    }

    func setLanguage(_ l: Language) {
        engine.setLanguage(l)
        recolorAll()
    }

    func recolorAll() {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        colored = IndexSet()
        engine.invalidateAll()
        if storage.length > 0, tv.markedTextRange == nil {
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        colorViewport()
    }

    func textDidChange(firstLine: Int, lastLine: Int, lineDelta: Int) {
        engine.invalidate(fromLine: firstLine)
        if Languages.tokenizer(for: engine.language).carriesState || lineDelta != 0 {
            colored.remove(integersIn: firstLine..<Int.max)
        } else {
            colored.remove(integersIn: firstLine...max(firstLine, lastLine))
        }
        scheduleViewport()
    }

    func scheduleViewport() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.colorViewport()
        }
    }

    /// The UTF-16 range on screen.
    static func visibleRange(_ tv: UITextView) -> NSRange? {
        let r = tv.bounds
        guard let a = tv.closestPosition(to: CGPoint(x: r.minX, y: r.minY)),
              let b = tv.closestPosition(to: CGPoint(x: r.maxX, y: r.maxY)) else { return nil }
        let s = tv.offset(from: tv.beginningOfDocument, to: a), e = tv.offset(from: tv.beginningOfDocument, to: b)
        return NSRange(location: min(s, e), length: abs(e - s))
    }

    @discardableResult
    func colorViewport() -> Int {
        guard let tv = textView else { return 0 }
        let storage = tv.textStorage
        if tv.markedTextRange != nil { scheduleLater(); return 0 }
        guard storage.editedMask.isEmpty else { scheduleViewport(); return 0 }
        guard let vr = Self.visibleRange(tv) else { return 0 }
        let index = lineIndex()
        guard index.length == storage.length else { scheduleViewport(); return 0 }
        let first = max(0, index.line(containing: vr.location) - Self.margin)
        let last = min(index.lineCount, index.line(containing: min(index.length, vr.location + vr.length)) + Self.margin + 1)
        var todo = IndexSet(integersIn: first..<max(first, last))
        todo.subtract(colored)
        guard !todo.isEmpty else { return 0 }
        let text = storage.string as NSString
        var count = 0
        storage.beginEditing()
        for r in todo.rangeView {
            let start = index.starts[r.lowerBound]
            let end = r.upperBound < index.lineCount ? index.starts[r.upperBound] : index.length
            if end > start { storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: start, length: end - start)) }
            for t in engine.tokens(forLines: r, in: text, index: index) {
                guard let c = colors[t.kind], t.start + t.length <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: c, range: NSRange(location: t.start, length: t.length))
            }
            count += r.count
        }
        storage.endEditing()
        colored.formUnion(todo)
        return count
    }

    private func scheduleLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.colorViewport() }
    }
}
