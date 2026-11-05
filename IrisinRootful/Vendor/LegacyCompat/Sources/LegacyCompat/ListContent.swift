//
//  ListContent.swift
//  LegacyCompat
//
//  UIListContentConfiguration and UIBackgroundConfiguration are iOS 14. This
//  keeps the configuration's shape (text, secondary text, image, and their
//  properties) and draws it with a content view of its own, added to the
//  cell's or header's content view, so a cell of any style takes it.
//

#if canImport(UIKit) && os(iOS)
    import ObjectiveC
    import UIKit

    public struct LegacyListContentConfiguration {
        public struct TextProperties {
            public var font: UIFont
            public var color: UIColor
            public var numberOfLines: Int = 1
            public var lineBreakMode: NSLineBreakMode = .byTruncatingTail
            public var alignment: NSTextAlignment = .natural
            public var adjustsFontSizeToFitWidth = false
            public var minimumScaleFactor: CGFloat = 0
            public var transform: Transform = .none

            public enum Transform { case none, capitalized, lowercase, uppercase }

            public init(font: UIFont, color: UIColor) {
                self.font = font
                self.color = color
            }
        }

        public struct ImageProperties {
            public var tintColor: UIColor?
            public var maximumSize: CGSize = .zero
            public var reservedLayoutSize: CGSize = .zero
            public var cornerRadius: CGFloat = 0
            public var accessibilityIgnoresInvertColors = false
            public init() {}
        }

        public enum Layout { case stacked, sideBySide }

        public var text: String?
        public var attributedText: NSAttributedString?
        public var secondaryText: String?
        public var secondaryAttributedText: NSAttributedString?
        public var image: UIImage?
        public var textProperties: TextProperties
        public var secondaryTextProperties: TextProperties
        public var imageProperties = ImageProperties()
        public var imageToTextPadding: CGFloat = 12
        public var textToSecondaryTextVerticalPadding: CGFloat = 2
        public var textToSecondaryTextHorizontalPadding: CGFloat = 8
        public var directionalLayoutMargins = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        public var prefersSideBySideTextAndSecondaryText: Bool

        init(text font: UIFont, color: UIColor, secondary secondaryFont: UIFont, secondaryColor: UIColor, sideBySide: Bool) {
            textProperties = TextProperties(font: font, color: color)
            secondaryTextProperties = TextProperties(font: secondaryFont, color: secondaryColor)
            prefersSideBySideTextAndSecondaryText = sideBySide
            secondaryTextProperties.numberOfLines = 0
            textProperties.numberOfLines = 0
        }

        public static func cell() -> Self {
            Self(text: .preferredFont(forTextStyle: .body), color: .compatLabel,
                 secondary: .preferredFont(forTextStyle: .subheadline), secondaryColor: .compatSecondaryLabel, sideBySide: false)
        }

        public static func subtitleCell() -> Self {
            var c = Self(text: .preferredFont(forTextStyle: .body), color: .compatLabel,
                         secondary: .preferredFont(forTextStyle: .footnote), secondaryColor: .compatSecondaryLabel, sideBySide: false)
            c.textToSecondaryTextVerticalPadding = 3
            return c
        }

        public static func valueCell() -> Self {
            var c = Self(text: .preferredFont(forTextStyle: .body), color: .compatLabel,
                         secondary: .preferredFont(forTextStyle: .body), secondaryColor: .compatSecondaryLabel, sideBySide: true)
            c.secondaryTextProperties.numberOfLines = 1
            return c
        }

        public static func groupedHeader() -> Self {
            var c = Self(text: .preferredFont(forTextStyle: .footnote), color: .compatSecondaryLabel,
                         secondary: .preferredFont(forTextStyle: .footnote), secondaryColor: .compatSecondaryLabel, sideBySide: false)
            c.textProperties.transform = .uppercase
            c.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: 6, trailing: 0)
            return c
        }

        public static func plainHeader() -> Self {
            var c = Self(text: .systemFont(ofSize: 17, weight: .semibold), color: .compatLabel,
                         secondary: .preferredFont(forTextStyle: .footnote), secondaryColor: .compatSecondaryLabel, sideBySide: false)
            c.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
            return c
        }

        public static func groupedFooter() -> Self {
            var c = Self(text: .preferredFont(forTextStyle: .footnote), color: .compatSecondaryLabel,
                         secondary: .preferredFont(forTextStyle: .footnote), secondaryColor: .compatSecondaryLabel, sideBySide: false)
            c.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 16, trailing: 0)
            return c
        }

        public static func sidebarHeader() -> Self {
            var c = Self(text: .systemFont(ofSize: 15, weight: .semibold), color: .compatSecondaryLabel,
                         secondary: .preferredFont(forTextStyle: .footnote), secondaryColor: .compatSecondaryLabel, sideBySide: false)
            c.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 4, trailing: 0)
            return c
        }

        public static func sidebarCell() -> Self { cell() }
        public static func accompaniedSidebarCell() -> Self { cell() }
        public static func header() -> Self { groupedHeader() }
        public static func footer() -> Self { groupedFooter() }
    }

    /// Draws a `LegacyListContentConfiguration`.
    public final class LegacyListContentView: UIView {
        private let imageView = UIImageView()
        private let textLabel = UILabel()
        private let secondaryLabel = UILabel()
        private var constraintsInPlace: [NSLayoutConstraint] = []
        private var imageWidth: NSLayoutConstraint?
        private var imageHeight: NSLayoutConstraint?

        public var configuration: LegacyListContentConfiguration {
            didSet { apply() }
        }

        public init(configuration: LegacyListContentConfiguration) {
            self.configuration = configuration
            super.init(frame: .zero)
            for view in [imageView, textLabel, secondaryLabel] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            imageView.contentMode = .scaleAspectFit
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
            secondaryLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            apply()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError() }

        private static func transform(_ text: String?, _ transform: LegacyListContentConfiguration.TextProperties.Transform) -> String? {
            switch transform {
            case .none: text
            case .capitalized: text?.capitalized
            case .lowercase: text?.lowercased()
            case .uppercase: text?.uppercased()
            }
        }

        private static func style(_ label: UILabel, _ p: LegacyListContentConfiguration.TextProperties) {
            label.font = p.font
            label.textColor = p.color
            label.numberOfLines = p.numberOfLines
            label.lineBreakMode = p.lineBreakMode
            label.textAlignment = p.alignment
            label.adjustsFontSizeToFitWidth = p.adjustsFontSizeToFitWidth
            label.minimumScaleFactor = p.minimumScaleFactor
        }

        private func apply() {
            let c = configuration
            Self.style(textLabel, c.textProperties)
            Self.style(secondaryLabel, c.secondaryTextProperties)
            if let attributed = c.attributedText {
                textLabel.attributedText = attributed
            } else {
                textLabel.attributedText = nil
                textLabel.text = Self.transform(c.text, c.textProperties.transform)
            }
            if let attributed = c.secondaryAttributedText {
                secondaryLabel.attributedText = attributed
            } else {
                secondaryLabel.attributedText = nil
                secondaryLabel.text = Self.transform(c.secondaryText, c.secondaryTextProperties.transform)
            }
            imageView.image = c.image
            imageView.tintColor = c.imageProperties.tintColor
            imageView.layer.cornerRadius = c.imageProperties.cornerRadius
            imageView.clipsToBounds = c.imageProperties.cornerRadius > 0
            layout()
        }

        private func layout() {
            NSLayoutConstraint.deactivate(constraintsInPlace)
            let c = configuration
            let margins = c.directionalLayoutMargins
            let hasImage = c.image != nil
            let hasSecondary = (c.secondaryText?.isEmpty == false) || c.secondaryAttributedText != nil
            imageView.isHidden = !hasImage
            secondaryLabel.isHidden = !hasSecondary

            var size = c.imageProperties.maximumSize
            if size == .zero, let image = c.image {
                let side = min(max(image.size.width, image.size.height), c.textProperties.font.lineHeight * 1.2)
                size = CGSize(width: side, height: side)
            }
            let reserved = c.imageProperties.reservedLayoutSize
            let imageBox = CGSize(width: max(size.width, reserved.width), height: max(size.height, reserved.height))

            var list: [NSLayoutConstraint] = []
            let textLeading: NSLayoutXAxisAnchor
            let textLeadingConstant: CGFloat
            if hasImage {
                list += [
                    imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margins.leading),
                    imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: imageBox.width),
                    imageView.heightAnchor.constraint(equalToConstant: imageBox.height),
                    imageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: margins.top),
                ]
                textLeading = imageView.trailingAnchor
                textLeadingConstant = c.imageToTextPadding
            } else {
                textLeading = leadingAnchor
                textLeadingConstant = margins.leading
            }
            list += [
                textLabel.leadingAnchor.constraint(equalTo: textLeading, constant: textLeadingConstant),
                textLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            ]
            if hasSecondary, c.prefersSideBySideTextAndSecondaryText {
                list += [
                    secondaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textLabel.trailingAnchor, constant: c.textToSecondaryTextHorizontalPadding),
                    secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
                    secondaryLabel.firstBaselineAnchor.constraint(equalTo: textLabel.firstBaselineAnchor),
                    textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margins.bottom),
                ]
                textLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
            } else if hasSecondary {
                list += [
                    textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margins.trailing),
                    secondaryLabel.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
                    secondaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margins.trailing),
                    secondaryLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: c.textToSecondaryTextVerticalPadding),
                    secondaryLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margins.bottom),
                ]
            } else {
                list += [
                    textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margins.trailing),
                    textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margins.bottom),
                ]
            }
            if hasImage {
                list.append(imageView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -margins.bottom))
            }
            NSLayoutConstraint.activate(list)
            constraintsInPlace = list
        }
    }

    /// UIBackgroundConfiguration's colour and corners.
    public struct LegacyBackgroundConfiguration {
        public var backgroundColor: UIColor?
        public var cornerRadius: CGFloat = 0
        public var strokeColor: UIColor?
        public var strokeWidth: CGFloat = 0
        public var backgroundInsets = NSDirectionalEdgeInsets.zero

        public init() {}

        public static func listGroupedCell() -> Self {
            var c = Self()
            c.backgroundColor = .compatSecondarySystemGroupedBackground
            return c
        }

        public static func listPlainCell() -> Self {
            var c = Self()
            c.backgroundColor = .compatSystemBackground
            return c
        }

        public static func clear() -> Self {
            var c = Self()
            c.backgroundColor = .clear
            return c
        }

        func makeView() -> UIView {
            let view = UIView()
            view.backgroundColor = backgroundColor
            view.layer.cornerRadius = cornerRadius
            view.layer.borderColor = strokeColor?.cgColor
            view.layer.borderWidth = strokeWidth
            return view
        }
    }

    private var contentViewKey: UInt8 = 0

    /// Where a configuration is drawn: a cell's or header's content view.
    private func legacyContentHost(_ host: UIView) -> LegacyListContentView? {
        objc_getAssociatedObject(host, &contentViewKey) as? LegacyListContentView
    }

    private func legacySetContent(_ configuration: LegacyListContentConfiguration?, in host: UIView, margins: Bool) {
        if let configuration {
            if let view = legacyContentHost(host) {
                view.configuration = configuration
                return
            }
            let view = LegacyListContentView(configuration: configuration)
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            let guide = margins ? host.layoutMarginsGuide : nil
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: guide?.leadingAnchor ?? host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: guide?.trailingAnchor ?? host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            objc_setAssociatedObject(host, &contentViewKey, view, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else if let view = legacyContentHost(host) {
            view.removeFromSuperview()
            objc_setAssociatedObject(host, &contentViewKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    extension UITableViewCell {
        public func legacyDefaultContentConfiguration() -> LegacyListContentConfiguration {
            .cell()
        }

        /// `contentConfiguration` for a list configuration; nil removes it.
        public var legacyContentConfiguration: LegacyListContentConfiguration? {
            get { legacyContentHost(contentView)?.configuration }
            set { legacySetContent(newValue, in: contentView, margins: true) }
        }

        public var legacyBackgroundConfiguration: LegacyBackgroundConfiguration? {
            get { nil }
            set {
                backgroundView = newValue?.makeView()
                if newValue != nil { backgroundColor = .clear }
            }
        }
    }

    extension UITableViewHeaderFooterView {
        public func legacyDefaultContentConfiguration() -> LegacyListContentConfiguration {
            .groupedHeader()
        }

        public var legacyContentConfiguration: LegacyListContentConfiguration? {
            get { legacyContentHost(contentView)?.configuration }
            set { legacySetContent(newValue, in: contentView, margins: true) }
        }

        public var legacyBackgroundConfiguration: LegacyBackgroundConfiguration? {
            get { nil }
            set { backgroundView = newValue?.makeView() }
        }
    }

    extension UICollectionViewCell {
        public func legacyDefaultContentConfiguration() -> LegacyListContentConfiguration {
            .cell()
        }

        public var legacyContentConfiguration: LegacyListContentConfiguration? {
            get { legacyContentHost(contentView)?.configuration }
            set { legacySetContent(newValue, in: contentView, margins: true) }
        }

        public var legacyBackgroundConfiguration: LegacyBackgroundConfiguration? {
            get { nil }
            set { backgroundView = newValue?.makeView() }
        }
    }
#endif
