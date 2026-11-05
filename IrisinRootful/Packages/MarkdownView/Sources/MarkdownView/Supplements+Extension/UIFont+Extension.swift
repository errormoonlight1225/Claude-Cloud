//
//  UIFont+Extension.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2025/1/3.
//

import UIKit

public extension UIFont {
    var bold: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    var italic: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitItalic) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    var monospaced: UIFont {
        let settings = [[
            // iOS 12 port: the pre-iOS 15 names of the same keys
            UIFontDescriptor.FeatureKey.featureIdentifier: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.typeIdentifier: kMonospacedNumbersSelector,
        ]]

        let attributes = [UIFontDescriptor.AttributeName.featureSettings: settings]
        let newDescriptor = fontDescriptor.addingAttributes(attributes)
        return UIFont(descriptor: newDescriptor, size: 0)
    }
}
