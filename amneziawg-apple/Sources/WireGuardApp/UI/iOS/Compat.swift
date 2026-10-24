// SPDX-License-Identifier: MIT
// Fallbacks for UIKit APIs introduced after iOS 12, so the app can run on iOS 12.

import UIKit

extension UIColor {
    static var compatBackground: UIColor {
        if #available(iOS 13.0, *) { return .compatBackground }
        return .white
    }

    static var compatLabel: UIColor {
        if #available(iOS 13.0, *) { return .label }
        return .black
    }

    static var compatSecondaryLabel: UIColor {
        if #available(iOS 13.0, *) { return .compatSecondaryLabel }
        return UIColor(red: 0x3c / 255.0, green: 0x3c / 255.0, blue: 0x43 / 255.0, alpha: 0.6)
    }

    static var compatGray3: UIColor {
        if #available(iOS 13.0, *) { return .compatGray3 }
        return UIColor(red: 0xc7 / 255.0, green: 0xc7 / 255.0, blue: 0xcc / 255.0, alpha: 1)
    }
}

extension UIActivityIndicatorView.Style {
    static var compatMedium: UIActivityIndicatorView.Style {
        if #available(iOS 13.0, *) { return .medium }
        return .gray
    }
}
