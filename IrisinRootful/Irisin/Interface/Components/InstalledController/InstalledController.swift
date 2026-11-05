//
//  InstalledController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import OpenCombine
import OpenCombineDispatch
import OpenCombineFoundation
import SPIndicator
import Then
import UIKit

class InstalledController: UICollectionViewController {
    var subscriptions = Set<AnyCancellable>()
    var updateSetTask: LegacyMainTask?

    // MARK: - SORT OPTION

    enum SortOption: String, CaseIterable {
        case name
        case lastModification

        func convertToInterfaceString() -> String {
            switch self {
            case .name:
                String(legacyLocalized: "Name")
            case .lastModification:
                String(legacyLocalized: "Last Modified")
            }
        }
    }

    private let sortOptionStore = Stored(
        key: "installed.sortOption",
        defaultValue: SortOption.lastModification.rawValue
    )
    private let sortReversedStore = Stored(key: "installed.sortReversed", defaultValue: false)

    var sortOption: SortOption {
        SortOption(rawValue: sortOptionStore.wrappedValue) ?? .name
    }

    var sortReversed: Bool {
        get { sortReversedStore.wrappedValue }
        set {
            sortReversedStore.wrappedValue = newValue
            LegacyMainTask { updateSource() }
        }
    }

    // MARK: - FILTER

    /// The `Section:` fields the list is narrowed to; empty shows everything.
    private let selectedSectionsStore = Stored(key: "installed.sections", defaultValue: [String]())
    var selectedSections: Set<String> {
        get { Set(selectedSectionsStore.wrappedValue) }
        set {
            selectedSectionsStore.wrappedValue = newValue.sorted()
            LegacyMainTask { updateSource(withSearchText: searchController.searchBar.text) }
        }
    }

    /// The authors the list is narrowed to; empty shows everything.
    private let selectedAuthorsStore = Stored(key: "installed.authors", defaultValue: [String]())
    var selectedAuthors: Set<String> {
        get { Set(selectedAuthorsStore.wrappedValue) }
        set {
            selectedAuthorsStore.wrappedValue = newValue.sorted()
            LegacyMainTask { updateSource(withSearchText: searchController.searchBar.text) }
        }
    }

    /// Every section and author among the installed packages and how many
    /// packages carry each, before the filter and the search apply.
    /// Refreshed by `updateSource`.
    var sectionCounts: [String: Int] = [:]
    var authorCounts: [String: Int] = [:]

    static func section(of package: Package) -> String {
        let section = package.latestMetadata?["section"] ?? ""
        return section.isEmpty ? String(legacyLocalized: "Unknown Section") : section.sectionDisplayName
    }

    /// Each author the way the package page names them: the name alone,
    /// without the `<address>` or `<https://...>` after it.
    static func authors(of package: Package) -> [String] {
        let authors = PackageCenter.authors(of: package)
            .map { PackageController.contact($0).text }
            .filter { !$0.isEmpty }
        return authors.isEmpty ? [String(legacyLocalized: "Unknown Author")] : authors
    }

    // MARK: - PROPERTY

    let searchController = UISearchController()
    let cellId = UUID().uuidString
    let headerId = UUID().uuidString

    struct InstalledGroup {
        let key: Date? // the section: the modification date, nil when unsorted or never modified
        let section: String?
        var packages: [Package]
    }

    var dataSource: [InstalledGroup] = []
    /// Installed packages with a candidate. Answering this per row costs two
    /// index lookups, so the whole set is refreshed on a reload and read from.
    /// The install origins by identity, as of the last reload: the rows are
    /// dpkg's, and they sort and search by the name the origin gives them.
    var origins: [String: Package] = [:]
    var identitiesWithUpdate: Set<String> = []
    var updateFound: Bool {
        !identitiesWithUpdate.isEmpty
    }

