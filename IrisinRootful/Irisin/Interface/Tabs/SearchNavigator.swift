//
//  SearchNavigator.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import UIKit

class SearchNavigator: UINavigationController {
    init() {
        super.init(rootViewController: SearchController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(legacyLocalized: "Search"),
            image: UIImage.fluent(.bookSearch24Regular),
            tag: 0
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
