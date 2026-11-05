//
//  AlertInputViewController.swift
//  AlertController
//
//  Created by 秋星桥 on 1/30/25.
//

import LegacyCompat
import Foundation

open class AlertInputViewController: AlertViewController {
    public convenience init(
        title: LegacyLocalizationValue = "",
        message: LegacyLocalizationValue = "",
        placeholder: LegacyLocalizationValue,
        text: String,
        cancelButtonText: LegacyLocalizationValue = "Cancel",
        doneButtonText: LegacyLocalizationValue = "Done",
        onConfirm: @escaping (String) -> Void
    ) {
        let confirm: (ActionContext) -> Void = { context in
            context.dispose { onConfirm(context.userObject as! String) }
        }
        let controller = AlertInputContentController(
            title: String(legacyLocalized: title),
            message: String(legacyLocalized: message),
            originalText: text,
            placeholder: String(legacyLocalized: placeholder),
            setupActions: { context in
                context.addAction(title: cancelButtonText) {
                    context.dispose()
                }
                context.addAction(title: doneButtonText, attribute: .accent) {
                    confirm(context)
                }
            },
            onSubmit: confirm
        )
        self.init(contentViewController: controller)
    }

    public required init(contentViewController: PlatformViewController) {
        super.init(contentViewController: contentViewController)
    }
}
