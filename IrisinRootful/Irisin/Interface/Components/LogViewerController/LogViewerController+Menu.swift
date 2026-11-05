//
//  LogViewerController+Menu.swift
//  Irisin
//

import LegacyCompat
import Dog
import UIKit

extension LogViewerController {
    func setupNavigationItems() {
        let menuButton = UIButton(type: .system)
        menuButton.setImage(UIImage.compatSystemImage("ellipsis"), for: .normal)
        menuButton.tintColor = .textTitle
        // the bar item is only a wrapper; the button is what a reader lands on
        menuButton.accessibilityLabel = String(legacyLocalized: "More")
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = LegacyMenu(children: [
            LegacyDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.createMenu().children ?? [])
            },
        ])
        menuButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: menuButton)
    }

    private func createMenu() -> LegacyMenu {
        let levelActions = [Dog.DogLevel.verbose, .info, .warning, .error, .critical].map { level in
            LegacyAction(
                title: level.rawValue,
                image: selectedLevels.contains(level) ? UIImage.compatSystemImage("checkmark") : nil,
                handler: { [weak self] _ in
                    self?.toggleLevel(level)
                }
            )
        }
        let levelMenu = LegacyMenu(
            title: String(legacyLocalized: "Filter by Level"),
            image: UIImage.compatSystemImage("slider.horizontal.3"),
            children: levelActions
        )

        var categoryActions: [LegacyAction] = []
        let categories = allCategories
        if !categories.isEmpty {
            categoryActions.append(LegacyAction(
                title: String(legacyLocalized: "All Categories"),
                image: selectedCategories.isEmpty ? UIImage.compatSystemImage("checkmark") : nil,
                handler: { [weak self] _ in
                    self?.selectedCategories.removeAll()
                    self?.applyFilters(stickToBottom: false)
                }
            ))
            categoryActions.append(contentsOf: categories.sorted().map { category in
                LegacyAction(
                    title: category,
                    image: selectedCategories.contains(category) ? UIImage.compatSystemImage("checkmark") : nil,
                    handler: { [weak self] _ in
                        self?.toggleCategory(category)
                    }
                )
            })
        }
        let emptyCategories = [LegacyAction(title: String(legacyLocalized: "No Categories"), handler: { _ in })]
        let categoryMenu = LegacyMenu(
            title: String(legacyLocalized: "Filter by Category"),
            image: UIImage.compatSystemImage("tag"),
            children: categoryActions.isEmpty ? emptyCategories : categoryActions
        )

        let onlyFailuresAction = LegacyAction(
            title: String(legacyLocalized: "Errors Only"),
            image: UIImage.compatSystemImage("exclamationmark.triangle"),
            state: selectedLevels == [.error, .critical] ? .on : .off,
            handler: { [weak self] _ in
                guard let self else { return }
                selectedLevels = selectedLevels == [.error, .critical]
                    ? [.verbose, .info, .warning, .error, .critical]
                    : [.error, .critical]
                applyFilters(stickToBottom: false)
            }
        )

        let shareAction = LegacyAction(
            title: String(legacyLocalized: "Share"),
            image: UIImage.compatSystemImage("square.and.arrow.up"),
            handler: { [weak self] _ in
                self?.shareLog()
            }
        )

        let clearAction = LegacyAction(
            title: String(legacyLocalized: "Clear"),
            image: UIImage.compatSystemImage("trash"),
            attributes: .destructive,
            handler: { [weak self] _ in
                self?.clearLog()
            }
        )

        return LegacyMenu(children: [
            levelMenu,
            categoryMenu,
            LegacyMenu(options: .displayInline, children: [onlyFailuresAction]),
            LegacyMenu(options: .displayInline, children: [shareAction, clearAction]),
        ])
    }

    private func toggleLevel(_ level: Dog.DogLevel) {
        if selectedLevels.contains(level) {
            selectedLevels.remove(level)
        } else {
            selectedLevels.insert(level)
        }
        applyFilters(stickToBottom: false)
    }

    private func toggleCategory(_ category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
        applyFilters(stickToBottom: false)
    }

    /// Shares the log as a file. A support report is a `.log` attachment, not
    /// half a megabyte pasted into a message field.
    @objc private func shareLog() {
        let name = "irisin-\(Int(Date().timeIntervalSince1970)).log"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let items: [Any] = if (try? logText().write(to: file, atomically: true, encoding: .utf8)) != nil {
            [file]
        } else {
            [logText()]
        }
        // the bar button is a custom view, and that view is the anchor
        ShareSheet.present(
            items,
            anchor: navigationItem.rightBarButtonItem?.customView.map { PopoverAnchor($0) },
            from: self
        )
    }

    @objc private func clearLog() {
        hiddenPrefixCount = Dog.shared.obtainCurrentLogContent().count
        reload()
    }

    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let logLine = dataSource.itemIdentifier(for: indexPath)?.line else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyAction = LegacyAction(
                title: String(legacyLocalized: "Copy"),
                image: UIImage.compatSystemImage("doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = logLine.fullText
            }

            let copyMessageAction = LegacyAction(
                title: String(legacyLocalized: "Copy Message"),
                image: UIImage.compatSystemImage("text.quote")
            ) { _ in
                UIPasteboard.general.string = logLine.message
            }

            return LegacyMenu(children: [copyAction, copyMessageAction])
        }
    }
}
