import UIKit

/// The handle between text and Markdown preview on a wide screen: a 44 pt
/// wide touch area over the seam with a visible grabber. Drag to resize
/// (the editor snaps it to the stops), double-tap to put it back on the
/// fold (halves without one). VoiceOver: "Resize preview", adjustable,
/// swipe up or down for the next stop.
final class SplitDivider: UIView {
    static let hitWidth: CGFloat = 44
    private let grabber = UIView()
    /// The seam's x in the superview while dragging, and whether it ended.
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onReset: (() -> Void)?
    /// +1: the preview bigger (VoiceOver increment), -1: smaller.
    var onStep: ((Int) -> Void)?
    var value: (() -> String)?
    private(set) var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.layer.cornerCurve = .continuous
        grabber.isUserInteractionEnabled = false
        addSubview(grabber)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
        let twice = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        twice.numberOfTapsRequired = 2
        addGestureRecognizer(twice)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Resize preview")
        accessibilityHint = String(localized: "Swipe up or down to give the preview more or less room.")
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "editor.splitDivider"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Reset Split")) { [weak self] _ in self?.onReset?(); return true },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = min(44, bounds.height / 3)
        grabber.frame = CGRect(x: bounds.midX - 2.5, y: bounds.midY - h / 2, width: 5, height: h)
    }

    override var accessibilityValue: String? {
        get { value?() }
        set {}
    }

    override func accessibilityIncrement() { onStep?(1) }
    override func accessibilityDecrement() { onStep?(-1) }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        let x = g.location(in: sv).x
        switch g.state {
        case .began:
            isDragging = true
            setGrabberActive(true)
            onDrag?(x, false)
        case .changed:
            onDrag?(x, false)
        case .ended, .cancelled, .failed:
            isDragging = false
            setGrabberActive(false)
            onDrag?(x, true)
        default: break
        }
    }

    @objc private func doubleTapped() { onReset?() }

    private func setGrabberActive(_ on: Bool) {
        let apply = { self.grabber.backgroundColor = on ? .secondaryLabel : .tertiaryLabel }
        if UIAccessibility.isReduceMotionEnabled { apply() } else { UIView.animate(withDuration: 0.15, animations: apply) }
    }
}

extension SplitDivider: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: 28), constrainedAxes: [])
    }
}
