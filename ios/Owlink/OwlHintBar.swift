import UIKit
import CedricCore

/// Cedric's hint, as a banner above the status line: the owl, the hint's
/// title and detail, "Fix it" when the hint carries a fix, and a close
/// button. One hint at a time; "Next" when there are more.
final class OwlHintBar: UIView {
    let owl = UIImageView(image: UIImage(named: "Owl"))
    let title = UILabel()
    let detail = UILabel()
    let fix = UIButton(configuration: .borderedProminent())
    let nextButton = UIButton(configuration: .bordered())
    let close = UIButton(type: .close)
    var onFix: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityIdentifier = "owl.hint"

        owl.contentMode = .scaleAspectFit
        owl.widthAnchor.constraint(equalToConstant: 40).isActive = true
        owl.heightAnchor.constraint(equalToConstant: 40).isActive = true
        title.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        title.numberOfLines = 2
        title.accessibilityIdentifier = "owl.hint.title"
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 3
        fix.configuration?.title = String(localized: "Fix it")
        fix.configuration?.buttonSize = .small
        fix.accessibilityIdentifier = "owl.hint.fix"
        nextButton.configuration?.title = String(localized: "Next")
        nextButton.configuration?.buttonSize = .small
        fix.addAction(UIAction { [weak self] _ in self?.onFix?() }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.onNext?() }, for: .primaryActionTriggered)
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        close.accessibilityIdentifier = "owl.hint.close"

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 2
        let buttons = UIStackView(arrangedSubviews: [nextButton, fix])
        buttons.spacing = 8
        let right = UIStackView(arrangedSubviews: [close, buttons])
        right.axis = .vertical
        right.alignment = .trailing
        right.spacing = 6
        let row = UIStackView(arrangedSubviews: [owl, text, right])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ hint: OwlHint, fixTitle: String?, more: Bool) {
        title.text = hint.title
        detail.text = hint.detail
        detail.isHidden = hint.detail?.isEmpty ?? true
        fix.isHidden = fixTitle == nil
        if let fixTitle { fix.configuration?.title = fixTitle }
        nextButton.isHidden = !more
        accessibilityLabel = "Cedric: \(hint.title)"
    }
}

extension UIFont {
    func withWeight(_ w: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: w)
    }
}
