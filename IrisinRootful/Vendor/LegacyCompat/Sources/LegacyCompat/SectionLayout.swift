//
//  SectionLayout.swift
//  LegacyCompat
//
//  Compositional layouts are iOS 13 and list sections iOS 14. What the app
//  asks of them is a column of full-width rows, a grid of fixed-size items,
//  and a header and a footer per section; this lays out exactly that, from a
//  provider asked per section, as a compositional layout's is. A row or a
//  supplementary view with an estimated height is measured by Auto Layout
//  (self-sizing), as a list section's are.
//

#if canImport(UIKit) && os(iOS)
    import UIKit

    public struct LegacyLayoutSection {
        public enum Height {
            case absolute(CGFloat)
            case estimated(CGFloat)

            var value: CGFloat {
                switch self {
                case let .absolute(v), let .estimated(v): v
                }
            }

            var selfSizing: Bool {
                if case .estimated = self { return true }
                return false
            }
        }

        public enum Items {
            /// One full-width row per item.
            case rows(Height)
            /// Items of a fixed size, as many to a line as fit, the width
            /// left over spread between them.
            case grid(CGSize)
        }

        public var items: Items
        public var insets: UIEdgeInsets
        /// Between two lines of items.
        public var lineSpacing: CGFloat
        /// nil: no header.
        public var header: Height?
        public var footer: Height?
        /// Headers and footers span the content width (true) or sit within
        /// the section's own insets (false).
        public var supplementariesIgnoreInsets: Bool

        public init(
            items: Items,
            insets: UIEdgeInsets = .zero,
            lineSpacing: CGFloat = 0,
            header: Height? = nil,
            footer: Height? = nil,
            supplementariesIgnoreInsets: Bool = true
        ) {
            self.items = items
            self.insets = insets
            self.lineSpacing = lineSpacing
            self.header = header
            self.footer = footer
            self.supplementariesIgnoreInsets = supplementariesIgnoreInsets
        }
    }

    open class LegacySectionLayout: UICollectionViewLayout {
        /// The section's layout for a content width.
        public var sectionProvider: (Int, CGFloat) -> LegacyLayoutSection?

        private var cells: [IndexPath: UICollectionViewLayoutAttributes] = [:]
        private var supplementaries: [String: [IndexPath: UICollectionViewLayoutAttributes]] = [:]
        private var contentHeight: CGFloat = 0
        private var preparedWidth: CGFloat = -1
        /// Heights measured by self-sizing, kept across passes.
        private var measured: [String: CGFloat] = [:]

        public init(sectionProvider: @escaping (Int, CGFloat) -> LegacyLayoutSection?) {
            self.sectionProvider = sectionProvider
            super.init()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) { fatalError() }

        private static func key(_ kind: String, _ path: IndexPath) -> String {
            "\(kind)|\(path.section)|\(path.item)"
        }

        override open func prepare() {
            super.prepare()
            guard let collectionView else { return }
            cells.removeAll()
            supplementaries.removeAll()
            let insets = collectionView.adjustedContentInset
            let width = collectionView.bounds.width - insets.left - insets.right
            preparedWidth = collectionView.bounds.width
            var y: CGFloat = 0
            for section in 0 ..< collectionView.numberOfSections {
                guard let layout = sectionProvider(section, width) else { continue }
                let count = collectionView.numberOfItems(inSection: section)
                let sectionPath = IndexPath(item: 0, section: section)
                let supplementaryX = layout.supplementariesIgnoreInsets ? 0 : layout.insets.left
                let supplementaryWidth = layout.supplementariesIgnoreInsets
                    ? width : width - layout.insets.left - layout.insets.right
                if let header = layout.header {
                    let kind = UICollectionView.elementKindSectionHeader
                    let height = header.selfSizing ? (measured[Self.key(kind, sectionPath)] ?? header.value) : header.value
                    let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: sectionPath)
                    attributes.frame = CGRect(x: supplementaryX, y: y, width: supplementaryWidth, height: height)
                    attributes.zIndex = 1
                    supplementaries[kind, default: [:]][sectionPath] = attributes
                    y += height
                }
                y += layout.insets.top
                let available = width - layout.insets.left - layout.insets.right
                switch layout.items {
                case let .rows(height):
                    for item in 0 ..< count {
                        let path = IndexPath(item: item, section: section)
                        let h = height.selfSizing ? (measured[Self.key("cell", path)] ?? height.value) : height.value
                        let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
                        attributes.frame = CGRect(x: layout.insets.left, y: y, width: available, height: h)
                        cells[path] = attributes
                        y += h + (item < count - 1 ? layout.lineSpacing : 0)
                    }
                case let .grid(size):
                    let perLine = max(1, Int((available + 0.5) / max(size.width, 1)))
                    let spare = available - CGFloat(perLine) * size.width
                    let gap = perLine > 1 ? spare / CGFloat(perLine - 1) : 0
                    var item = 0
                    while item < count {
                        for column in 0 ..< perLine where item < count {
                            let path = IndexPath(item: item, section: section)
                            let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
                            attributes.frame = CGRect(
                                x: layout.insets.left + CGFloat(column) * (size.width + gap),
                                y: y,
                                width: size.width,
                                height: size.height
                            )
                            cells[path] = attributes
                            item += 1
                        }
                        y += size.height + (item < count ? layout.lineSpacing : 0)
                    }
                }
                y += layout.insets.bottom
                if let footer = layout.footer {
                    let kind = UICollectionView.elementKindSectionFooter
                    let height = footer.selfSizing ? (measured[Self.key(kind, sectionPath)] ?? footer.value) : footer.value
                    let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: sectionPath)
                    attributes.frame = CGRect(x: supplementaryX, y: y, width: supplementaryWidth, height: height)
                    supplementaries[kind, default: [:]][sectionPath] = attributes
                    y += height
                }
            }
            contentHeight = y
        }

        override open var collectionViewContentSize: CGSize {
            guard let collectionView else { return .zero }
            let insets = collectionView.adjustedContentInset
            return CGSize(width: collectionView.bounds.width - insets.left - insets.right, height: contentHeight)
        }

        override open func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            var result = cells.values.filter { $0.frame.intersects(rect) }
            for group in supplementaries.values {
                result += group.values.filter { $0.frame.intersects(rect) }
            }
            return result
        }

        override open func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            cells[indexPath]
        }

        override open func layoutAttributesForSupplementaryView(
            ofKind elementKind: String,
            at indexPath: IndexPath
        ) -> UICollectionViewLayoutAttributes? {
            supplementaries[elementKind]?[indexPath]
        }

        override open func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
            newBounds.width != preparedWidth
        }

        // MARK: Self-sizing

        private func isSelfSizing(_ attributes: UICollectionViewLayoutAttributes) -> Bool {
            guard let layout = sectionProvider(attributes.indexPath.section, collectionViewContentSize.width) else { return false }
            switch attributes.representedElementCategory {
            case .cell:
                if case let .rows(height) = layout.items { return height.selfSizing }
                return false
            case .supplementaryView:
                if attributes.representedElementKind == UICollectionView.elementKindSectionHeader {
                    return layout.header?.selfSizing ?? false
                }
                return layout.footer?.selfSizing ?? false
            default:
                return false
            }
        }

        override open func shouldInvalidateLayout(
            forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
            withOriginalAttributes original: UICollectionViewLayoutAttributes
        ) -> Bool {
            guard isSelfSizing(original) else { return false }
            let kind = original.representedElementCategory == .cell ? "cell" : (original.representedElementKind ?? "")
            let key = Self.key(kind, original.indexPath)
            let height = ceil(preferred.frame.height)
            guard abs((measured[key] ?? original.frame.height) - height) > 0.5 else { return false }
            measured[key] = height
            return true
        }

        override open func invalidationContext(
            forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
            withOriginalAttributes original: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutInvalidationContext {
            let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
            context.contentSizeAdjustment = CGSize(width: 0, height: preferred.frame.height - original.frame.height)
            return context
        }

        /// Forgets measured heights, for content that changed in place.
        public func invalidateMeasurements() {
            measured.removeAll()
            invalidateLayout()
        }
    }

    /// Asks a cell or supplementary view to size itself to the layout's
    /// width, which self-sizing in a custom layout needs: the cell's content
    /// view is laid out by Auto Layout at the proposed width.
    open class LegacySelfSizingCell: UICollectionViewCell {
        override open func preferredLayoutAttributesFitting(
            _ layoutAttributes: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutAttributes {
            let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
            let size = contentView.systemLayoutSizeFitting(
                CGSize(width: layoutAttributes.frame.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            attributes.frame.size.height = ceil(size.height)
            return attributes
        }
    }

    open class LegacySelfSizingReusableView: UICollectionReusableView {
        override open func preferredLayoutAttributesFitting(
            _ layoutAttributes: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutAttributes {
            let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
            let size = systemLayoutSizeFitting(
                CGSize(width: layoutAttributes.frame.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            attributes.frame.size.height = ceil(size.height)
            return attributes
        }
    }
#endif

#if canImport(UIKit) && os(iOS)
    /// What a list cell shows at its trailing edge (`UICellAccessory`, iOS 14).
    public struct LegacyCellAccessory {
        enum Kind { case disclosure, checkmark }
        let kind: Kind
        public static func disclosureIndicator() -> LegacyCellAccessory { LegacyCellAccessory(kind: .disclosure) }
        public static func checkmark() -> LegacyCellAccessory { LegacyCellAccessory(kind: .checkmark) }
    }

    /// `UICollectionViewListCell` for iOS 12: a self-sizing cell that draws
    /// a list content configuration, on the grouped list's card ground,
    /// with a trailing accessory.
    open class LegacyListCell: LegacySelfSizingCell {
        private let accessoryView = UIImageView()
        private var trailingConstraint: NSLayoutConstraint?

        public var accessories: [LegacyCellAccessory] = [] {
            didSet { updateAccessory() }
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .compatSecondarySystemGroupedBackground
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.contentMode = .center
            accessoryView.tintColor = .compatTertiaryLabel
            contentView.addSubview(accessoryView)
            NSLayoutConstraint.activate([
                accessoryView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                accessoryView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
            contentView.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) { fatalError() }

        private func updateAccessory() {
            switch accessories.first?.kind {
            case .disclosure?:
                accessoryView.image = UIImage.compatSystemImage("chevron.right", withConfiguration: LegacySymbolConfiguration(pointSize: 13, weight: .semibold))
                accessoryView.tintColor = .compatTertiaryLabel
            case .checkmark?:
                accessoryView.image = UIImage.compatSystemImage("checkmark", withConfiguration: LegacySymbolConfiguration(pointSize: 15, weight: .semibold))
                accessoryView.tintColor = tintColor
            case nil:
                accessoryView.image = nil
            }
            contentView.layoutMargins.right = accessories.isEmpty ? 16 : 40
        }

        override open var isHighlighted: Bool {
            didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
        }
    }
#endif
