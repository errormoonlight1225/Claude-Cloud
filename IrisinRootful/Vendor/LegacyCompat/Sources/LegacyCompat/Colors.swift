//
//  Colors.swift
//  LegacyCompat
//
//  The iOS 13 semantic colours, with their light-appearance values on iOS 12
//  (which has no dark mode). On iOS 13 and later the system colour is used.
//

#if canImport(UIKit)
    import UIKit

    private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    extension UIColor {
        public static var compatLabel: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .label }
            return .black
        }

        public static var compatSecondaryLabel: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .secondaryLabel }
            return rgba(60, 60, 67, 0.6)
        }

        public static var compatTertiaryLabel: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .tertiaryLabel }
            return rgba(60, 60, 67, 0.3)
        }

        public static var compatQuaternaryLabel: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .quaternaryLabel }
            return rgba(60, 60, 67, 0.18)
        }

        public static var compatPlaceholderText: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .placeholderText }
            return rgba(60, 60, 67, 0.3)
        }

        public static var compatLink: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .link }
            return rgba(0, 122, 255)
        }

        public static var compatSeparator: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .separator }
            return rgba(60, 60, 67, 0.29)
        }

        public static var compatOpaqueSeparator: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .opaqueSeparator }
            return rgba(198, 198, 200)
        }

        public static var compatSystemBackground: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemBackground }
            #endif
            return .white
        }

        public static var compatSecondarySystemBackground: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .secondarySystemBackground }
            #endif
            return rgba(242, 242, 247)
        }

        public static var compatTertiarySystemBackground: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .tertiarySystemBackground }
            #endif
            return .white
        }

        public static var compatSystemGroupedBackground: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemGroupedBackground }
            #endif
            return rgba(242, 242, 247)
        }

        public static var compatSecondarySystemGroupedBackground: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .secondarySystemGroupedBackground }
            #endif
            return .white
        }

        public static var compatTertiarySystemGroupedBackground: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .tertiarySystemGroupedBackground }
            #endif
            return rgba(242, 242, 247)
        }

        public static var compatSystemFill: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemFill }
            #endif
            return rgba(120, 120, 128, 0.2)
        }

        public static var compatSecondarySystemFill: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .secondarySystemFill }
            #endif
            return rgba(120, 120, 128, 0.16)
        }

        public static var compatTertiarySystemFill: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .tertiarySystemFill }
            #endif
            return rgba(118, 118, 128, 0.12)
        }

        public static var compatQuaternarySystemFill: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .quaternarySystemFill }
            #endif
            return rgba(116, 116, 128, 0.08)
        }

        public static var compatSystemGray2: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemGray2 }
            #endif
            return rgba(174, 174, 178)
        }

        public static var compatSystemGray3: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemGray3 }
            #endif
            return rgba(199, 199, 204)
        }

        public static var compatSystemGray4: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemGray4 }
            #endif
            return rgba(209, 209, 214)
        }

        public static var compatSystemGray5: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemGray5 }
            #endif
            return rgba(229, 229, 234)
        }

        public static var compatSystemGray6: UIColor {
            #if os(iOS)
                if #available(iOS 13.0, *) { return .systemGray6 }
            #endif
            return rgba(242, 242, 247)
        }

        public static var compatSystemIndigo: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemIndigo }
            return rgba(88, 86, 214)
        }

        public static var compatSystemTeal: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemTeal }
            return rgba(90, 200, 250)
        }

        public static var compatSystemMint: UIColor {
            if #available(iOS 15.0, tvOS 15.0, *) { return .systemMint }
            return rgba(0, 199, 190)
        }

        public static var compatSystemCyan: UIColor {
            if #available(iOS 15.0, tvOS 15.0, *) { return .systemCyan }
            return rgba(50, 173, 230)
        }

        public static var compatSystemBrown: UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemBrown }
            return rgba(162, 132, 94)
        }

        /// `resolvedColor(with:)` for iOS 12, where every colour is already
        /// resolved.
        public func compatResolvedColor(with traitCollection: UITraitCollection) -> UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return resolvedColor(with: traitCollection) }
            return self
        }

        /// `UIColor(dynamicProvider:)` for iOS 12: the light appearance.
        public static func compatDynamic(_ provider: @escaping (UITraitCollection) -> UIColor) -> UIColor {
            if #available(iOS 13.0, tvOS 13.0, *) { return UIColor(dynamicProvider: provider) }
            return provider(UITraitCollection(traitsFrom: []))
        }
    }

    extension UIBlurEffect.Style {
        /// The iOS 13 materials map to the closest iOS 12 blur.
        public static var compatSystemMaterial: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemMaterial }
            return .extraLight
        }

        public static var compatSystemThinMaterial: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemThinMaterial }
            return .light
        }

        public static var compatSystemUltraThinMaterial: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemUltraThinMaterial }
            return .light
        }

        public static var compatSystemThickMaterial: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemThickMaterial }
            return .extraLight
        }

        public static var compatSystemMaterialDark: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemMaterialDark }
            return .dark
        }

        public static var compatSystemThinMaterialDark: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemThinMaterialDark }
            return .dark
        }

        public static var compatSystemUltraThinMaterialDark: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemUltraThinMaterialDark }
            return .dark
        }

        public static var compatSystemChromeMaterialDark: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemChromeMaterialDark }
            return .dark
        }

        public static var compatSystemThickMaterialDark: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemThickMaterialDark }
            return .dark
        }

        public static var compatSystemChromeMaterial: UIBlurEffect.Style {
            if #available(iOS 13.0, tvOS 13.0, *) { return .systemChromeMaterial }
            return .extraLight
        }
    }

    #if os(iOS)
        extension UIActivityIndicatorView.Style {
            public static var compatMedium: UIActivityIndicatorView.Style {
                if #available(iOS 13.0, *) { return .medium }
                return .gray
            }

            public static var compatLarge: UIActivityIndicatorView.Style {
                if #available(iOS 13.0, *) { return .large }
                return .whiteLarge
            }
        }
    #endif

    extension UIFont {
        /// `monospacedSystemFont(ofSize:weight:)` is iOS 13; Menlo before it.
        public static func compatMonospacedSystemFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
            if #available(iOS 13.0, tvOS 13.0, *) { return .monospacedSystemFont(ofSize: size, weight: weight) }
            let name = weight.rawValue >= UIFont.Weight.semibold.rawValue ? "Menlo-Bold" : "Menlo-Regular"
            return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    extension CALayer {
        /// `cornerCurve = .continuous` where iOS 13 has it; iOS 12 keeps the
        /// circular corner.
        public func compatContinuousCorners() {
            if #available(iOS 13.0, tvOS 13.0, *) { cornerCurve = .continuous }
        }
    }
#endif
