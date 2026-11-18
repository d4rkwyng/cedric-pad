import AppKit
import CedricCore
import CedricAI

/// The speech bubble beside the owl: title, optional detail, and buttons.
/// The tail at the bottom right points at the owl.
@MainActor
final class OwlBubble: NSView {
    struct Button {
        let title: String
        let isDefault: Bool
        let action: () -> Void
    }

    static let tail: CGFloat = 10
    static let maxWidth: CGFloat = 290

    let hint: OwlHint
    private(set) var buttons: [NSButton] = []
    private(set) var closeButton: NSButton?
    /// The hint's source line, if it has one (AI hints).
    private(set) var sourceLabel: NSTextField?
    /// Model names for local hints, read once.
    static let catalog: ModelCatalog? = ModelCatalog.bundled()
    private var actions: [() -> Void] = []
    private var onClose: (() -> Void)?
    private let stack = NSStackView()
    /// The tail is on the side towards the owl: top when the bubble is
    /// below him, left when it extends to his right.
    var tailOnTop = false { didSet { if oldValue != tailOnTop { updateInsets(); needsDisplay = true } } }
    var tailAtLeft = false { didSet { if oldValue != tailAtLeft { needsDisplay = true } } }

    private func updateInsets() {
        stack.edgeInsets.top = 10 + (tailOnTop ? Self.tail : 0)
        stack.edgeInsets.bottom = 10 + (tailOnTop ? 0 : Self.tail)
    }

    init(hint: OwlHint, buttons specs: [Button], onClose: (() -> Void)?) {
        self.hint = hint
        self.onClose = onClose
        super.init(frame: .zero)
        let title = NSTextField(wrappingLabelWithString: hint.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = Self.maxWidth - 12 - (onClose == nil ? 12 : 34)
        var rows: [NSView] = [title]
        // Where it came from, quietly: "AI suggestion · Apple Intelligence".
        // The owl's own rules need no label.
        if let src = HintSource.displayName(hint.source, catalog: Self.catalog) {
            let label = NSTextField(labelWithString: src)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            sourceLabel = label
            rows.append(label)
        }
        if let d = hint.detail, !d.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: d)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = Self.maxWidth - 24
            rows.append(detail)
        }
        // Buttons in one row, or more when they wouldn't fit the bubble's width.
        let room = Self.maxWidth - 12 - (onClose == nil ? 12 : 28)
        var row = NSStackView()
        row.spacing = 6
        var used: CGFloat = 0
        for (i, s) in specs.enumerated() {
            let b = OwlButton(title: s.title, target: self, action: #selector(pressed(_:)))
            b.tag = i
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.bezelStyle = .rounded
            if s.isDefault { b.keyEquivalent = "\r"; b.bezelColor = .controlAccentColor }
            let w = b.fittingSize.width
            if !row.arrangedSubviews.isEmpty, used + 6 + w > room {
                rows.append(row)
                row = NSStackView()
                row.spacing = 6
                used = 0
            }
            used += (row.arrangedSubviews.isEmpty ? 0 : 6) + w
            row.addArrangedSubview(b)
            buttons.append(b)
            actions.append(s.action)
        }
        rows.append(row)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10 + Self.tail, right: 12)
        rows.forEach(stack.addArrangedSubview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
        ])
        if onClose != nil {
            let x = OwlButton(title: "✕", target: self, action: #selector(close))
            x.isBordered = false
            x.font = .systemFont(ofSize: 11)
            x.contentTintColor = .secondaryLabelColor
            x.toolTip = String(localized: "Dismiss")
            x.setAccessibilityLabel(String(localized: "Dismiss"))
            x.translatesAutoresizingMaskIntoConstraints = false
            addSubview(x)
            NSLayoutConstraint.activate([
                x.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                x.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ])
            closeButton = x
            stack.edgeInsets.right = 28
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(hint.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    @objc private func pressed(_ sender: NSButton) { OwlCheck.clicked = true; actions[sender.tag]() }
    @objc private func close() { onClose?() }

    /// Its size for the current text.
    func fit() -> NSSize {
        layoutSubtreeIfNeeded()
        let s = fittingSize
        return NSSize(width: min(Self.maxWidth, max(180, s.width)), height: s.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Self.tail
        let body = NSRect(x: 0.5, y: (tailOnTop ? 0 : t) + 0.5, width: bounds.width - 1, height: bounds.height - t - 1)
        let path = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        // The tail, towards the owl.
        let tx = tailAtLeft ? body.minX + 30 : body.maxX - 30
        let lean: CGFloat = tailAtLeft ? -1 : 1
        let base = tailOnTop ? body.maxY - 1 : body.minY + 1
        let tip = tailOnTop ? bounds.height - 0.5 : 0.5
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tx - 9 * lean, y: base))
        tail.line(to: NSPoint(x: tx + 6 * lean, y: tip))
        tail.line(to: NSPoint(x: tx + 4 * lean, y: base))
        tail.close()
        path.append(tail)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10).stroke()
        // The tail's two outer edges, so it reads on dark editors too.
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: tx - 9 * lean, y: base))
        edge.line(to: NSPoint(x: tx + 6 * lean, y: tip))
        edge.line(to: NSPoint(x: tx + 4 * lean, y: base))
        edge.lineWidth = 1
        edge.stroke()
        // Open the body's border where the tail joins it.
        NSColor.controlBackgroundColor.setStroke()
        let gap = NSBezierPath()
        gap.move(to: NSPoint(x: min(tx - 9 * lean, tx + 4 * lean) + 1, y: tailOnTop ? body.maxY : body.minY))
        gap.line(to: NSPoint(x: max(tx - 9 * lean, tx + 4 * lean) - 1, y: tailOnTop ? body.maxY : body.minY))
        gap.lineWidth = 1.5
        gap.stroke()
    }
}

/// Bubble buttons work on the first click, also in a background window:
/// the bubble is the owl talking to you, not a control that needs focus first.
final class OwlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
