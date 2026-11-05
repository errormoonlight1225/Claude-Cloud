//
//  AlertProgressIndicatorViewController.swift
//  AlertController
//
//  Created by 秋星桥 on 1/30/25.
//

import LegacyCompat
import Foundation

open class AlertProgressIndicatorViewController: AlertViewController {
    public var progressContext: ProgressContext {
        guard let contentViewController = contentViewController as? AlertProgressIndicatorContentController else {
            preconditionFailure("Expected AlertProgressIndicatorContentController")
        }
        return contentViewController.progressContext
    }

    public convenience init(
        title: LegacyLocalizationValue = "",
        message: LegacyLocalizationValue = ""
    ) {
        let controller = AlertProgressIndicatorContentController(
            title: String(legacyLocalized: title),
            message: String(legacyLocalized: message)
        ) { _ in }
        self.init(contentViewController: controller)
    }

    public required init(contentViewController: PlatformViewController) {
        super.init(contentViewController: contentViewController)
    }
}
