//
//  Diffable.swift
//  LegacyCompat
//
//  Diffable data sources are iOS 13 and `reconfigureItems` iOS 15. These
//  keep their spelling over the iOS 12 data source protocols: a snapshot of
//  section and item identities, applied to a table or collection view. An
//  apply that only inserts and deletes (the order of what stays unchanged)
//  is animated as a batch of row changes; anything else reloads the view.
//  Reconfigured items have their visible cells made again by the provider.
//

#if canImport(UIKit) && os(iOS)
    import UIKit

    public struct LegacyDiffableSnapshot<SectionIdentifierType: Hashable, ItemIdentifierType: Hashable> {
        public typealias Section = SectionIdentifierType
        public typealias Item = ItemIdentifierType

        private(set) var sections: [Section] = []
        private(set) var items: [Section: [Item]] = [:]
        private var sectionOfItem: [Item: Section] = [:]
        /// identities whose cells are made again on the next apply
        var refreshed: Set<Item> = []
        var refreshedSections: Set<Section> = []

        public init() {}

        // MARK: Reading

        public var numberOfSections: Int { sections.count }
        public var numberOfItems: Int { sections.reduce(0) { $0 + (items[$1]?.count ?? 0) } }
        public var sectionIdentifiers: [Section] { sections }
        public var itemIdentifiers: [Item] { sections.flatMap { items[$0] ?? [] } }
        public var reconfiguredItemIdentifiers: [Item] { Array(refreshed) }
        public var reloadedItemIdentifiers: [Item] { Array(refreshed) }

        public func numberOfItems(inSection section: Section) -> Int { items[section]?.count ?? 0 }
        public func itemIdentifiers(inSection section: Section) -> [Item] { items[section] ?? [] }
        public func sectionIdentifier(containingItem item: Item) -> Section? { sectionOfItem[item] }

        public func indexOfItem(_ item: Item) -> Int? {
            guard let section = sectionOfItem[item] else { return nil }
            var offset = 0
            for current in sections {
                if current == section { return (items[current]?.firstIndex(of: item)).map { offset + $0 } }
                offset += items[current]?.count ?? 0
            }
            return nil
        }

        public func indexOfSection(_ section: Section) -> Int? { sections.firstIndex(of: section) }

        // MARK: Sections

        public mutating func appendSections(_ identifiers: [Section]) {
            for section in identifiers where items[section] == nil {
                sections.append(section)
                items[section] = []
            }
        }

        public mutating func insertSections(_ identifiers: [Section], beforeSection: Section) {
            guard let index = sections.firstIndex(of: beforeSection) else { return }
            let new = identifiers.filter { items[$0] == nil }
            sections.insert(contentsOf: new, at: index)
            new.forEach { items[$0] = [] }
        }

        public mutating func insertSections(_ identifiers: [Section], afterSection: Section) {
            guard let index = sections.firstIndex(of: afterSection) else { return }
            let new = identifiers.filter { items[$0] == nil }
            sections.insert(contentsOf: new, at: index + 1)
            new.forEach { items[$0] = [] }
        }

        public mutating func deleteSections(_ identifiers: [Section]) {
            for section in identifiers {
                for item in items[section] ?? [] { sectionOfItem[item] = nil }
                items[section] = nil
                sections.removeAll { $0 == section }
            }
        }

        public mutating func reloadSections(_ identifiers: [Section]) {
            refreshedSections.formUnion(identifiers)
        }

        public mutating func reconfigureSections(_ identifiers: [Section]) {
            refreshedSections.formUnion(identifiers)
        }

        public mutating func moveSection(_ section: Section, beforeSection: Section) {
            guard section != beforeSection, sections.contains(section) else { return }
            sections.removeAll { $0 == section }
            guard let index = sections.firstIndex(of: beforeSection) else { return }
            sections.insert(section, at: index)
        }

        public mutating func moveSection(_ section: Section, afterSection: Section) {
            guard section != afterSection, sections.contains(section) else { return }
            sections.removeAll { $0 == section }
            guard let index = sections.firstIndex(of: afterSection) else { return }
            sections.insert(section, at: index + 1)
        }

        // MARK: Items

        public mutating func appendItems(_ identifiers: [Item], toSection section: Section? = nil) {
            guard let target = section ?? sections.last, items[target] != nil else { return }
            for item in identifiers where sectionOfItem[item] == nil {
                items[target]?.append(item)
                sectionOfItem[item] = target
            }
        }

        public mutating func insertItems(_ identifiers: [Item], beforeItem: Item) {
            guard let section = sectionOfItem[beforeItem], let index = items[section]?.firstIndex(of: beforeItem) else { return }
            let new = identifiers.filter { sectionOfItem[$0] == nil }
            items[section]?.insert(contentsOf: new, at: index)
            new.forEach { sectionOfItem[$0] = section }
        }

        public mutating func insertItems(_ identifiers: [Item], afterItem: Item) {
            guard let section = sectionOfItem[afterItem], let index = items[section]?.firstIndex(of: afterItem) else { return }
            let new = identifiers.filter { sectionOfItem[$0] == nil }
            items[section]?.insert(contentsOf: new, at: index + 1)
            new.forEach { sectionOfItem[$0] = section }
        }

        public mutating func deleteItems(_ identifiers: [Item]) {
            for item in identifiers {
                guard let section = sectionOfItem[item] else { continue }
                items[section]?.removeAll { $0 == item }
                sectionOfItem[item] = nil
                refreshed.remove(item)
            }
        }

        public mutating func deleteAllItems() {
            sections.removeAll()
            items.removeAll()
            sectionOfItem.removeAll()
            refreshed.removeAll()
            refreshedSections.removeAll()
        }

        public mutating func moveItem(_ item: Item, beforeItem: Item) {
            guard item != beforeItem, let from = sectionOfItem[item], let to = sectionOfItem[beforeItem] else { return }
            items[from]?.removeAll { $0 == item }
            guard let index = items[to]?.firstIndex(of: beforeItem) else { return }
            items[to]?.insert(item, at: index)
            sectionOfItem[item] = to
        }

        public mutating func moveItem(_ item: Item, afterItem: Item) {
            guard item != afterItem, let from = sectionOfItem[item], let to = sectionOfItem[afterItem] else { return }
            items[from]?.removeAll { $0 == item }
            guard let index = items[to]?.firstIndex(of: afterItem) else { return }
            items[to]?.insert(item, at: index + 1)
            sectionOfItem[item] = to
        }

        public mutating func reconfigureItems(_ identifiers: [Item]) {
            refreshed.formUnion(identifiers.filter { sectionOfItem[$0] != nil })
        }

        public mutating func reloadItems(_ identifiers: [Item]) {
            reconfigureItems(identifiers)
        }

        // MARK: Paths

        func item(at indexPath: IndexPath) -> Item? {
            guard indexPath.section < sections.count, let list = items[sections[indexPath.section]],
                  indexPath.item < list.count
            else { return nil }
            return list[indexPath.item]
        }

        func indexPath(of item: Item) -> IndexPath? {
            guard let section = sectionOfItem[item], let s = sections.firstIndex(of: section),
                  let row = items[section]?.firstIndex(of: item)
            else { return nil }
            return IndexPath(item: row, section: s)
        }

        /// The row changes from `old` to self, when what stays keeps its
        /// order and the sections are the same: nil otherwise.
        func changes(from old: LegacyDiffableSnapshot) -> (deleted: [IndexPath], inserted: [IndexPath])? {
            guard old.sections == sections else { return nil }
            var deleted = [IndexPath]()
            var inserted = [IndexPath]()
            for (s, section) in sections.enumerated() {
                let before = old.items[section] ?? []
                let after = items[section] ?? []
                let afterSet = Set(after)
                let beforeSet = Set(before)
                let keptBefore = before.filter { afterSet.contains($0) }
                let keptAfter = after.filter { beforeSet.contains($0) }
                guard keptBefore == keptAfter else { return nil }
                for (row, item) in before.enumerated() where !afterSet.contains(item) {
                    deleted.append(IndexPath(item: row, section: s))
                }
                for (row, item) in after.enumerated() where !beforeSet.contains(item) {
                    inserted.append(IndexPath(item: row, section: s))
                }
            }
            return (deleted, inserted)
        }

        func clearingRefresh() -> LegacyDiffableSnapshot {
            var copy = self
            copy.refreshed.removeAll()
            copy.refreshedSections.removeAll()
            return copy
        }
    }

    // MARK: - Table views

    open class LegacyTableViewDiffableDataSource<SectionIdentifierType: Hashable, ItemIdentifierType: Hashable>:
        NSObject, UITableViewDataSource
    {
        public typealias Snapshot = LegacyDiffableSnapshot<SectionIdentifierType, ItemIdentifierType>
        public typealias CellProvider = (UITableView, IndexPath, ItemIdentifierType) -> UITableViewCell?

        private weak var tableView: UITableView?
        private let cellProvider: CellProvider
        private var current = Snapshot()
        public var defaultRowAnimation: UITableView.RowAnimation = .automatic

        public init(tableView: UITableView, cellProvider: @escaping CellProvider) {
            self.tableView = tableView
            self.cellProvider = cellProvider
            super.init()
            tableView.dataSource = self
        }

        public func snapshot() -> Snapshot {
            current.clearingRefresh()
        }

        public func itemIdentifier(for indexPath: IndexPath) -> ItemIdentifierType? {
            current.item(at: indexPath)
        }

        public func indexPath(for item: ItemIdentifierType) -> IndexPath? {
            current.indexPath(of: item)
        }

        public func sectionIdentifier(for index: Int) -> SectionIdentifierType? {
            index < current.sections.count ? current.sections[index] : nil
        }

        public func index(for section: SectionIdentifierType) -> Int? {
            current.sections.firstIndex(of: section)
        }

        public func apply(_ snapshot: Snapshot, animatingDifferences: Bool = true, completion: (() -> Void)? = nil) {
            let old = current
            current = snapshot.clearingRefresh()
            guard let tableView else {
                completion?()
                return
            }
            let refreshedRows = snapshot.refreshed.compactMap { current.indexPath(of: $0) }
            let refreshedSections = IndexSet(snapshot.refreshedSections.compactMap { current.sections.firstIndex(of: $0) })
            guard tableView.window != nil, animatingDifferences, let changes = current.changes(from: old) else {
                tableView.reloadData()
                completion?()
                return
            }
            let animation = defaultRowAnimation
            CATransaction.begin()
            CATransaction.setCompletionBlock(completion)
            tableView.beginUpdates()
            if !changes.deleted.isEmpty { tableView.deleteRows(at: changes.deleted, with: animation) }
            if !changes.inserted.isEmpty { tableView.insertRows(at: changes.inserted, with: animation) }
            tableView.endUpdates()
            // made again after the batch, at their new paths, without a fade
            let visible = Set(tableView.indexPathsForVisibleRows ?? [])
            let rows = refreshedRows.filter { visible.contains($0) && !changes.inserted.contains($0) }
            if !rows.isEmpty { tableView.reloadRows(at: rows, with: .none) }
            if !refreshedSections.isEmpty { tableView.reloadSections(refreshedSections, with: .none) }
            CATransaction.commit()
        }

        /// `applySnapshotUsingReloadData(_:)`.
        public func applySnapshotUsingReloadData(_ snapshot: Snapshot, completion: (() -> Void)? = nil) {
            current = snapshot.clearingRefresh()
            tableView?.reloadData()
            completion?()
        }

        // MARK: UITableViewDataSource

        open func numberOfSections(in _: UITableView) -> Int {
            current.sections.count
        }

        open func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
            guard section < current.sections.count else { return 0 }
            return current.items[current.sections[section]]?.count ?? 0
        }

        open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let item = current.item(at: indexPath), let cell = cellProvider(tableView, indexPath, item) else {
                return UITableViewCell()
            }
            return cell
        }

        open func tableView(_: UITableView, titleForHeaderInSection _: Int) -> String? { nil }
        open func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? { nil }
        open func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool { false }
        open func tableView(_: UITableView, canMoveRowAt _: IndexPath) -> Bool { false }
        open func tableView(_: UITableView, commit _: UITableViewCell.EditingStyle, forRowAt _: IndexPath) {}

        open func tableView(_: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
            // keep the snapshot as the table now shows it
            guard let item = current.item(at: source) else { return }
            var next = current
            next.deleteItems([item])
            let section = next.sections[destination.section]
            let list = next.itemIdentifiers(inSection: section)
            if destination.row < list.count {
                next.insertItems([item], beforeItem: list[destination.row])
            } else {
                next.appendItems([item], toSection: section)
            }
            current = next
        }
    }

    // MARK: - Collection views

    open class LegacyCollectionViewDiffableDataSource<SectionIdentifierType: Hashable, ItemIdentifierType: Hashable>:
        NSObject, UICollectionViewDataSource
    {
        public typealias Snapshot = LegacyDiffableSnapshot<SectionIdentifierType, ItemIdentifierType>
        public typealias CellProvider = (UICollectionView, IndexPath, ItemIdentifierType) -> UICollectionViewCell?
        public typealias SupplementaryViewProvider = (UICollectionView, String, IndexPath) -> UICollectionReusableView?

        private weak var collectionView: UICollectionView?
        private let cellProvider: CellProvider
        private var current = Snapshot()
        public var supplementaryViewProvider: SupplementaryViewProvider?

        public init(collectionView: UICollectionView, cellProvider: @escaping CellProvider) {
            self.collectionView = collectionView
            self.cellProvider = cellProvider
            super.init()
            collectionView.dataSource = self
        }

        public func snapshot() -> Snapshot {
            current.clearingRefresh()
        }

        public func itemIdentifier(for indexPath: IndexPath) -> ItemIdentifierType? {
            current.item(at: indexPath)
        }

        public func indexPath(for item: ItemIdentifierType) -> IndexPath? {
            current.indexPath(of: item)
        }

        public func sectionIdentifier(for index: Int) -> SectionIdentifierType? {
            index < current.sections.count ? current.sections[index] : nil
        }

        public func index(for section: SectionIdentifierType) -> Int? {
            current.sections.firstIndex(of: section)
        }

        public func apply(_ snapshot: Snapshot, animatingDifferences: Bool = true, completion: (() -> Void)? = nil) {
            let old = current
            current = snapshot.clearingRefresh()
            guard let collectionView else {
                completion?()
                return
            }
            let refreshed = snapshot.refreshed.compactMap { current.indexPath(of: $0) }
            guard collectionView.window != nil, animatingDifferences, let changes = current.changes(from: old) else {
                collectionView.reloadData()
                completion?()
                return
            }
            collectionView.performBatchUpdates({
                if !changes.deleted.isEmpty { collectionView.deleteItems(at: changes.deleted) }
                if !changes.inserted.isEmpty { collectionView.insertItems(at: changes.inserted) }
            }, completion: { _ in
                let visible = Set(collectionView.indexPathsForVisibleItems)
                let items = refreshed.filter { visible.contains($0) && !changes.inserted.contains($0) }
                if !items.isEmpty {
                    UIView.performWithoutAnimation { collectionView.reloadItems(at: items) }
                }
                completion?()
            })
        }

        public func applySnapshotUsingReloadData(_ snapshot: Snapshot, completion: (() -> Void)? = nil) {
            current = snapshot.clearingRefresh()
            collectionView?.reloadData()
            completion?()
        }

        // MARK: UICollectionViewDataSource

        open func numberOfSections(in _: UICollectionView) -> Int {
            current.sections.count
        }

        open func collectionView(_: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            guard section < current.sections.count else { return 0 }
            return current.items[current.sections[section]]?.count ?? 0
        }

        open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let item = current.item(at: indexPath), let cell = cellProvider(collectionView, indexPath, item) else {
                fatalError("LegacyCollectionViewDiffableDataSource: no cell for \(indexPath)")
            }
            return cell
        }

        open func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            guard let view = supplementaryViewProvider?(collectionView, kind, indexPath) else {
                fatalError("LegacyCollectionViewDiffableDataSource: no supplementary view of kind \(kind)")
            }
            return view
        }
    }
#endif
