//
//  TextReaderController.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import LegacyCompat
import SnapKit
import Then
import UIKit

/// Text to read: a maintainer script or a package's control fields, in a
/// monospaced, selectable text view whose lines run past the edge until the
/// toggle wraps them, with Share. Nothing here edits.
///
/// iOS 12 port: a UITextView where the upstream reader is Runestone's text
/// view (which stands on UITextInteraction, iOS 13), so there are no line
/// numbers and no syntax colours.
final class TextReaderController: UIViewController {
    private let text: String
    private let textView = UITextView()
    private var wrapsLines = false

    init(title: String, text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        let wrap = UIBarButtonItem(
            legacyTitle: String(legacyLocalized: "Wrap Lines"),
            image: UIImage.compatSystemImage("arrow.turn.down.left")
        ) { [weak self] item in
            guard let self else { return }
            wrapsLines.toggle()
            applyWrapping()
            item.tintColor = wrapsLines ? nil : .textSubtitle
        }
        wrap.tintColor = .textSubtitle
        let share = UIBarButtonItem(
            legacyTitle: String(legacyLocalized: "Share"),
            image: UIImage.compatSystemImage("square.and.arrow.up")
        ) { [weak self] _ in self?.share() }
        navigationItem.rightBarButtonItems = [share, wrap]

        textView.do {
            $0.isEditable = false
            $0.isSelectable = true
            $0.alwaysBounceVertical = true
            $0.font = UIFont.monospaced(.footnote)
            $0.textColor = .textTitle
            $0.backgroundColor = .pageBackground
            $0.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.dataDetectorTypes = []
            $0.text = text
        }
        view.backgroundColor = .pageBackground
        view.addSubview(textView)
        textView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        applyWrapping()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !wrapsLines { applyWrapping() }
    }

    /// Unwrapped, the text container is as wide as the longest line and the
    /// text view scrolls sideways; wrapped, it follows the view's width.
    private func applyWrapping() {
        let container = textView.textContainer
        if wrapsLines {
            container.widthTracksTextView = true
            container.lineBreakMode = .byWordWrapping
            container.size = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        } else {
            container.widthTracksTextView = false
            container.lineBreakMode = .byClipping
            let font = textView.font ?? UIFont.monospaced(.footnote)
            let longest = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { ($0 as Substring).count }.max() ?? 0
            let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
            let width = max(textView.bounds.width, CGFloat(longest) * advance + 32)
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        textView.layoutManager.ensureLayout(for: container)
        let used = textView.layoutManager.usedRect(for: container)
        textView.contentSize = CGSize(
            width: wrapsLines ? textView.bounds.width : container.size.width,
            height: used.height + textView.textContainerInset.top + textView.textContainerInset.bottom
        )
    }

    private func share() {
        ShareSheet.present(
            [text],
            anchor: navigationItem.rightBarButtonItem.map { PopoverAnchor($0) },
            from: self
        )
    }
}
