//
//  InstalledNavigator.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import OpenCombine
import OpenCombineDispatch
import OpenCombineFoundation
import UIKit

class InstalledNavigator: UINavigationController {
    private var subscriptions = Set<AnyCancellable>()
    private var updateCountTask: LegacyMainTask?

    init() {
        super.init(rootViewController: InstalledController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(legacyLocalized: "Installed"),
            image: UIImage.fluent(.textChangeAccept24Filled),
            tag: 0
        )
        tabBarItem.badgeColor = .buttonNormal

        NotificationCenter.default.ocombine.publisher(for: PackageCenter.packageRecordChanged)
            .receive(on: DispatchQueue.main.ocombine)
            .sink { [weak self] _ in self?.updateAvailableUpdateBadge() }
            .store(in: &subscriptions)
    }

    func updateAvailableUpdateBadge() {
        updateCountTask?.cancel()
        updateCountTask = LegacyMainTask { [weak self] in
            let index = PackageCenter.default.index
            let count = awaitBackground { Self.updateCount(in: index) }
            guard !LegacyTask.isCancelled, let self else { return }
            setTabBadge(count > 0 ? String(count) : nil)
        }
    }

    /// A walk of the whole installed list, so it runs off the main actor on
    /// a copy of the index.
    private nonisolated static func updateCount(in index: PackageIndex) -> Int {
        index.updateCandidates().count
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
