//
//  UIKitMisc.swift
//  LegacyCompat
//
//  Small iOS 13-15 conveniences with an iOS 12 spelling.
//

import Foundation

/// `ListFormatter` (iOS 13): items joined as the locale lists them, with
/// "and" from the app's own strings when it has one.
public enum LegacyListFormatter {
    public static func localizedString(byJoining items: [String]) -> String {
        if #available(iOS 13.0, tvOS 13.0, macOS 10.15, *) {
            return ListFormatter.localizedString(byJoining: items)
        }
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default:
            let and = Bundle.main.localizedString(forKey: "and", value: "and", table: nil)
            return items.dropLast().joined(separator: ", ") + " \(and) " + items[items.count - 1]
        }
    }
}

extension HTTPURLResponse {
    /// `value(forHTTPHeaderField:)` (iOS 13): a case-insensitive lookup.
    public func compatValue(forHTTPHeaderField field: String) -> String? {
        if #available(iOS 13.0, tvOS 13.0, macOS 10.15, *) {
            return value(forHTTPHeaderField: field)
        }
        let wanted = field.lowercased()
        for (key, value) in allHeaderFields {
            if let key = key as? String, key.lowercased() == wanted {
                return value as? String ?? "\(value)"
            }
        }
        return nil
    }
}

#if canImport(UIKit) && os(iOS)
    import UIKit

    extension UITableView.Style {
        /// `.insetGrouped` (iOS 13); `.grouped` before.
        public static var compatInsetGrouped: UITableView.Style {
            if #available(iOS 13.0, *) { return .insetGrouped }
            return .grouped
        }
    }

    extension UISearchBar {
        /// `searchTextField` (iOS 13): the bar's text field, found by key on
        /// iOS 12, where it is private but has always been there.
        public var compatSearchTextField: UITextField {
            if #available(iOS 13.0, *) { return searchTextField }
            if let field = value(forKey: "searchField") as? UITextField { return field }
            return UITextField()
        }
    }

    extension UIFontDescriptor {
        /// `withDesign(_:)` (iOS 13): nil on iOS 12, which has no rounded or
        /// serif system designs.
        public func compatWithDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFontDescriptor? {
            if #available(iOS 13.0, *) { return withDesign(design) }
            return nil
        }
    }


    extension UITraitCollection {
        /// `userInterfaceLevel` (iOS 13): always the base level on iOS 12.
        public var compatIsElevated: Bool {
            if #available(iOS 13.0, *) { return userInterfaceLevel == .elevated }
            return false
        }
    }
#endif
