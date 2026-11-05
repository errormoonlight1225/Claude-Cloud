//
//  AlertViewController+Convenience.swift
//  AlertController
//

import LegacyCompat
import Foundation

public extension AlertViewController {
    convenience init(
        title: LegacyLocalizationValue = "",
        message: LegacyLocalizationValue = "",
        setupActions: @escaping (ActionContext) -> Void
    ) {
        let controller = AlertContentController(
            title: String(legacyLocalized: title),
            message: String(legacyLocalized: message),
            setupActions: setupActions
        )
        self.init(contentViewController: controller)
    }
}
