//
//  LicenseController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/30.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import SnapKit
import Then
import UIKit

/// One notice of `Licenses.json`, which the Collect Licenses build phase
/// scans from what the build links (`Scripts/collect-licenses.py`).
private nonisolated struct LicenseEntry: Decodable {
    let name: String
    let version: String?
    let license: String
    let url: String
    let text: String

    var summary: String {
        [license, version].compactMap(\.self).joined(separator: " · ")
    }
}

/// Every license the app ships under, a row per notice and its whole text
/// a push away. Adapted from Fila's LicensesViewController.
final class LicenseController: UITableViewController {
    private var entries: [LicenseEntry] = []

    /// rows by position: two notices may read the same
    private lazy var dataSource = LegacyTableViewDiffableDataSource<Int, Int>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, index in
        let entry = entries[index]
        let cell = tableView.dequeueReusableCell(withIdentifier: "license", for: indexPath)
        var content = LegacyListContentConfiguration.valueCell()
        content.text = entry.name
        content.textProperties.numberOfLines = 1
        content.secondaryText = entry.summary
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = .compatSecondaryLabel
        content.secondaryTextProperties.font = .footnote
        cell.legacyContentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    init() {
        super.init(style: .compatInsetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(legacyLocalized: "License")
        navigationItem.largeTitleDisplayMode = .never
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        } else {
            navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        }
        view.backgroundColor = .groupedBackground

        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LicenseEntry].self, from: data)
        {
            entries = decoded
        }
        if entries.isEmpty {
            tableView.backgroundView = UILabel().then {
                $0.text = String(legacyLocalized: "No license information to show.")
                $0.font = .body
                $0.textColor = .compatSecondaryLabel
                $0.numberOfLines = 0
                $0.textAlignment = .center
            }
        }

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "license")
        tableView.dataSource = dataSource
        var snapshot = LegacyDiffableSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(Array(entries.indices))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let index = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(LicenseTextController(entry: entries[index]), animated: true)
    }
}

/// The whole notice, selectable; its address is a link.
private final class LicenseTextController: UIViewController {
    private let entry: LicenseEntry

    init(entry: LicenseEntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.name
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .groupedBackground

        let text = NSMutableAttributedString(string: entry.name + "\n", attributes: [
            .font: UIFont.title, .foregroundColor: UIColor.compatLabel,
        ])
        text.append(NSAttributedString(string: entry.summary + "\n\n", attributes: [
            .font: UIFont.footnote, .foregroundColor: UIColor.compatSecondaryLabel,
        ]))
        if let url = URL(string: entry.url), ["https", "http"].contains(url.scheme) {
            text.append(NSAttributedString(string: entry.url + "\n\n", attributes: [
                .font: UIFont.footnote, .link: url,
            ]))
        }
        text.append(NSAttributedString(string: entry.text, attributes: [
            .font: UIFont.monospaced(.footnote), .foregroundColor: UIColor.compatLabel,
        ]))
        let textView = UITextView().then {
            $0.isEditable = false
            $0.backgroundColor = .clear
            $0.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 28, right: 16)
            $0.attributedText = text
        }

        // edge to edge, so the bar's own scroll edge blur is what covers the text
        view.addSubview(textView)
        textView.snp.makeConstraints { $0.edges.equalToSuperview() }
        if #available(iOS 26.0, *) {
            textView.topEdgeEffect.style = .soft
        }
    }
}
