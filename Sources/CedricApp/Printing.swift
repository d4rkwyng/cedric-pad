import AppKit
import CedricCore

// File › Print… (⌘P) and Page Setup… (⇧⌘P). Built only when used: a
// separate TextKit 1 text view laid out for the page width (so long lines
// wrap whatever the editor's Wrap Lines setting), in the editor's font,
// dark text on the paper's white rather than the theme's colours. Line
// numbers are an option in the print panel.

/// The text as printed: one paragraph per line; with line numbers, each
/// starts with its number right-aligned in a column, and wrapped lines
/// continue to the right of it.
@MainActor
enum PrintLayout {
    static func attributedText(_ text: String, font: NSFont, tabWidth: Int, lineNumbers: Bool) -> NSAttributedString {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let ns = text as NSString
        let index = LineIndex(ns)
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = space * CGFloat(tabWidth)
        para.lineBreakMode = .byWordWrapping
        var numberWidth: CGFloat = 0
        if lineNumbers {
            let digits = max(2, String(index.lineCount).count)
            numberWidth = space * CGFloat(digits)
            let gap = space * 2
            para.headIndent = numberWidth + gap
            // The number (right-aligned), the text, then the text's own tab stops.
            para.tabStops = [NSTextTab(textAlignment: .right, location: numberWidth), NSTextTab(textAlignment: .left, location: para.headIndent)]
                + (1...64).map { NSTextTab(textAlignment: .left, location: para.headIndent + space * CGFloat(tabWidth * $0)) }
        } else {
            para.tabStops = []
        }
        let ink: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para]
        guard lineNumbers else { return NSAttributedString(string: text, attributes: ink) }
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.gray, .paragraphStyle: para]
        let out = NSMutableAttributedString()
        out.beginEditing()
        // An empty last line after a final newline isn't numbered.
        let count = index.lineCount > 1 && index.lineLength(index.lineCount - 1) == 0 ? index.lineCount - 1 : index.lineCount
        for line in 0..<count {
            out.append(NSAttributedString(string: "\t\(line + 1)\t", attributes: numberAttrs))
            let r = NSRange(location: index.starts[line], length: index.lineLength(line))
            out.append(NSAttributedString(string: ns.substring(with: r), attributes: ink))
        }
        out.endEditing()
        return out
    }
}

/// The view that prints: re-laid out for the paper when the options change.
@MainActor
final class PrintTextView: NSTextView {
    var source = ""
    var printFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    var tabWidth = 4
    var lineNumbers = false { didSet { if lineNumbers != oldValue { reload() } } }

    func reload() {
        textStorage?.setAttributedString(PrintLayout.attributedText(source, font: printFont, tabWidth: tabWidth, lineNumbers: lineNumbers))
        fitHeight()
    }

    /// As tall as the laid-out text (TextKit 1 paginates the view by height).
    func fitHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + textContainerInset.height * 2
        setFrameSize(NSSize(width: frame.width, height: max(h, 1)))
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // The paper may have changed in the panel: lay out for its width.
        if let info = NSPrintOperation.current?.printInfo {
            let w = info.paperSize.width - info.leftMargin - info.rightMargin
            if w > 50, abs(w - frame.width) > 0.5 {
                setFrameSize(NSSize(width: w, height: frame.height))
                fitHeight()
            }
        }
        return super.knowsPageRange(range)
    }
}

/// The print panel's extra option: line numbers (remembered).
@MainActor
final class PrintOptions: NSViewController, NSPrintPanelAccessorizing {
    static let lineNumbersKey = "printLineNumbers"
    weak var printView: PrintTextView?
    private let box = NSButton(checkboxWithTitle: String(localized: "Print line numbers"), target: nil, action: nil)

    @objc dynamic var lineNumbers = UserDefaults.standard.bool(forKey: PrintOptions.lineNumbersKey) {
        didSet {
            UserDefaults.standard.set(lineNumbers, forKey: Self.lineNumbersKey)
            printView?.lineNumbers = lineNumbers
        }
    }

    override func loadView() {
        box.target = self
        box.action = #selector(toggled(_:))
        box.state = lineNumbers ? .on : .off
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        box.frame = NSRect(x: 20, y: 6, width: 260, height: 20)
        v.addSubview(box)
        view = v
    }

    @objc private func toggled(_ sender: NSButton) { lineNumbers = sender.state == .on }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: String(localized: "Line Numbers"), .itemDescription: lineNumbers ? String(localized: "On") : String(localized: "Off")]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["lineNumbers"] }
}

extension EditorWindowController {
    /// The print operation for this tab's text. `lineNumbers` nil: the
    /// remembered choice.
    func makePrintOperation(lineNumbers: Bool? = nil, info: NSPrintInfo? = nil) -> (NSPrintOperation, PrintTextView, PrintOptions) {
        let info = (info ?? NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter.rawValue] = true
        let width = max(100, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = PrintTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isRichText = false
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.source = text
        view.printFont = Settings.shared.font
        view.tabWidth = tabWidth
        let options = PrintOptions()
        options.printView = view
        if let lineNumbers { options.lineNumbers = lineNumbers }
        view.lineNumbers = options.lineNumbers
        view.reload()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = doc.displayName
        op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        op.printPanel.addAccessoryController(options)
        return (op, view, options)
    }

    func printText() {
        guard let window else { return }
        let (op, _, _) = makePrintOperation()
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

extension AppDelegate {
    @objc func printDocument(_ sender: Any?) { currentTab?.printText() }
    @objc func pageSetup(_ sender: Any?) {
        let layout = NSPageLayout()
        if let w = currentTab?.window ?? currentViewerTab?.window {
            layout.beginSheet(using: NSPrintInfo.shared, on: w, completionHandler: nil)
        } else {
            layout.runModal(with: NSPrintInfo.shared)
        }
    }
}
