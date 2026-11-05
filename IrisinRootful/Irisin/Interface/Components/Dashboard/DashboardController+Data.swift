//
//  DashboardController+Data.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import SPIndicator
import UIKit

extension DashboardController {
    @objc
    func refresh() {
        LegacyTask.detached {
            reload(animated: true)
            refreshControl.endRefreshing()
            SPIndicator.present(
                title: String(legacyLocalized: "Refreshed"),
                message: nil,
                preset: .done,
                haptic: .success,
                from: .top,
                completion: nil
            )
        }
    }

    nonisolated func reload(
        animated: Bool,
        load: @Sendable () -> [DashboardController.Section] = DashboardController.sections
    ) {
        let requestID = UUID()
        reloadID = requestID
        let sections = load()
        guard reloadID == requestID, !LegacyTask.isCancelled else { return }
        dataSource = sections
        applySnapshot(
            animatingDifferences: animated && collectionView.shouldAnimateDiff
        )
        hasShownSections = true
    }

    func applySnapshot(animatingDifferences: Bool) {
        var snapshot = LegacyDiffableSnapshot<String, Item>()
        for section in dataSource where !snapshot.sectionIdentifiers.contains(section.title) {
            snapshot.appendSections([section.title])
            var items = section.packages.uniqued().map { Item.package(section: section.title, $0) }
            if section.shouldLimit {
                items = Array(items.prefix(cellLimit))
            }
            snapshot.appendItems(items, toSection: section.title)
        }
        snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
        // an open swipe belongs to a cell, which the diff may move
        gridSwipe.close(animated: false)
        diffableDataSource.apply(snapshot, animatingDifferences: animatingDifferences)
        if snapshot.numberOfItems == 0 {
            emptyStateLabel.text = RepositoryCenter.default.obtainRepositoryCount() == 0
                ? String(legacyLocalized: "Add a repository to get started.")
                : String(legacyLocalized: "Nothing to show yet. Refresh your repositories.")
            collectionView.backgroundView = emptyStateLabel
        } else {
            collectionView.backgroundView = nil
        }
    }

    func section(at index: Int) -> DashboardController.Section? {
        guard let title = diffableDataSource.sectionIdentifier(for: index) else { return nil }
        return dataSource.first { $0.title == title }
    }
}
