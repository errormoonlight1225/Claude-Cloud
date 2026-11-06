//
//  TabDashboardController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import SPIndicator
import UIKit

class DashboardNavigator: UINavigationController {
    init() {
        super.init(rootViewController: TabDashboardController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(legacyLocalized: "Dashboard"),
            image: UIImage.fluent(.timeline24Regular),
            tag: 0
        )
    }

    /// iOS 12 port: iOS 12's init(rootViewController:) calls this initializer
    /// on the subclass, which a Swift subclass with its own designated
    /// initializer does not inherit: it trapped as unimplemented at launch.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class TabDashboardController: DashboardController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground
        title = String(legacyLocalized: "Dashboard")

        let settings = UIBarButtonItem(
            image: .fluent(.settings24Regular),
            style: .plain,
            target: self,
            action: #selector(rightButtonCall)
        )
        settings.accessibilityLabel = String(legacyLocalized: "Settings")
        navigationItem.rightBarButtonItem = settings

        refreshControl.alpha = 0
    }

    @objc
    func rightButtonCall() {
        let target = SettingsController()
        present(next: target)
    }
}
