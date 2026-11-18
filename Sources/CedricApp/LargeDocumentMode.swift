import AppKit
import CedricCore

/// The slim bar above a large document: what was paused and a button to
/// turn it back on.
final class LargeDocumentBar: NSView {
    let label = NSTextField(labelWithString: "")
    let button = NSButton(title: String(localized: "Turn On Anyway"), target: nil, action: nil)
    var onTurnOn: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(turnOn)
        let icon = NSImageView(image: NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, label, spacer, button])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ reason: LargeDocument.Reason) {
        switch reason {
        case .longLine: label.stringValue = String(localized: "Very long lines: colouring, spell check and the owl are paused for speed.")
        case .size: label.stringValue = String(localized: "Large file: colouring, spell check and the owl are paused for speed.")
        }
        button.toolTip = String(localized: "Colour this document and let the owl look at it. Typing may lag.")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds: fill only our part.
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func turnOn() { onTurnOn?() }
}

/// Large mode (LargeDocument in CedricCore): entered when a document is
/// opened, reloaded or restored large, or when an edit makes a line too
/// long; left only when the text is replaced with a document that isn't
/// large (typing a long line shorter again doesn't flicker it off).
extension EditorWindowController {
    /// Large and the user hasn't asked for the extras back: colouring,
    /// spell check and the owl's rules and AI pause.
    var extrasPaused: Bool { (largeReason != nil || largePending) && !largeOverride }

    /// The owl's rules and AI stay off for this tab (unless clicked).
    var owlIdleForSpeed: Bool { extrasPaused }

    func applyLargeMode(_ reason: LargeDocument.Reason?, newText: Bool) {
        let wasPaused = extrasPaused
        let wasChunked = textView.contentStorage?.chunkLimit != nil
        largeReason = reason
        largePending = false
        if newText { largeOverride = false }
        let chunk = reason != nil ? LargeDocument.chunkLength : nil
        textView.contentStorage?.chunkLimit = chunk
        if (chunk != nil) != wasChunked, !newText, let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager {
            // The text stays; TextKit drops its paragraphs and lays out the chunks.
            tlm.invalidateLayout(for: tcm.documentRange)
            textView.needsLayout = true
            textView.needsDisplay = true
        }
        if let reason, extrasPaused { largeBar.show(reason) }
        largeBar.isHidden = !extrasPaused
        colorizer.paused = extrasPaused
        // Spell checking (Spelling.swift) follows extrasPaused.
        spelling.apply()
        if extrasPaused { spelling.stop() }
        if extrasPaused != wasPaused { OwlHub.shared.largeModeChanged(self) }
    }

    /// "Turn On Anyway".
    func turnOnExtras() {
        largeOverride = true
        applyLargeMode(largeReason, newText: false)
        OwlHub.shared.largeModeChanged(self)
        colorizer.recolorAll()
        if owl != nil { OwlHub.shared.activity(in: self) }
    }

    /// After an edit of lines `lines`: a pasted or typed line over the
    /// threshold turns large mode on (once per run loop turn, after
    /// TextKit has finished with the edit).
    func checkLargeAfterEdit(lines: Range<Int>) {
        guard largeReason == nil, !largePending, let reason = LargeDocument.reason(afterEditOf: lines, in: lineIndex) else { return }
        // Paused from now (no sniff, spell check or owl for this edit);
        // TextKit switches to chunks once it's done with the edit.
        largePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.largeReason == nil else { return }
            self.applyLargeMode(reason, newText: false)
        }
    }
}
