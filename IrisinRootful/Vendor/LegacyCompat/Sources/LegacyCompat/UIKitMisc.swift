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

        /// `withDesign(.rounded)` (iOS 13): nil on iOS 12.
        public func compatRounded() -> UIFontDescriptor? {
            if #available(iOS 13.0, *) { return withDesign(.rounded) }
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

    extension UITraitCollection {
        /// `hasDifferentColorAppearance(comparedTo:)` (iOS 13): iOS 12 has
        /// one appearance.
        public func compatHasDifferentColorAppearance(comparedTo other: UITraitCollection?) -> Bool {
            if #available(iOS 13.0, *) { return hasDifferentColorAppearance(comparedTo: other) }
            return false
        }
    }

    extension UIBarButtonItem.SystemItem {
        /// `.close` (iOS 13); `.stop`, the same cross, before.
        public static var compatClose: UIBarButtonItem.SystemItem {
            if #available(iOS 13.0, *) { return .close }
            return .stop
        }
    }

    extension UICollectionView {
        /// `isEditing` (iOS 14). On iOS 12 editing is multiple selection.
        public var compatIsEditing: Bool {
            get {
                if #available(iOS 14.0, *) { return isEditing }
                return objc_getAssociatedObject(self, &collectionEditingKey) as? Bool ?? false
            }
            set {
                if #available(iOS 14.0, *) {
                    isEditing = newValue
                    return
                }
                objc_setAssociatedObject(self, &collectionEditingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                if !newValue {
                    indexPathsForSelectedItems?.forEach { deselectItem(at: $0, animated: false) }
                }
                allowsMultipleSelection = newValue
            }
        }

        /// `allowsMultipleSelectionDuringEditing` (iOS 14): what
        /// `compatIsEditing` turns on by itself on iOS 12.
        public var compatAllowsMultipleSelectionDuringEditing: Bool {
            get {
                if #available(iOS 14.0, *) { return allowsMultipleSelectionDuringEditing }
                return true
            }
            set {
                if #available(iOS 14.0, *) { allowsMultipleSelectionDuringEditing = newValue }
            }
        }
    }

    private var collectionEditingKey: UInt8 = 0
    private var keyboardGuideKey: UInt8 = 0

    /// The keyboard's top edge, or the safe area's bottom while it is hidden,
    /// as `keyboardLayoutGuide` (iOS 15) is.
    private final class LegacyKeyboardGuide: UILayoutGuide {
        var overlap: NSLayoutConstraint?
        var observer: NSObjectProtocol?

        deinit {
            observer.map(NotificationCenter.default.removeObserver)
        }

        func attach(to view: UIView) {
            view.addLayoutGuide(self)
            let overlap = topAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
            let pull = topAnchor.constraint(equalTo: view.bottomAnchor)
            pull.priority = .defaultLow
            NSLayoutConstraint.activate([
                leadingAnchor.constraint(equalTo: view.leadingAnchor),
                trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bottomAnchor.constraint(equalTo: view.bottomAnchor),
                topAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
                overlap,
                pull,
            ])
            self.overlap = overlap
            observer = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.update(note)
            }
        }

        private func update(_ note: Notification) {
            guard let view = owningView, let window = view.window,
                  let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            else { return }
            let frame = view.convert(window.convert(end, from: nil), from: window)
            let height = max(0, view.bounds.maxY - frame.minY)
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            overlap?.constant = -height
            UIView.animate(withDuration: duration) { view.layoutIfNeeded() }
        }
    }

    extension UIView {
        /// `keyboardLayoutGuide` (iOS 15); a guide following the keyboard's
        /// frame notifications before.
        public var compatKeyboardLayoutGuide: UILayoutGuide {
            if #available(iOS 15.0, *) { return keyboardLayoutGuide }
            if let guide = objc_getAssociatedObject(self, &keyboardGuideKey) as? LegacyKeyboardGuide {
                return guide
            }
            let guide = LegacyKeyboardGuide()
            guide.attach(to: self)
            objc_setAssociatedObject(self, &keyboardGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return guide
        }
    }
#endif
