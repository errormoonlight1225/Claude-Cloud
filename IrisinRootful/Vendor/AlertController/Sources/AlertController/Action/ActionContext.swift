//
//  ActionContext.swift
//  AlertController
//
//  Created by 秋星桥 on 2/22/25.
//

import LegacyCompat
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

open class ActionContext {
    public typealias ActionBlock = () -> Void
    public typealias DismissBlock = () -> Void
    public typealias DismissHandler = (@escaping DismissBlock) -> Void

    var actions = [Action]()
    var dismissHandler: DismissHandler?
    var userObject: Any?

    /// Set to true when the caller explicitly
    /// opts in to simple ESC dismissal via
    /// `allowSimpleDispose()`.
    var simpleDisposeRequested = false

    private var disposeRequested = false

    init() {}

    #if canImport(UIKit)
        func bind(to viewController: UIViewController) {
            dismissHandler = { [weak viewController, weak self] completionBlock in
                guard let viewController, viewController.presentingViewController != nil else {
                    self?.dismissHandler = nil
                    completionBlock()
                    return
                }
                if let coordinator = viewController.transitionCoordinator {
                    // UIKit drops a dismiss requested while a transition is
                    // running, so retry once the current transition finishes.
                    coordinator.animate(alongsideTransition: nil) { _ in
                        DispatchQueue.main.async {
                            guard let handler = self?.dismissHandler else {
                                completionBlock()
                                return
                            }
                            handler(completionBlock)
                        }
                    }
                    return
                }
                self?.dismissHandler = nil
                viewController.dismiss(animated: true) {
                    completionBlock()
                }
            }
        }
    #elseif canImport(AppKit)
        func bind(to viewController: NSViewController) {
            dismissHandler = { [weak viewController, weak self] completionBlock in
                guard let viewController, let presenter = viewController.presentingViewController else {
                    self?.dismissHandler = nil
                    completionBlock()
                    return
                }
                self?.dismissHandler = nil
                guard let alertController = viewController as? AlertBaseController else {
                    presenter.dismiss(viewController)
                    completionBlock()
                    return
                }
                // The alert defers a dismissal requested while it is still
                // animating in, so no retry is needed here.
                alertController.dismiss(animated: true, completion: completionBlock)
            }
        }
    #endif

    /// Releases the action blocks and the dismiss handler once the alert
    /// is gone, breaking the cycles formed by blocks that capture the context.
    func releaseAfterDismissal() {
        actions.removeAll()
        dismissHandler = nil
    }

    open func addAction(
        title: LegacyLocalizationValue,
        attribute: Action.Attribute = .normal,
        block: @escaping ActionBlock
    ) {
        actions.append(.init(
            title: Self.localizedString(title),
            attribute: attribute,
            block: block
        ))
    }

    open func dispose(_ completion: @escaping () -> Void = {}) {
        guard !disposeRequested else { return }
        disposeRequested = true
        #if canImport(UIKit)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        #endif
        let completionBlock: DismissBlock = {
            // iOS 12 port: the completion runs on the next main-queue turn,
            // where the Task hop used to put it.
            DispatchQueue.main.async {
                completion()
            }
        }
        guard let dismissHandler else {
            // Already dismissed (for example by tap-around or Escape).
            completionBlock()
            return
        }
        dismissHandler(completionBlock)
    }

    /// Resolves against the host app first, then falls back to the
    /// package's own translations (e.g. the default "Cancel" / "Done").
    static func localizedString(_ value: LegacyLocalizationValue) -> String {
        let localized = String(legacyLocalized: value)
        let unlocalized = String(
            legacyLocalized: value,
            table: "AlertControllerMissingTable",
            bundle: .main
        )
        guard localized == unlocalized else { return localized }
        return String(legacyLocalized: value, bundle: AlertControllerConfiguration.module)
    }
}

public extension ActionContext {
    struct Action {
        let title: String
        let attribute: Attribute
        let block: ActionBlock
    }
}

public extension ActionContext.Action {
    enum Attribute: Equatable {
        case normal
        case accent
    }
}

public extension ActionContext {
    func allowSimpleDispose() {
        simpleDisposeRequested = true
    }
}
