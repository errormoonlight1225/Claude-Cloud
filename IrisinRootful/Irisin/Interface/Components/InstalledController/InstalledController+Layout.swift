//
//  InstalledController+Layout.swift
//  Irisin
//

import LegacyCompat
import AptRepository
import UIKit

extension InstalledController {
    /// The dashboard's edge: icons and date headers start 20 in.
    static let horizontalInset: CGFloat = 20
    /// The gap between two rows, the flow layout's own before this one.
    static let rowSpacing: CGFloat = 10

    /// One column is a list, whose rows swipe; a width that fits more is
    /// the grid every package page lays out, where a long press has the
    /// same actions. The count is the layout's own footer, after the last
    /// section whichever that is, as tall as its lines: a search adds one.
    ///
    /// iOS 12 port: LegacySectionLayout (compositional layouts are iOS 13,
    /// list sections iOS 14); the list's rows swipe through the grid's own
    /// swipe interaction.
    func makeLayout() -> UICollectionViewLayout {
        LegacySectionLayout { [weak self] index, width in
            self?.makeSection(at: index, width: width)
        }
    }

    private func makeSection(at index: Int, width containerWidth: CGFloat) -> LegacyLayoutSection {
        let width = containerWidth - Self.horizontalInset * 2
        let (cellSize, itemsPerRow) = PackageListRow.layout(inWidth: width)
        let rowHeight = InstalledPackageCell.rowHeight
        laysOutGrid = itemsPerRow > 1
        let isLast = index == collectionView.numberOfSections - 1
        return LegacyLayoutSection(
            items: itemsPerRow < 2 ? .rows(.absolute(rowHeight)) : .grid(CGSize(width: cellSize.width, height: rowHeight)),
            insets: UIEdgeInsets(
                top: 0,
                left: Self.horizontalInset,
                // the next date stands off these rows as far as they stand
                // off each other; after the last of them comes the footer
                bottom: showsHeaders && index < dataSource.count - 1 ? Self.rowSpacing : 0,
                right: Self.horizontalInset
            ),
            lineSpacing: Self.rowSpacing,
            // the date is measured from the page's edge and starts where the
            // rows do
            header: showsHeaders ? .absolute(20) : nil,
            // the count, after the last section
            footer: isLast ? .estimated(ListFootnoteView.height) : nil,
            supplementariesIgnoreInsets: false
        )
    }

    // MARK: - SWIPE

    /// Remove, and Update or Reinstall when a repository has the version:
    /// the package menu's own actions, run as the menu runs them. A queued
    /// package leaves the queue instead, as its page would have it.
    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isEditing, let row = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        let (package, actions) = PackageMenu.swipeActions(forInstalled: row)
        return PackageMenu.swipeConfiguration(for: package, actions: actions, from: self) { [weak self] in
            self?.collectionView.cellForItem(at: indexPath).map { PopoverAnchor($0) }
        }
    }

    /// The same swipe in a grid, where the list's is not drawn.
    /// iOS 12 port: the list's swipe as well, which a list section drew.
    func gridSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        swipeActions(at: indexPath)
    }

    // MARK: - TEXT SIZE

    /// A row is as tall as its text: a new text size is a new layout, for
    /// the grid too, whose rows are a number the layout was given.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }
}
