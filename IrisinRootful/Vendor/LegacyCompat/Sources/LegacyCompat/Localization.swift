//
//  Localization.swift
//  LegacyCompat
//
//  `String(localized:)` and `String.LocalizationValue` are iOS 15. The string
//  catalogs (.xcstrings) still compile to .strings and .stringsdict files that
//  iOS 12 reads, keyed the way LocalizationValue spells a key: each
//  interpolation becomes a format specifier ("%@", "%lld", ...). This builds
//  the same key, looks it up with NSLocalizedString's machinery and formats
//  the arguments, plural rules included.
//

import Foundation

public struct LegacyLocalizationValue: ExpressibleByStringInterpolation, Hashable, CustomStringConvertible {
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [CVarArg] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + interpolationCount * 3)
        }

        public mutating func appendLiteral(_ literal: String) {
            // A literal percent sign is doubled in a format key.
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation(_ value: String) {
            key += "%@"
            arguments.append(value as NSString)
        }

        public mutating func appendInterpolation(_ value: Substring) {
            appendInterpolation(String(value))
        }

        public mutating func appendInterpolation<T: BinaryInteger & SignedInteger>(_ value: T) {
            key += "%lld"
            arguments.append(Int64(value))
        }

        public mutating func appendInterpolation<T: BinaryInteger & UnsignedInteger>(_ value: T) {
            key += "%llu"
            arguments.append(UInt64(value))
        }

        public mutating func appendInterpolation(_ value: Double) {
            key += "%lf"
            arguments.append(value)
        }

        public mutating func appendInterpolation(_ value: Float) {
            key += "%f"
            arguments.append(Double(value))
        }

        public mutating func appendInterpolation(_ value: CGFloat) {
            key += "%lf"
            arguments.append(Double(value))
        }

        public mutating func appendInterpolation(_ value: LegacyLocalizationValue) {
            // Already localized text, inserted as an argument.
            key += "%@"
            arguments.append(value.resolve(table: nil, bundle: .main, locale: nil) as NSString)
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value) as NSString)
        }
    }

    public let key: String
    let arguments: [CVarArg]

    public init(_ key: String) {
        self.key = key
        arguments = []
    }

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public var description: String {
        resolve(table: nil, bundle: .main, locale: nil)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.arguments.map { "\($0)" } == rhs.arguments.map { "\($0)" }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(arguments.count)
    }

    public func resolve(table: String?, bundle: Bundle, locale: Locale?) -> String {
        // An interpolated key holds "%%" for a literal percent sign; a plain
        // literal was never a format, so look it up as written.
        let lookupKey = arguments.isEmpty ? key.replacingOccurrences(of: "%%", with: "%") : key
        let format = bundle.localizedString(forKey: lookupKey, value: lookupKey, table: table)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale ?? .current, arguments: arguments)
    }
}

extension String {
    /// `String(localized:table:bundle:locale:comment:)` for iOS 12.
    public init(
        legacyLocalized value: LegacyLocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil,
        locale: Locale? = nil,
        comment _: StaticString? = nil
    ) {
        self = value.resolve(table: table, bundle: bundle ?? .main, locale: locale)
    }

    /// The `defaultValue:` form: the key is looked up, the value is used when
    /// no table has it.
    public init(
        legacyLocalized key: StaticString,
        defaultValue: LegacyLocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil,
        locale: Locale? = nil,
        comment _: StaticString? = nil
    ) {
        let bundle = bundle ?? .main
        let keyString = "\(key)"
        let missing = "\u{0}LegacyCompat.missing"
        let found = bundle.localizedString(forKey: keyString, value: missing, table: table)
        if found == missing {
            self = defaultValue.resolve(table: table, bundle: bundle, locale: locale)
        } else if defaultValue.arguments.isEmpty {
            self = found
        } else {
            self = String(format: found, locale: locale ?? .current, arguments: defaultValue.arguments)
        }
    }
}
