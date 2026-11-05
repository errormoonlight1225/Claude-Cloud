//
//  SheetMenu.swift
//  MarkdownView
//

import LegacyCompat
import Foundation
import UIKit

/// What the menu at the top trailing corner of a code or table sheet does.
///
/// The block in the document keeps only Copy and Expand; saving a file and
/// closing the sheet happen from here.
struct SheetMenuActions {
    let copy: () -> Void
    let download: () -> Void
    let close: () -> Void
}

enum SheetMenuText {
    static var more: String {
        String(legacyLocalized: "More", comment: "Button that opens a sheet's menu of actions.")
    }

    static var close: String {
        String(legacyLocalized: "Close", comment: "Menu item that closes a code or table sheet.")
    }
}

enum SheetMenuSymbol {
    static let menu = "ellipsis"
    static let close = "chevron.down"
}

extension UIBarButtonItem {
    /// A bar button that opens Copy, Download and Close.
    static func sheetMenu(_ actions: SheetMenuActions) -> UIBarButtonItem {
        // iOS 12 port: LegacyMenu (an action sheet below iOS 15)
        let menu = LegacyMenu(children: [
            LegacyAction(title: TableTitleText.copy, image: UIImage.compatSystemImage(TableSymbol.copy)) { _ in
                actions.copy()
            },
            LegacyAction(title: TableTitleText.download, image: UIImage.compatSystemImage(TableSymbol.download)) { _ in
                actions.download()
            },
            LegacyAction(title: SheetMenuText.close, image: UIImage.compatSystemImage(SheetMenuSymbol.close)) { _ in
                actions.close()
            },
        ])
        let item = UIBarButtonItem(legacyTitle: nil, image: UIImage.compatSystemImage(SheetMenuSymbol.menu)) { menu }
        item.accessibilityLabel = SheetMenuText.more
        return item
    }
}
