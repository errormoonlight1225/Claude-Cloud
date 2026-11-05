//
//  Symbols.swift
//  LegacyCompat
//
//  SF Symbols are iOS 13. On iOS 12 a symbol name maps to a text glyph drawn
//  as a template image, so an icon-only button still shows something that
//  reads as its action. On iOS 13 and later the real symbol is used.
//

#if canImport(UIKit)
    import UIKit

    public enum LegacySymbol {
        /// Glyphs for the symbol names this app uses, matched on the name's
        /// first component when there is no exact entry ("trash.fill" -> "trash").
        static let glyphs: [String: String] = [
            "plus": "+", "minus": "\u{2212}", "xmark": "\u{2715}", "checkmark": "\u{2713}",
            "multiply": "\u{00D7}", "ellipsis": "\u{2026}", "magnifyingglass": "\u{2315}",
            "gear": "\u{2699}\u{FE0E}", "gearshape": "\u{2699}\u{FE0E}", "slider.horizontal.3": "\u{2630}",
            "arrow.clockwise": "\u{21BB}", "arrow.counterclockwise": "\u{21BA}",
            "arrow.triangle.2.circlepath": "\u{21BB}", "arrow.down": "\u{2193}", "arrow.up": "\u{2191}",
            "arrow.left": "\u{2190}", "arrow.right": "\u{2192}", "arrow.down.circle": "\u{2B07}\u{FE0E}",
            "arrow.up.circle": "\u{2B06}\u{FE0E}", "arrow.down.to.line": "\u{2913}",
            "arrow.up.arrow.down": "\u{21C5}", "arrow.uturn.backward": "\u{21A9}\u{FE0E}",
            "arrow.uturn.left": "\u{21A9}\u{FE0E}", "arrow.up.right": "\u{2197}",
            "arrow.up.right.square": "\u{2197}", "arrow.up.forward.app": "\u{2197}",
            "square.and.arrow.up": "\u{21EA}", "square.and.arrow.down": "\u{21E9}",
            "chevron.right": "\u{203A}", "chevron.left": "\u{2039}", "chevron.down": "\u{2304}",
            "chevron.up": "\u{2303}", "trash": "\u{232B}", "doc": "\u{2397}", "doc.on.doc": "\u{2398}",
            "doc.text": "\u{2397}", "folder": "\u{2302}", "house": "\u{2302}", "star": "\u{2605}",
            "heart": "\u{2665}\u{FE0E}", "info": "\u{24D8}", "info.circle": "\u{24D8}",
            "questionmark": "?", "questionmark.circle": "?", "exclamationmark": "!",
            "exclamationmark.triangle": "\u{26A0}\u{FE0E}", "exclamationmark.circle": "!",
            "bell": "\u{237E}", "lock": "\u{1F512}\u{FE0E}", "lock.open": "\u{1F513}\u{FE0E}",
            "link": "\u{1F517}\u{FE0E}", "globe": "\u{1F310}\u{FE0E}", "network": "\u{1F310}\u{FE0E}",
            "safari": "\u{1F310}\u{FE0E}", "person": "\u{263A}\u{FE0E}", "person.crop.circle": "\u{263A}\u{FE0E}",
            "cart": "\u{1F6D2}\u{FE0E}", "creditcard": "\u{25AD}", "tag": "\u{1F3F7}\u{FE0E}",
            "shippingbox": "\u{25A3}", "cube": "\u{25A3}", "cube.box": "\u{25A3}", "archivebox": "\u{25A3}",
            "square.stack.3d.up": "\u{25A4}", "tray": "\u{25AD}", "tray.full": "\u{25A4}",
            "list.bullet": "\u{2630}", "line.3.horizontal": "\u{2630}", "line.3.horizontal.decrease": "\u{2263}",
            "line.horizontal.3.decrease": "\u{2263}", "line.3.horizontal.decrease.circle": "\u{2263}",
            "square.grid.2x2": "\u{229E}", "circle": "\u{25CB}", "circle.fill": "\u{25CF}",
            "checkmark.circle": "\u{2713}", "xmark.circle": "\u{2715}", "plus.circle": "+",
            "minus.circle": "\u{2212}", "pause": "\u{2016}", "play": "\u{25B6}\u{FE0E}",
            "stop": "\u{25A0}", "terminal": ">_", "hammer": "\u{2692}\u{FE0E}", "wrench": "\u{2692}\u{FE0E}",
            "wrench.and.screwdriver": "\u{2692}\u{FE0E}", "pin": "\u{2316}", "pin.slash": "\u{2316}",
            "eye": "\u{25C9}", "eye.slash": "\u{25CE}", "clock": "\u{25F7}", "calendar": "\u{25A6}",
            "bolt": "\u{26A1}\u{FE0E}", "flame": "\u{2668}\u{FE0E}", "sparkles": "\u{2728}\u{FE0E}",
            "paintbrush": "\u{270E}", "pencil": "\u{270E}", "square.and.pencil": "\u{270E}",
            "photo": "\u{25A8}", "text.alignleft": "\u{2630}", "textformat": "Aa",
            "power": "\u{23FB}", "restart": "\u{21BB}", "iphone": "\u{25AF}", "ipad": "\u{25AD}",
            "externaldrive": "\u{25AD}", "server.rack": "\u{2261}", "icloud": "\u{2601}\u{FE0E}",
            "icloud.and.arrow.down": "\u{2601}\u{FE0E}", "wifi": "\u{25E0}", "antenna.radiowaves.left.and.right": "\u{25E0}",
            "envelope": "\u{2709}\u{FE0E}", "bubble.left": "\u{2709}\u{FE0E}", "ladybug": "\u{2741}",
            "ant": "\u{2741}", "book": "\u{25A5}", "books.vertical": "\u{25A5}", "flag": "\u{2691}",
            "hand.raised": "\u{270B}\u{FE0E}", "nosign": "\u{20E0}", "shield": "\u{26E8}",
            "key": "\u{26BF}", "app": "\u{25A2}", "app.badge": "\u{25A2}", "square": "\u{25A1}",
            "square.fill": "\u{25A0}", "rectangle.stack": "\u{25A4}", "sidebar.left": "\u{25A5}",
            "line.3.crossed.swirl.circle": "\u{29BE}", "swift": "\u{25C6}", "ellipsis.circle": "\u{2026}",
        ]

        static func glyph(for name: String) -> String {
            if let glyph = glyphs[name] { return glyph }
            var parts = name.split(separator: ".").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                if let glyph = glyphs[parts.joined(separator: ".")] { return glyph }
            }
            return "\u{2022}"
        }

        private static let cache = NSCache<NSString, UIImage>()

        /// The glyph for `name` as a template image at `pointSize`.
        public static func fallbackImage(named name: String, pointSize: CGFloat = 17, weight: UIFont.Weight = .regular) -> UIImage {
            let cacheKey = "\(name)|\(pointSize)|\(weight.rawValue)" as NSString
            if let image = cache.object(forKey: cacheKey) { return image }
            let text = glyph(for: name) as NSString
            let font = UIFont.systemFont(ofSize: pointSize, weight: weight)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let measured = text.size(withAttributes: attributes)
            let side = ceil(max(measured.width, measured.height, pointSize))
            let size = CGSize(width: side, height: side)
            UIGraphicsBeginImageContextWithOptions(size, false, 0)
            text.draw(
                at: CGPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2),
                withAttributes: attributes
            )
            let drawn = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
            UIGraphicsEndImageContext()
            let image = drawn.withRenderingMode(.alwaysTemplate)
            cache.setObject(image, forKey: cacheKey)
            return image
        }
    }

    /// `UIImage.SymbolConfiguration` for iOS 12: what the drawn glyph can
    /// follow (a size and a weight), and the real configuration on iOS 13.
    public struct LegacySymbolConfiguration {
        public enum Weight {
            case unspecified, ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

            var font: UIFont.Weight {
                switch self {
                case .ultraLight: .ultraLight
                case .thin: .thin
                case .light: .light
                case .medium: .medium
                case .semibold: .semibold
                case .bold: .bold
                case .heavy: .heavy
                case .black: .black
                case .unspecified, .regular: .regular
                }
            }

            @available(iOS 13.0, tvOS 13.0, *)
            var symbol: UIImage.SymbolWeight {
                switch self {
                case .unspecified: .unspecified
                case .ultraLight: .ultraLight
                case .thin: .thin
                case .light: .light
                case .regular: .regular
                case .medium: .medium
                case .semibold: .semibold
                case .bold: .bold
                case .heavy: .heavy
                case .black: .black
                }
            }
        }

        public enum Scale {
            case `default`, unspecified, small, medium, large

            var factor: CGFloat {
                switch self {
                case .small: 0.8
                case .large: 1.25
                default: 1
                }
            }

            @available(iOS 13.0, tvOS 13.0, *)
            var symbol: UIImage.SymbolScale {
                switch self {
                case .default: .default
                case .unspecified: .unspecified
                case .small: .small
                case .medium: .medium
                case .large: .large
                }
            }
        }

        var pointSize: CGFloat?
        var weight: Weight = .unspecified
        var scale: Scale = .default
        var font: UIFont?
        var textStyle: UIFont.TextStyle?

        public init(pointSize: CGFloat, weight: Weight = .regular, scale: Scale = .default) {
            self.pointSize = pointSize
            self.weight = weight
            self.scale = scale
        }

        public init(weight: Weight) { self.weight = weight }
        public init(scale: Scale) { self.scale = scale }
        public init(font: UIFont, scale: Scale = .default) {
            self.font = font
            self.scale = scale
        }

        public init(textStyle: UIFont.TextStyle, scale: Scale = .default) {
            self.textStyle = textStyle
            self.scale = scale
        }

        var resolvedPointSize: CGFloat {
            (font?.pointSize ?? textStyle.map { UIFont.preferredFont(forTextStyle: $0).pointSize } ?? pointSize ?? 17)
                * scale.factor
        }

        @available(iOS 13.0, tvOS 13.0, *)
        public var native: UIImage.SymbolConfiguration {
            if let font { return UIImage.SymbolConfiguration(font: font, scale: scale.symbol) }
            if let textStyle { return UIImage.SymbolConfiguration(textStyle: textStyle, scale: scale.symbol) }
            if let pointSize { return UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight.symbol, scale: scale.symbol) }
            if weight != .unspecified { return UIImage.SymbolConfiguration(weight: weight.symbol) }
            return UIImage.SymbolConfiguration(scale: scale.symbol)
        }
    }

    extension UIImage {
        /// `UIImage(systemName:withConfiguration:)`.
        public static func compatSystemImage(_ name: String, withConfiguration configuration: LegacySymbolConfiguration?) -> UIImage? {
            guard let configuration else { return compatSystemImage(name) }
            if #available(iOS 13.0, tvOS 13.0, *) {
                return UIImage(systemName: name, withConfiguration: configuration.native)
            }
            return LegacySymbol.fallbackImage(
                named: name,
                pointSize: configuration.resolvedPointSize,
                weight: configuration.font.map { _ in configuration.weight.font } ?? configuration.weight.font
            )
        }

        /// `withTintColor(_:renderingMode:)` (iOS 13): a template image on
        /// iOS 12, which the view it is shown in tints.
        public func compatWithTintColor(_ color: UIColor, renderingMode: UIImage.RenderingMode = .automatic) -> UIImage {
            if #available(iOS 13.0, tvOS 13.0, *) { return withTintColor(color, renderingMode: renderingMode) }
            return withRenderingMode(.alwaysTemplate)
        }

        /// `withConfiguration(_:)` (iOS 13); the glyph is drawn once on iOS 12.
        public func compatWithConfiguration(_ configuration: LegacySymbolConfiguration) -> UIImage {
            if #available(iOS 13.0, tvOS 13.0, *) { return withConfiguration(configuration.native) }
            return self
        }
    }

    extension UIImageView {
        /// `preferredSymbolConfiguration` (iOS 13); nothing on iOS 12.
        public var compatPreferredSymbolConfiguration: LegacySymbolConfiguration? {
            get { nil }
            set {
                if #available(iOS 13.0, tvOS 13.0, *) { preferredSymbolConfiguration = newValue?.native }
            }
        }
    }

    extension UIButton {
        /// `setPreferredSymbolConfiguration(_:forImageIn:)` (iOS 13).
        public func compatSetPreferredSymbolConfiguration(_ configuration: LegacySymbolConfiguration?, forImageIn state: UIControl.State) {
            if #available(iOS 13.0, tvOS 13.0, *) { setPreferredSymbolConfiguration(configuration?.native, forImageIn: state) }
        }
    }

    extension UIImage {
        /// `UIImage(systemName:)` on iOS 13 and later, a drawn glyph before.
        public static func compatSystemImage(_ name: String) -> UIImage? {
            if #available(iOS 13.0, tvOS 13.0, *) {
                return UIImage(systemName: name)
            }
            return LegacySymbol.fallbackImage(named: name)
        }

        /// `UIImage(systemName:withConfiguration:)` with a point size and
        /// weight, the only configuration the fallback can follow.
        public static func compatSystemImage(_ name: String, pointSize: CGFloat, weight: UIFont.Weight = .regular) -> UIImage? {
            if #available(iOS 13.0, tvOS 13.0, *) {
                let symbolWeight: UIImage.SymbolWeight = switch weight {
                case .ultraLight: .ultraLight
                case .thin: .thin
                case .light: .light
                case .medium: .medium
                case .semibold: .semibold
                case .bold: .bold
                case .heavy: .heavy
                case .black: .black
                default: .regular
                }
                return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: symbolWeight))
            }
            return LegacySymbol.fallbackImage(named: name, pointSize: pointSize, weight: weight)
        }
    }
#endif
