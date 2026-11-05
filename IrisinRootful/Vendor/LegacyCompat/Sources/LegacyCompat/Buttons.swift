//
//  Buttons.swift
//  LegacyCompat
//
//  `UIButton.Configuration` (iOS 15) as far as the app uses it: the filled,
//  tinted and plain styles, drawn with the classic button properties so iOS
//  12 shows the same shapes.
//

#if canImport(UIKit) && os(iOS)
    import UIKit

    public struct LegacyButtonConfiguration {
        public enum Style { case plain, tinted, filled, gray }
        public enum Size { case mini, small, medium, large }
        public enum CornerStyle { case fixed, dynamic, small, medium, large, capsule }

        public struct Background {
            public var cornerRadius: CGFloat = 0
        }

        public var style: Style
        public var title: String?
        public var image: UIImage?
        public var imagePadding: CGFloat = 4
        public var baseForegroundColor: UIColor?
        public var baseBackgroundColor: UIColor?
        public var background = Background()
        public var cornerStyle: CornerStyle = .dynamic
        public var buttonSize: Size = .medium
        public var contentInsets: NSDirectionalEdgeInsets?
        /// The title's font; `titleTextAttributesTransformer` set only this.
        public var font: UIFont?

        public init(style: Style) {
            self.style = style
        }

        public static func plain() -> Self { Self(style: .plain) }
        public static func tinted() -> Self { Self(style: .tinted) }
        public static func filled() -> Self { Self(style: .filled) }
        public static func gray() -> Self { Self(style: .gray) }

        var defaultInsets: NSDirectionalEdgeInsets {
            switch buttonSize {
            case .mini: NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            case .small: NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            case .medium: NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
            case .large: NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
            }
        }

        var defaultFont: UIFont {
            switch buttonSize {
            case .mini: .preferredFont(forTextStyle: .caption2)
            case .small: .preferredFont(forTextStyle: .footnote)
            case .medium, .large: .preferredFont(forTextStyle: .body)
            }
        }

        func cornerRadius(forHeight height: CGFloat) -> CGFloat {
            switch cornerStyle {
            case .fixed: background.cornerRadius
            case .dynamic: buttonSize == .large ? 10 : 6
            case .small: 4
            case .medium: 8
            case .large: 12
            case .capsule: height / 2
            }
        }
    }

    private var configurationKey: UInt8 = 0
    private var boundsObservationKey: UInt8 = 0

    extension UIButton {
        public convenience init(legacyConfiguration: LegacyButtonConfiguration) {
            self.init(type: .system)
            self.legacyConfiguration = legacyConfiguration
        }

        /// Set to restyle the button; the corners follow its height.
        public var legacyConfiguration: LegacyButtonConfiguration? {
            get { objc_getAssociatedObject(self, &configurationKey) as? LegacyButtonConfiguration }
            set {
                objc_setAssociatedObject(self, &configurationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                guard let newValue else { return }
                applyLegacyConfiguration(newValue)
                if objc_getAssociatedObject(self, &boundsObservationKey) == nil {
                    let observation = layer.observe(\.bounds) { [weak self] _, _ in
                        guard let self, let configuration = self.legacyConfiguration else { return }
                        self.layer.cornerRadius = configuration.cornerRadius(forHeight: self.bounds.height)
                    }
                    objc_setAssociatedObject(self, &boundsObservationKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            }
        }

        private func applyLegacyConfiguration(_ configuration: LegacyButtonConfiguration) {
            let accent = configuration.baseBackgroundColor ?? tintColor ?? .systemBlue
            let foreground: UIColor = switch configuration.style {
            case .filled: configuration.baseForegroundColor ?? .white
            case .tinted, .plain, .gray: configuration.baseForegroundColor ?? accent
            }
            switch configuration.style {
            case .filled: backgroundColor = accent
            case .tinted: backgroundColor = (configuration.baseBackgroundColor ?? foreground).withAlphaComponent(0.15)
            case .gray: backgroundColor = UIColor(white: 0.5, alpha: 0.15)
            case .plain: backgroundColor = .clear
            }
            setTitle(configuration.title, for: .normal)
            setTitleColor(foreground, for: .normal)
            setTitleColor(foreground.withAlphaComponent(0.5), for: .highlighted)
            setTitleColor(foreground.withAlphaComponent(0.4), for: .disabled)
            setImage(configuration.image?.withRenderingMode(.alwaysTemplate), for: .normal)
            tintColor = foreground
            titleLabel?.font = configuration.font ?? configuration.defaultFont
            titleLabel?.adjustsFontForContentSizeCategory = configuration.font == nil
            let insets = configuration.contentInsets ?? configuration.defaultInsets
            contentEdgeInsets = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
            let gap = configuration.image != nil && configuration.title != nil ? configuration.imagePadding : 0
            titleEdgeInsets = UIEdgeInsets(top: 0, left: gap, bottom: 0, right: -gap)
            if gap > 0 {
                contentEdgeInsets.right += gap
            }
            layer.cornerRadius = configuration.cornerRadius(forHeight: bounds.height)
            clipsToBounds = configuration.style != .plain
        }
    }
#endif
