import AppKit
import CedricCore

/// One proposed edit in Ask Cedric (0.4.1): the reason, the change as a
/// before/after diff, and Apply / Skip. Apply is enabled only while the
/// proposal applies to the live document (`OwlEditProposal.state`): for a
/// find/replace edit, its text occurs exactly once; never in a read-only
/// document. The panel does the applying (`OwlChatPanel.apply(_:)`).
@MainActor
final class OwlEditCard: NSStackView {
    let proposal: OwlEditProposal
    let titleLabel = NSTextField(labelWithString: "")
    let reasonLabel = NSTextField(wrappingLabelWithString: "")
    let diffView = NSTextView()
    let staleLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var applyButton: NSButton!
    private(set) var skipButton: NSButton!
    private(set) var askAgainButton: NSButton!
    private(set) var state: OwlEditProposal.ApplyState = .stale

    /// "Text changed or isn’t unique; ask again."
    static let staleText = String(localized: "Text changed or isn’t unique; ask again.")
    static let readOnlyText = String(localized: "This document is read-only, so the change can’t be applied.")

    init(_ p: OwlEditProposal, index: Int, of count: Int, target: AnyObject,
         apply: Selector, skip: Selector, askAgain: Selector) {
        proposal = p
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let lines = p.firstLine == p.lastLine
            ? String(localized: "line \(p.firstLine)") : String(localized: "lines \(p.firstLine)–\(p.lastLine)")
        titleLabel.stringValue = count > 1
            ? String(localized: "Change \(index + 1) of \(count), \(lines)")
            : (p.firstLine == p.lastLine ? String(localized: "Proposed change to line \(p.firstLine)")
                : String(localized: "Proposed change to lines \(p.firstLine)–\(p.lastLine)"))
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        reasonLabel.stringValue = p.reason
        reasonLabel.font = .systemFont(ofSize: 11)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.isHidden = p.reason.isEmpty

        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diffView.isVerticallyResizable = true
        diffView.autoresizingMask = [.width]
        diffView.textContainer?.widthTracksTextView = true
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let rows = p.diffLines
        for row in rows {
            let (prefix, bg): (String, NSColor) = row.kind == .removed ? ("- ", NSColor.systemRed.withAlphaComponent(0.18))
                : row.kind == .added ? ("+ ", NSColor.systemGreen.withAlphaComponent(0.18)) : ("  ", .clear)
            out.append(NSAttributedString(string: prefix + row.text + "\n",
                                          attributes: [.font: font, .foregroundColor: NSColor.labelColor, .backgroundColor: bg]))
        }
        diffView.textStorage?.setAttributedString(out)
        // VoiceOver reads the change as words, not as "minus" and "plus" rows.
        diffView.setAccessibilityLabel(String(localized: "Before and after"))
        diffView.setAccessibilityValue(Self.spokenDiff(p))
        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(6, max(1, rows.count))) * 16 + 12).isActive = true

        staleLabel.font = .systemFont(ofSize: 11)
        staleLabel.textColor = .systemOrange
        staleLabel.isHidden = true

        func small(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: target, action: action)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.bezelStyle = .rounded
            return b
        }
        applyButton = small(String(localized: "Apply"), apply)
        skipButton = small(String(localized: "Skip"), skip)
        askAgainButton = small(String(localized: "Ask Again"), askAgain)
        askAgainButton.isHidden = true
        applyButton.setAccessibilityLabel(String(localized: "Apply the change to \(lines)"))
        skipButton.setAccessibilityLabel(String(localized: "Skip the change to \(lines)"))
        let buttons = NSStackView(views: [applyButton, skipButton, askAgainButton])
        buttons.spacing = 6

        for v in [titleLabel, reasonLabel, scroll, staleLabel, buttons] as [NSView] { addArrangedSubview(v) }
        scroll.widthAnchor.constraint(equalTo: widthAnchor, constant: -12).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(p.reason.isEmpty ? titleLabel.stringValue : titleLabel.stringValue + ": " + p.reason)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// "Replace “old” with “new”." (cut short when long), for VoiceOver.
    static func spokenDiff(_ p: OwlEditProposal) -> String {
        func clip(_ s: String) -> String { s.count > 300 ? String(s.prefix(300)) + "…" : s }
        if p.replacement.isEmpty { return String(localized: "Delete “\(clip(p.original))”.") }
        return String(localized: "Replace “\(clip(p.original))” with “\(clip(p.replacement))”.")
    }

    /// Shows where the proposal stands: Apply only when it is `.ready`.
    func show(_ s: OwlEditProposal.ApplyState) {
        state = s
        switch s {
        case .ready:
            applyButton.isEnabled = true
            staleLabel.isHidden = true
            askAgainButton.isHidden = true
        case .stale:
            applyButton.isEnabled = false
            staleLabel.stringValue = Self.staleText
            staleLabel.isHidden = false
            askAgainButton.isHidden = false
        case .readOnly:
            applyButton.isEnabled = false
            staleLabel.stringValue = Self.readOnlyText
            staleLabel.isHidden = false
            askAgainButton.isHidden = true
        }
        setAccessibilityHelp(staleLabel.isHidden ? nil : staleLabel.stringValue)
    }

    var isReady: Bool { if case .ready = state { return true }; return false }
}
