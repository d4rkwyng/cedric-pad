import UIKit
import CedricCore

/// Cedric himself, as on the Mac: the owl sprite (Resources/Owl art) in a
/// corner of the editor, no button chrome. Tap: his bubble (the waiting
/// hint) or Ask Cedric. Drag: pick him up; on release he snaps to the
/// nearest edge or corner (`OwlPlacement`, shared with the Mac). Double
/// tap: back bottom right. Long press: his menu. A count badge and a short
/// pulse when hints arrive (no pulse under Reduce Motion); he fades while
/// the caret is near him. A light rim on dark themes, a faint shadow on
/// light ones. The editor (EditorViewController) owns his frame.
final class OwlSprite: UIView, UIContextMenuInteractionDelegate {
    /// His size: the Mac's is 72; 64 on iOS, well over the 44 pt minimum target.
    static let size: CGFloat = 64

    enum Pose { case idle, talking }

    let image = UIImageView()
    let badge = UILabel()
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onDragBegan: (() -> Void)?
    /// Where he may be dragged (the editor's owl area), in the superview's coordinates.
    var dragArea: () -> CGRect = { .infinite }
    /// Released after a drag, at this frame (superview coordinates).
    var onDragEnded: ((CGRect) -> Void)?
    var menuProvider: (() -> UIMenu)?
    private(set) var isDragging = false
    private(set) var faded = false
    private var dragStart = CGPoint.zero

    var pose: Pose = .idle {
        didSet {
            guard pose != oldValue else { return }
            image.image = UIImage(named: pose == .talking ? "OwlTalking" : "Owl", in: .owlink, with: nil)
        }
    }

    /// The editor behind him is dark: the light rim.
    var onDark = false { didSet { updateRim() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "owl.sprite"
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = OwlBadge.label(0)
        accessibilityHint = String(localized: "Shows Cedric’s hint, or asks Cedric about this document.")

        image.image = UIImage(named: "Owl", in: .owlink, with: nil)
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        badge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = .systemRed
        badge.textAlignment = .center
        badge.layer.cornerRadius = 10
        badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.accessibilityIdentifier = "owl.badge"
        addSubview(badge)
        NSLayoutConstraint.activate([
            // Inset a little so the rim isn't cut off (as on the Mac).
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            image.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: -2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        updateRim()

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        for g in [double, single, pan] { addGestureRecognizer(g) }
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateRim() {
        // The rim follows the sprite's outline (the layer shadow uses its alpha).
        let l = image.layer
        if onDark {
            l.shadowColor = UIColor.white.cgColor
            l.shadowOpacity = 0.75
            l.shadowRadius = 2.5
            l.shadowOffset = .zero
        } else {
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.18
            l.shadowRadius = 2
            l.shadowOffset = CGSize(width: 0, height: 1)
        }
    }

    /// Shows the badge and says it to VoiceOver; pulses if asked.
    func apply(_ state: OwlBadge) {
        badge.isHidden = state.count == 0
        badge.text = state.count > 9 ? "9+" : " \(state.count) "
        accessibilityLabel = state.accessibilityLabel
        if state.pulse { pulse() }
    }

    /// A short double bounce, once. Never under Reduce Motion.
    func pulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.16, 0.97, 1.08, 1]
        a.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        a.duration = 0.8
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "owl.pulse")
    }

    /// Faded while the caret is near him (0.12, as on the Mac).
    func setFaded(_ f: Bool) {
        guard f != faded, !isDragging else { return }
        faded = f
        let alpha: CGFloat = f ? 0.12 : 1
        if UIAccessibility.isReduceMotionEnabled { self.alpha = alpha; return }
        UIView.animate(withDuration: 0.18) { self.alpha = alpha }
    }

    // MARK: Gestures

    @objc private func tapped() { onTap?() }
    @objc private func doubleTapped() { onDoubleTap?() }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began:
            isDragging = true
            dragStart = frame.origin
            faded = false
            alpha = 1
            onDragBegan?()
        case .changed:
            let t = g.translation(in: sv)
            let o = OwlPlacement.clamp(CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y), size: bounds.size, in: dragArea())
            frame.origin = o
        case .ended, .cancelled, .failed:
            isDragging = false
            onDragEnded?(frame)
        default: break
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
