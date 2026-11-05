//
//  QueuePackageController.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import UIKit

/// One queued package, opened from its row on the queue page: what the
/// change does to the files on the device and which maintainer scripts run
/// for it, in order. Every count is written out, a zero too, and one that is
/// not zero opens its paths; a script opens its text. The page only reads:
/// Execute on the queue page never waits for it.
final class QueuePackageController: UIViewController, UITableViewDelegate {
    nonisolated enum Section: Hashable {
        case package, reading, files, scripts
    }

    nonisolated enum Row: Hashable {
        case package
        case reading
        case failure
        case added, replaced, deleted
        /// An index into the inspection's scripts.
        case script(Int)
        case noScripts
    }

    private let change: QueueChange
    private var inspection: QueuePackageInspection?
    private var failed = false
    private var work: LegacyMainTask?
    private lazy var icons = PackageIconCache { [weak self] in self?.render(animated: false) }

    private let tableView = UITableView(frame: .zero, style: .compatInsetGrouped)

    private lazy var dataSource: EditableTableDiffableDataSource<Section, Row> = .init(
        tableView: tableView
    ) { [unowned self] table, indexPath, row in
        let cell = table.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.legacyContentConfiguration = content(for: row)
        let opens = opens(row)
        cell.selectionStyle = opens ? .default : .none
        cell.accessoryType = opens ? .disclosureIndicator : .none
        cell.accessoryView = row == .reading ? spinner : nil
        return cell
    }

    private let spinner = UIActivityIndicatorView(style: .compatMedium)

    init(change: QueueChange) {
        self.change = change
        super.init(nibName: nil, bundle: nil)
        title = change.name
        // not hashed: the page only looks
        let archive = change.package.fileOnDisk
        work = LegacyMainTask { [weak self] in
            let inspection = try? awaitBackground { try QueuePackageInspection.inspect(change, archive: archive) }
            guard let self else { return }
            work = nil
            self.inspection = inspection
            failed = inspection == nil
            if isViewLoaded {
                render(animated: view.shouldAnimateDiff)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// Waits for the package to be read, up to `budget`, so a quick read
    /// arrives with the page and only a slow one fades in after it. A large
    /// package takes seconds to read; the page does not wait for that.
    func prepare(within budget: TimeInterval) {
        awaitBackground { work?.wait(upTo: budget) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never

        tableView.backgroundColor = .groupedBackground
        tableView.register(ListContentCell.self, forCellReuseIdentifier: "row")
        tableView.delegate = self
        tableView.dataSource = dataSource
        dataSource.defaultRowAnimation = .fade
        dataSource.headerTitle = { section in
            switch section {
            case .files: String(legacyLocalized: "Files")
            case .scripts: String(legacyLocalized: "Scripts")
            case .package, .reading: nil
            }
        }
        dataSource.footerTitle = { [unowned self] section in
            guard let inspection else { return nil }
            switch section {
            case .files where inspection.otherOwned > 0:
                let owners = LegacyListFormatter.localizedString(byJoining: inspection.otherOwners)
                return String(legacyLocalized: "\(inspection.otherOwned) of the replaced files belong to \(owners).")
            case .scripts where !inspection.scripts.isEmpty:
                return String(legacyLocalized: "The scripts run as root, in this order.")
            default:
                return nil
            }
        }
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        spinner.startAnimating()
        render(animated: false)
    }

    // MARK: - Content

    private func render(animated: Bool) {
        var snapshot = LegacyDiffableSnapshot<Section, Row>()
        snapshot.appendSections([.package])
        snapshot.appendItems([.package], toSection: .package)
        if let inspection {
            snapshot.appendSections([.files, .scripts])
            snapshot.appendItems([.added, .replaced, .deleted], toSection: .files)
            snapshot.appendItems(
                inspection.scripts.isEmpty ? [.noScripts] : inspection.scripts.indices.map(Row.script),
                toSection: .scripts
            )
        } else {
            snapshot.appendSections([.reading])
            snapshot.appendItems([failed ? .failure : .reading], toSection: .reading)
        }
        snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func paths(for row: Row) -> [String] {
        switch row {
        case .added: inspection?.added ?? []
        case .replaced: inspection?.replaced ?? []
        case .deleted: inspection?.deleted ?? []
        default: []
        }
    }

    private func opens(_ row: Row) -> Bool {
        switch row {
        case .added, .replaced, .deleted: !paths(for: row).isEmpty
        case let .script(index): inspection?.scripts[index].text != nil
        case .package, .reading, .failure, .noScripts: false
        }
    }

    private func title(of row: Row) -> String {
        switch row {
        case .added: String(legacyLocalized: "New Files")
        case .replaced: String(legacyLocalized: "Replaced Files")
        case .deleted: String(legacyLocalized: "Deleted Files")
        default: ""
        }
    }

    private func content(for row: Row) -> LegacyListContentConfiguration {
        var content = LegacyListContentConfiguration.valueCell()
        content.textProperties.font = .body
        content.secondaryTextProperties.font = .body.monospacedDigitFont
        content.secondaryTextProperties.color = .textSubtitle
        switch row {
        case .package:
            return change.content(
                icon: icons.icon(of: change.package),
                details: [change.versions, change.kind.title(dependencies: false)]
            )
        case .reading:
            content.text = String(legacyLocalized: "Reading the package…")
            content.textProperties.color = .textSubtitle
        case .failure:
            content.text = String(legacyLocalized: "Unable to read this package.")
            content.textProperties.color = .operationFailed
            content.image = UIImage.compatSystemImage("exclamationmark.triangle")
            content.imageProperties.tintColor = .operationFailed
        case .added, .replaced, .deleted:
            let count = paths(for: row).count
            content.text = title(of: row)
            content.secondaryText = count.formatted()
            // something already there goes: the one count worth a second look
            if row == .replaced, count > 0 {
                content.textProperties.color = .diffReplacement
                content.secondaryTextProperties.color = .diffReplacement
            }
        case let .script(index):
            guard let script = inspection?.scripts[index] else { break }
            content.text = script.invocation
            content.textProperties.font = .monospaced(.subheadline)
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingMiddle
            let origin = script.installed ? String(legacyLocalized: "Installed") : String(legacyLocalized: "Incoming")
            content.secondaryText = script.text == nil ? String(legacyLocalized: "\(origin) · Binary") : origin
            content.secondaryTextProperties.font = .footnote
            content.prefersSideBySideTextAndSecondaryText = true
        case .noScripts:
            content.text = String(legacyLocalized: "No scripts")
            content.textProperties.color = .textSubtitle
        }
        return content
    }

    /// A row that opens nothing never highlights, whatever it was reused from.
    func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).map(opens) ?? false
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath), opens(row) else { return }
        if case let .script(index) = row, let script = inspection?.scripts[index], let text = script.text {
            present(next: TextReaderController(title: script.invocation, text: text))
        } else {
            present(next: PathListController(title: title(of: row), paths: paths(for: row)))
        }
    }
}
