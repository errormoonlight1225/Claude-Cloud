//
//  InterfaceHostController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import Dog
import UIKit

/// The root container: the split layout on a wide iPad, the tab bar layout
/// everywhere else, swapped as the window is resized. A plain child
/// controller, not a tab bar controller: on iPadOS 18 a tab bar controller
/// puts its bar at the top of the screen and keeps that space even when the
/// bar is hidden.
class InterfaceHostController: UIViewController {
    // iOS 12 port: the tab bar interface on every device; the iPad's split
    // interface stands on iOS 14 column split views and list layouts.
    private var tabs: TabInterfaceController?
    /// The layout on screen right now.
    private(set) var current: UIViewController?

    /// Where a page opened from outside the interface goes: the detail
    /// column on the iPad, the selected tab's stack elsewhere.
    var pageStack: UINavigationController? {
        return (current as? UITabBarController)?.selectedViewController as? UINavigationController
    }

    /// The interface `controller` is in, or is presented over.
    static func enclosing(_ controller: UIViewController) -> InterfaceHostController? {
        var node: UIViewController? = controller
        while let current = node {
            if let interface = current as? InterfaceHostController {
                return interface
            }
            node = current.parent ?? current.presentingViewController
        }
        return nil
    }

    /// Shows the Queue page: whatever sheet is up leaves, then the Queue
    /// card or tab is selected as a tap selects it.
    func openQueue() {
        if presentedViewController != nil {
            dismiss(animated: true)
        }
        (current as? TabInterfaceController)?.showQueue()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The interface is on screen before the engines have loaded, and
        // onboarding asks which repositories are already added.
        LegacyTask.detached {
            guard AppBootstrap.finished() else { return }
            DispatchQueue.main.async {
                // a link that opened the app gets its sheet; onboarding waits
                // for the next time the interface appears
                if WelcomeController.shouldPresent, self.presentedViewController == nil {
                    self.present(WelcomeController.makeLaunchNavigator(), animated: true)
                }
            }
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        installRootIfNeeded()
    }

    override var childForStatusBarStyle: UIViewController? {
        current
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        current
    }

    func installRootIfNeeded() {
        let target: UIViewController
        let controller = tabs ?? TabInterfaceController()
        tabs = controller
        target = controller
        guard target !== current else { return }
        Dog.shared.join(
            "Interface",
            "loading the tab bar interface",
            level: .info
        )

        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(target)
        target.view.frame = view.bounds
        target.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(target.view)
        target.didMove(toParent: self)
        current = target
    }

    var usesSplitLayout: Bool {
        false
    }
}