    private(set) lazy var diffableDataSource: LegacyCollectionViewDiffableDataSource<Date?, Package> = {
        let source = LegacyCollectionViewDiffableDataSource<Date?, Package>(
            collectionView: collectionView
        ) { [unowned self] collectionView, indexPath, package in
            configureCell(collectionView, at: indexPath, for: package)
        }
        source.supplementaryViewProvider = { [unowned self] collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionFooter {
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: footerId,
                    for: indexPath
                )
                if let view = view as? ListFootnoteView {
                    configureFooter(view)
                    footerView = view
                }
                return view
            }
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: headerId,
                for: indexPath
            )
            if let view = view as? PackageSectionHeaderView,
               let key = diffableDataSource.sectionIdentifier(for: indexPath.section)
            {
                view.horizontalPadding = 0
                view.loadText(dataSource.first { $0.key == key }?.section ?? "")
            }
            return view
        }
        return source
    }()

    /// Whether the sections have date headers, which the layout reads. An
    /// empty list has its one section and no header over it.
    private(set) var showsHeaders = false

    /// The rows are laid out in columns, where only `gridSwipe` swipes
    /// them; a single column is a list section, which swipes its own.
    var laysOutGrid = false
    private(set) lazy var gridSwipe = GridSwipeInteraction(collectionView: collectionView) { [weak self] in
        self?.gridSwipeActions(at: $0)
    }

    var isEmpty: Bool {
        dataSource.allSatisfy(\.packages.isEmpty)
    }

    func applySnapshot() {
        var snapshot = LegacyDiffableSnapshot<Date?, Package>()
        var seen = Set<Package>()
        for section in dataSource {
            snapshot.appendSections([section.key])
            snapshot.appendItems(section.packages.filter { seen.insert($0).inserted }, toSection: section.key)
        }
        // the update indicator lives outside the package: repaint survivors
        snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
        // the date headers are the layout's: when they come or go the
        // sections change shape, and that is no diff to animate. The flag
        // changes once the rows have, and the layout is made again then.
        let headers = sortOption == .lastModification && !isEmpty
        let reshaped = headers != showsHeaders
        // an open swipe belongs to a cell, which the diff may move
        gridSwipe.close(animated: false)
        diffableDataSource.apply(
            snapshot,
            animatingDifferences: !reshaped && collectionView.shouldAnimateDiff
        ) { [weak self] in
            guard reshaped, let self else { return }
            showsHeaders = headers
            collectionView.collectionViewLayout.invalidateLayout()
        }
        // the footer is not a row: a diff never redraws it, so tell it
        // directly. A link that came or went changes its height.
        if let footerView {
            let linked = footerView.linkTitle != nil
            configureFooter(footerView)
            if (footerView.linkTitle != nil) != linked {
                collectionView.collectionViewLayout.invalidateLayout()
            }
        }
        // a row that left the list left the selection
        updateSelectionItems()
        rebuildMoreMenu()
        updateEmptyState()
    }

    /// Nothing to list is said, and says whether a search or a filter is
    /// the reason; a blank screen looks like a broken one.
    private func updateEmptyState() {
        guard isEmpty else {
            collectionView.backgroundView = nil
            return
        }
        emptyStateLabel.text = isNarrowed
            ? String(legacyLocalized: "No installed packages match the search or filter.")
            : String(legacyLocalized: "No packages are installed.")
        collectionView.backgroundView = emptyStateLabel
    }

    /// Whether a search or a filter is holding rows back.
    private var isNarrowed: Bool {
        !(searchController.searchBar.text ?? "").isEmpty
            || !selectedSections.isEmpty
            || !selectedAuthors.isEmpty
    }

    private let emptyStateLabel = EmptyStateView()

    // MARK: - FOOTER

    let footerId = UUID().uuidString
    /// The one footer on screen, so a new list can retitle it without a reload.
    weak var footerView: ListFootnoteView?

    /// What the list shows, filter and search applied.
    var footerText: String {
        let shown = dataSource.flatMap(\.packages)
        let sections = Set(shown.map(Self.section(of:))).count
        return String(legacyLocalized: "Packages: \(shown.count) · Sections: \(sections)")
    }

    /// The count, and under it while a search narrows the list a link that
    /// takes the same text to the Search page, which looks through every
    /// repository. Over an empty list the count would sit on the empty
    /// state and only the link stays: no installed match is when it helps.
    private func configureFooter(_ view: ListFootnoteView) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        view.label.text = isEmpty ? nil : footerText
        view.linkTitle = query.isEmpty ? nil : String(legacyLocalized: "Search All Repositories")
        view.linkAction = { [weak self] in
            self?.present(next: SearchController(query: query))
        }
        view.isHidden = isEmpty && query.isEmpty
    }

    let formatter = DateFormatter().then {
        $0.formatterBehavior = .behavior10_4
        $0.dateStyle = .medium
        $0.timeStyle = .medium
    }

    let refreshControl = UIRefreshControl()

    /// The layout needs the controller, which `super.init` has to come
    /// before: `viewDidLoad` sets `makeLayout()` ahead of the first row.
    init() {
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func justReload() {
        updateSource(withSearchText: searchController.searchBar.compatSearchTextField.text)
        refreshUpdateSet()
    }

    @objc
    func refresh() {
        LegacyMainTask {
            awaitBackground { PackageCenter.default.reloadLocalPackages() }
            refreshControl.endRefreshing()
            justReload()
            SPIndicator
                .present(
                    title: String(legacyLocalized: "Installed packages refreshed"),
                    message: "",
                    preset: .done,
                    from: .top,
                    completion: nil
                )
        }
    }

    @objc
    func sendUpdate() {
        UpdateController.show(from: self)
    }

    // MARK: - MORE MENU

    /// The ellipsis left of the update button: refresh, export, the filters
    /// and the sort order. A `UIButton`, because reassigning its `menu`
    /// redraws the menu while it is open — `updateVisibleMenu` does not, and
    /// a deferred element is resolved once per presentation — so a filter
    /// toggled with `keepsMenuPresented` ticks at once. `applySnapshot`
    /// rebuilds it, and every change to the list goes through there.
    private let moreButton = UIButton(type: .system).then {
        $0.setImage(UIImage.compatSystemImage("ellipsis"), for: .normal)
        $0.tintColor = .textTitle
        $0.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        $0.accessibilityLabel = String(legacyLocalized: "More")
    }

    lazy var moreItem = UIBarButtonItem(customView: moreButton)

    func rebuildMoreMenu() {
        moreButton.legacySetMenu(LegacyMenu(identifier: .init("installed.more"), children: buildMoreMenu()))
    }

    private func buildMoreMenu() -> [LegacyMenuElement] {
        // multi-selection reads better with the menu staying open, iOS 16 has that
        var stays: LegacyAction.Attributes = []
        if #available(iOS 16.0, *) {
            stays.insert(.keepsMenuPresented)
        }

        // the list sorts dates newest first when not reversed, names A to Z
        let sort = LegacyMenu(
            title: String(legacyLocalized: "Sort By"),
            subtitle: sortOption.convertToInterfaceString(),
            image: UIImage.compatSystemImage("arrow.up.arrow.down"),
            identifier: .init("installed.sort"),
            children: SortOption.allCases.map { option in
                let ascendingIsReversed = option == .lastModification
                let directions = [
                    (true, String(legacyLocalized: "Ascending"), "arrow.up"),
                    (false, String(legacyLocalized: "Descending"), "arrow.down"),
                ]
                return LegacyMenu(
                    title: option.convertToInterfaceString(),
                    image: UIImage.compatSystemImage(option == .name ? "textformat" : "clock"),
                    identifier: .init("installed.sort.\(option.rawValue)"),
                    children: directions.map { ascending, title, icon in
                        let reversed = ascending == ascendingIsReversed
                        return LegacyAction(
                            title: title,
                            image: UIImage.compatSystemImage(icon),
                            state: sortOption == option && sortReversed == reversed ? .on : .off
                        ) { [weak self] _ in
                            guard let self else { return }
                            sortOptionStore.wrappedValue = option.rawValue // one rebuild, below
                            sortReversed = reversed
                        }
                    }
                )
            }
        )

        let filtering = !selectedSections.isEmpty || !selectedAuthors.isEmpty
        let total = sectionCounts.values.reduce(0, +)
        let filter = LegacyMenu(
            title: String(legacyLocalized: "Filter"),
            subtitle: filtering ? nil : String(legacyLocalized: "\(total) Packages"),
            image: UIImage.compatSystemImage(filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            ),
            identifier: .init("installed.filter"),
            children: [
                choiceMenu(
                    title: String(legacyLocalized: "Section"),
                    image: "square.grid.2x2",
                    identifier: "installed.filter.section",
                    all: String(legacyLocalized: "All Sections"),
                    counts: sectionCounts,
                    selection: \.selectedSections,
                    stays: stays
                ),
                choiceMenu(
                    title: String(legacyLocalized: "Author"),
                    image: "person",
                    identifier: "installed.filter.author",
                    all: String(legacyLocalized: "All Authors"),
                    counts: authorCounts,
                    selection: \.selectedAuthors,
                    stays: stays
                ),
            ]
        )

        var top: [LegacyMenuElement] = [
            LegacyAction(
                title: String(localized: "Refresh"),
                image: UIImage.compatSystemImage("arrow.clockwise")
            ) { [weak self] _ in self?.refresh() },
            LegacyAction(
                title: String(localized: "Select"),
                image: UIImage.compatSystemImage("checkmark.circle")
            ) { [weak self] _ in self?.setEditing(true, animated: true) },
        ]
        if updateFound {
            top.append(LegacyAction(
                title: String(legacyLocalized: "Block All Updates"),
                image: UIImage.compatSystemImage("hand.raised"),
                attributes: .destructive
            ) { [weak self] _ in self?.blockUpdateAll() })
        }

        return [
            LegacyMenu(options: .displayInline, children: top),
            LegacyMenu(options: .displayInline, children: [
                LegacyAction(
                    title: String(legacyLocalized: "Export Package List"),
                    image: UIImage.compatSystemImage("square.and.arrow.up")
                ) { [weak self] _ in self?.exportPackageList() },
                LegacyAction(
                    title: String(legacyLocalized: "Export dpkg Status"),
                    image: UIImage.compatSystemImage("doc.text")
                ) { [weak self] _ in self?.exportStatus() },
            ]),
            LegacyMenu(options: .displayInline, children: [filter, sort]),
        ]
    }

    /// A multi-selection over `counts`: "all" on top, then every choice with
    /// its count, ticked when selected. The selection is read through the key
    /// path on every tap, so a menu that stays open never toggles a stale set.
    private func choiceMenu(
        title: String,
        image: String,
        identifier: String,
        all: String,
        counts: [String: Int],
        selection: ReferenceWritableKeyPath<InstalledController, Set<String>>,
        stays: LegacyAction.Attributes
    ) -> LegacyMenu {
        let selected = self[keyPath: selection]
        let allAction = LegacyAction(
            title: all,
            attributes: stays,
            state: selected.isEmpty ? .on : .off
        ) { [weak self] _ in self?[keyPath: selection] = [] }
        let choices = counts.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { choice in
                LegacyAction(
                    title: choice,
                    subtitle: String(counts[choice, default: 0]),
                    attributes: stays,
                    state: selected.contains(choice) ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    var next = self[keyPath: selection]
                    if next.remove(choice) == nil {
                        next.insert(choice)
                    }
                    self[keyPath: selection] = next
                }
            }
        return LegacyMenu(
            title: title,
            subtitle: selected.isEmpty ? nil : selected.sorted().joined(separator: ", "),
            image: UIImage.compatSystemImage(image),
            identifier: .init(identifier),
            children: [
                LegacyMenu(options: .displayInline, children: [allAction]),
                LegacyMenu(options: .displayInline, children: choices),
            ]
        )
    }

    /// The rows as they are filtered and sorted right now, one package a line.
    private func exportPackageList() {
        let packages = dataSource.flatMap(\.packages)
        guard !packages.isEmpty else {
            presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        ExportFile.share(
            ExportFile.packageText(packages),
            named: "installed-\(ExportFile.stamp()).txt",
            from: self,
            anchor: PopoverAnchor(moreButton)
        )
    }

    /// Shares dpkg's own status file, the raw record every row here came from.
    /// A copy, so the sheet never holds the bootstrap's file open while dpkg
    /// rewrites it.
    func exportStatus() {
        let source = URL(fileURLWithPath: JailbreakRoot.installedPath("/Library/dpkg/status"))
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpkg-status-\(ExportFile.stamp()).txt")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            presentNotice(
                title: "Unable to Export",
                message: "The dpkg status file could not be copied. Try again."
            )
            return
        }
        share(copy)
    }

    private func share(_ item: Any) {
        ShareSheet.present([item], anchor: PopoverAnchor(moreButton), from: self)
    }

    @objc
    func showAllUpdateToDate() {
        let nothingInstalled = isEmpty && !isNarrowed
        SPIndicator.present(
            title: nothingInstalled
                ? String(legacyLocalized: "No packages are installed.")
                : String(legacyLocalized: "All packages are up to date"),
            preset: .done
        )
    }

    @objc
    func blockUpdateAll() {
        PackageQueue.shared.blockUpdateEverything()
        refreshUpdateSet()
    }

    // MARK: - SELECTION

    /// The bar while the list is edited (`InstalledController+Selection`).
    private(set) lazy var removeSelectedItem = UIBarButtonItem(
        title: PackageMenu.Action.remove.describe(),
        style: .plain,
        target: self,
        action: #selector(removeSelected)
    ).then {
        $0.tintColor = .destructiveAction
    }

    private(set) lazy var updateSelectedItem = UIBarButtonItem(
        title: PackageMenu.Action.update.describe(),
        style: .plain,
        target: self,
        action: #selector(updateSelected)
    )

    /// Where the bar's items go. The iPad's detail column has the search
    /// field inline at the trailing end of the bar, which leaves the title
    /// little room as it is: there the items lead, the update button first
    /// and the ellipsis after it. The compact interface is another
    /// controller (`InterfaceHostController` swaps the two), so an
    /// item never changes sides while it is on screen.
    var placesBarItemsLeading: Bool {
        false
    }

    /// The update button, or the tick that says there is nothing to update.
    /// One item for the page's life: the bar is told what changed, never
    /// handed a new item to animate in.
    private lazy var statusItem = UIBarButtonItem(
        image: nil,
        style: .plain,
        target: self,
        action: nil
    )

    /// The items this page put on the bar, either side.
    private var ownBarItems: [UIBarButtonItem] = []

    /// Puts the page's items on the bar and leaves the rest alone: the split
    /// view keeps its Show Sidebar item first on the leading side
    /// (`SplitInterfaceController.syncSidebarToggle`), and the page's follow it.
    func placeBarItems(
        leading: [UIBarButtonItem],
        trailing: [UIBarButtonItem],
        animated: Bool
    ) {
        let own = Set(ownBarItems.map(ObjectIdentifier.init))
        func kept(_ items: [UIBarButtonItem]?) -> [UIBarButtonItem] {
            (items ?? []).filter { !own.contains(ObjectIdentifier($0)) }
        }
        let left = kept(navigationItem.leftBarButtonItems) + leading
        let right = trailing + kept(navigationItem.rightBarButtonItems)
        ownBarItems = leading + trailing
        // every reload comes through here: a bar that already reads so stays
        if !(navigationItem.leftBarButtonItems ?? []).elementsEqual(left, by: ===) {
            navigationItem.setLeftBarButtonItems(left.isEmpty ? nil : left, animated: animated)
        }
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(right, by: ===) {
            navigationItem.setRightBarButtonItems(right.isEmpty ? nil : right, animated: animated)
        }
    }

    func setupBarItems(animated: Bool = false) {
        // the bar is the selection's while the list is edited
        guard !isEditing else { return }
        // one name in both states; the tick is the item saying there is
        // nothing to update, which is a value and not another button
        statusItem.accessibilityLabel = String(legacyLocalized: "Updates")
        if updateFound {
            statusItem.image = .fluent(.arrowUpCircle24Filled)
            statusItem.action = #selector(sendUpdate)
            statusItem.tintColor = nil
            statusItem.accessibilityValue = nil
        } else {
            statusItem.image = .fluent(.checkmarkCircle24Filled)
            statusItem.action = #selector(showAllUpdateToDate)
            statusItem.tintColor = .upToDate
            statusItem.accessibilityValue = String(legacyLocalized: "All packages are up to date")
        }
        if placesBarItemsLeading {
            placeBarItems(leading: [statusItem, moreItem], trailing: [], animated: animated)
        } else {
            placeBarItems(leading: [], trailing: [statusItem, moreItem], animated: animated)
        }
    }
}
