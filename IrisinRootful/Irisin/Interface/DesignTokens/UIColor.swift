//
//  UIColor.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import UIKit

extension UIColor {
    /// A dynamic color that follows the interface style. Either side may be
    /// dynamic itself (a system color that follows the level).
    convenience init(light: UIColor, dark: UIColor) {
        if #available(iOS 13.0, *) {
            self.init { ($0.userInterfaceStyle == .dark ? dark : light).compatResolvedColor(with: $0) }
        } else {
            // iOS 12 port: one appearance
            self.init(cgColor: light.cgColor)
        }
    }

    /// An opaque color from a `0xRRGGBB` value.
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
