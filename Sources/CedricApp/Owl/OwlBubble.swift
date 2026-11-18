import AppKit
import CedricCore

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
    private var actions: [() -> Void] = []
    private var onClose: (() -> Void)?
    private let stack = NSStackView()

    init(hint: OwlHint, buttons specs: [Button], onClose: (() -> Void)?) {
        self.hint = hint
        self.onClose = onClose
        super.init(frame: .zero)
        let title = NSTextField(wrappingLabelWithString: hint.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = Self.maxWidth - 24 - (onClose == nil ? 0 : 16)
        var rows: [NSView] = [title]
        if let d = hint.detail, !d.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: d)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = Self.maxWidth - 24
            rows.append(detail)
        }
        let row = NSStackView()
        row.spacing = 6
        for (i, s) in specs.enumerated() {
            let b = OwlButton(title: s.title, target: self, action: #selector(pressed(_:)))
            b.tag = i
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.bezelStyle = .rounded
            if s.isDefault { b.keyEquivalent = "\r"; b.bezelColor = .controlAccentColor }
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
        let body = NSRect(x: 0.5, y: Self.tail + 0.5, width: bounds.width - 1, height: bounds.height - Self.tail - 1)
        let path = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        // The tail, bottom right, towards the owl.
        let tx = body.maxX - 30
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tx - 9, y: body.minY + 1))
        tail.line(to: NSPoint(x: tx + 6, y: 0.5))
        tail.line(to: NSPoint(x: tx + 4, y: body.minY + 1))
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
    }
}

/// Bubble buttons work on the first click, also in a background window:
/// the bubble is the owl talking to you, not a control that needs focus first.
final class OwlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
