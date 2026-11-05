//
//  UIColor+Extension.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2025/1/7.
//

import UIKit

extension UIColor {
    convenience init(light: UIColor, dark: UIColor) {
        // iOS 12 port: dynamic colours are iOS 13; iOS 12 has no dark mode
        if #available(iOS 13.0, *) {
            self.init(dynamicProvider: { $0.userInterfaceStyle == .dark ? dark : light })
        } else {
            self.init(cgColor: light.cgColor)
        }
    }
}

extension UIColor {
    /// An opaque sRGB colour from `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// An opaque colour that follows the appearance.
    convenience init(light: UInt32, dark: UInt32) {
        self.init(light: UIColor(hex: light), dark: UIColor(hex: dark))
    }
}
