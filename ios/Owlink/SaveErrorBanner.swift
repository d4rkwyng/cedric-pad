import UIKit

/// A save failed: a strip at the top of the editor that stays until a
/// save succeeds. It doesn't block typing (the text stays, unsaved), and
/// it can carry one action (Save as UTF-8 for characters the file's
/// encoding can't hold).
final class SaveErrorBanner: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemYellow.withAlphaComponent(0.92)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemOrange.cgColor
        accessibilityIdentifier = "editor.saveError"
        icon.tintColor = .black
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .black
        label.numberOfLines = 0
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
        button.setTitleColor(.black, for: .normal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        button.accessibilityIdentifier = "editor.saveError.action"
        let row = UIStackView(arrangedSubviews: [icon, label, button])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    var message: String? { label.text }

    func show(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        label.text = text
        button.setTitle(actionTitle, for: .normal)
        button.isHidden = actionTitle == nil
        self.action = action
        if isHidden {
            isHidden = false
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    func hide() {
        isHidden = true
        action = nil
    }
}

private extension UIFont {
    func withTraits(_ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(t).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
