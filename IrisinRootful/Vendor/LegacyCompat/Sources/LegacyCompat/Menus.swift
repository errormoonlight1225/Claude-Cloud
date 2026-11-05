//
//  Menus.swift
//  LegacyCompat
//
//  UIMenu and UIAction are iOS 13, a button's or bar item's menu and
//  closure actions iOS 14. These keep their shape: a `LegacyAction` or
//  `LegacyMenu` is built where a UIAction or UIMenu was, and a menu hangs off
//  a button or a bar item. On iOS 15 and later it becomes the real UIMenu; on
//  iOS 12 to 14 a tap shows it as an action sheet, a submenu as a further
//  sheet, an inline group as its actions in place.
//

#if canImport(UIKit) && os(iOS)
    import ObjectiveC
    import UIKit

    /// What a menu holds: an action, a menu, or a menu made when shown.
    public protocol LegacyMenuElement: AnyObject {}

    public final class LegacyAction: LegacyMenuElement {
        public struct Attributes: OptionSet {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }
            public static let destructive = Attributes(rawValue: 1 << 0)
            public static let disabled = Attributes(rawValue: 1 << 1)
            public static let hidden = Attributes(rawValue: 1 << 2)
            public static let keepsMenuPresented = Attributes(rawValue: 1 << 3)
        }

        public enum State {
            case off
            case on
            case mixed
        }

        public var title: String
        public var subtitle: String?
        public var image: UIImage?
        public var attributes: Attributes
        public var state: State
        public var discoverabilityTitle: String?
        let handler: (LegacyAction) -> Void
        /// The view or bar item the menu was shown from, for a handler that
        /// presents something anchored to it.
        public internal(set) weak var sender: AnyObject?

        public init(
            title: String = "",
            subtitle: String? = nil,
            image: UIImage? = nil,
            identifier _: String? = nil,
            discoverabilityTitle: String? = nil,
            attributes: Attributes = [],
            state: State = .off,
            handler: @escaping (LegacyAction) -> Void
        ) {
            self.title = title
            self.subtitle = subtitle
            self.image = image
            self.discoverabilityTitle = discoverabilityTitle
            self.attributes = attributes
            self.state = state
            self.handler = handler
        }

        public func perform() {
            handler(self)
        }
    }

    public final class LegacyMenu: LegacyMenuElement {
        public struct Options: OptionSet {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }
            public static let displayInline = Options(rawValue: 1 << 0)
            public static let destructive = Options(rawValue: 1 << 1)
            public static let singleSelection = Options(rawValue: 1 << 2)
        }

        public var title: String
        public var subtitle: String?
        public var image: UIImage?
        public var options: Options
        public var children: [LegacyMenuElement]

        public init(
            title: String = "",
            subtitle: String? = nil,
            image: UIImage? = nil,
            identifier _: String? = nil,
            options: Options = [],
            children: [LegacyMenuElement] = []
        ) {
            self.title = title
            self.subtitle = subtitle
            self.image = image
            self.options = options
            self.children = children
        }

        public func replacingChildren(_ children: [LegacyMenuElement]) -> LegacyMenu {
            LegacyMenu(title: title, subtitle: subtitle, image: image, options: options, children: children)
        }
    }

    /// `UIDeferredMenuElement`: children made when the menu is shown.
    public final class LegacyDeferredMenuElement: LegacyMenuElement {
        let provider: (@escaping ([LegacyMenuElement]) -> Void) -> Void

        public init(_ provider: @escaping (@escaping ([LegacyMenuElement]) -> Void) -> Void) {
            self.provider = provider
        }

        public static func uncached(
            _ provider: @escaping (@escaping ([LegacyMenuElement]) -> Void) -> Void
        ) -> LegacyDeferredMenuElement {
            LegacyDeferredMenuElement(provider)
        }
    }

    // MARK: - Resolving

    extension LegacyMenu {
        /// The children with every deferred element made, synchronously when
        /// its provider answers at once (as every provider here does).
        func resolvedChildren() -> [LegacyMenuElement] {
            var resolved = [LegacyMenuElement]()
            for child in children {
                if let deferred = child as? LegacyDeferredMenuElement {
                    var made: [LegacyMenuElement]?
                    deferred.provider { made = $0 }
                    resolved += (made ?? []).flatMap { element -> [LegacyMenuElement] in
                        if let menu = element as? LegacyMenu, menu.options.contains(.displayInline) {
                            return [menu.replacingChildren(menu.resolvedChildren())]
                        }
                        return [element]
                    }
                } else {
                    resolved.append(child)
                }
            }
            return resolved
        }
    }

    // MARK: - Native menus (iOS 15 and later: uncached deferred elements)

    @available(iOS 15.0, *)
    extension LegacyMenuElement {
        func makeNative(sender: AnyObject?) -> UIMenuElement? {
            if let action = self as? LegacyAction {
                if action.attributes.contains(.hidden) { return nil }
                var attributes: UIMenuElement.Attributes = []
                if action.attributes.contains(.destructive) { attributes.insert(.destructive) }
                if action.attributes.contains(.disabled) { attributes.insert(.disabled) }
                let native = UIAction(
                    title: action.title,
                    image: action.image,
                    discoverabilityTitle: action.discoverabilityTitle ?? action.subtitle,
                    attributes: attributes,
                    state: action.state == .on ? .on : action.state == .mixed ? .mixed : .off
                ) { [weak sender] _ in
                    action.sender = sender
                    action.perform()
                }
                return native
            }
            if let menu = self as? LegacyMenu {
                return menu.makeNativeMenu(sender: sender)
            }
            if let deferred = self as? LegacyDeferredMenuElement {
                return UIDeferredMenuElement.uncached { completion in
                    deferred.provider { elements in
                        completion(elements.compactMap { $0.makeNative(sender: sender) })
                    }
                }
            }
            return nil
        }
    }

    @available(iOS 15.0, *)
    extension LegacyMenu {
        public func makeNativeMenu(sender: AnyObject?) -> UIMenu {
            var options: UIMenu.Options = []
            if self.options.contains(.displayInline) { options.insert(.displayInline) }
            if self.options.contains(.destructive) { options.insert(.destructive) }
            if self.options.contains(.singleSelection) { options.insert(.singleSelection) }
            return UIMenu(
                title: title,
                image: image,
                options: options,
                children: children.compactMap { $0.makeNative(sender: sender) }
            )
        }
    }

    // MARK: - Action sheets (iOS 12 to 14)

    public enum LegacyMenuPresenter {
        /// Shows `menu` as an action sheet from `presenter`, anchored to
        /// `sourceView` or `barButtonItem` on iPad.
        public static func present(
            _ menu: LegacyMenu,
            from presenter: UIViewController,
            sourceView: UIView? = nil,
            sourceRect: CGRect? = nil,
            barButtonItem: UIBarButtonItem? = nil
        ) {
            let children = menu.resolvedChildren()
            let title = menu.title.isEmpty ? nil : menu.title
            let sheet = UIAlertController(title: title, message: menu.subtitle, preferredStyle: .actionSheet)
            let sender: AnyObject? = barButtonItem ?? sourceView
            func add(_ elements: [LegacyMenuElement]) {
                for element in elements {
                    if let action = element as? LegacyAction {
                        guard !action.attributes.contains(.hidden) else { continue }
                        let mark = action.state == .on ? "\u{2713} " : action.state == .mixed ? "\u{2013} " : ""
                        let style: UIAlertAction.Style = action.attributes.contains(.destructive) ? .destructive : .default
                        let item = UIAlertAction(title: mark + action.title, style: style) { [weak sender] _ in
                            action.sender = sender
                            action.perform()
                        }
                        item.isEnabled = !action.attributes.contains(.disabled)
                        sheet.addAction(item)
                    } else if let submenu = element as? LegacyMenu {
                        if submenu.options.contains(.displayInline) {
                            add(submenu.resolvedChildren())
                        } else {
                            sheet.addAction(UIAlertAction(title: submenu.title + " \u{203A}", style: .default) { [weak presenter] _ in
                                guard let presenter else { return }
                                present(submenu, from: presenter, sourceView: sourceView, sourceRect: sourceRect, barButtonItem: barButtonItem)
                            })
                        }
                    }
                }
            }
            add(children)
            guard !sheet.actions.isEmpty else { return }
            sheet.addAction(UIAlertAction(title: LegacyMenuPresenter.cancelTitle, style: .cancel))
            if let popover = sheet.popoverPresentationController {
                if let barButtonItem {
                    popover.barButtonItem = barButtonItem
                } else if let sourceView {
                    popover.sourceView = sourceView
                    popover.sourceRect = sourceRect ?? sourceView.bounds
                } else {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    popover.permittedArrowDirections = []
                }
            }
            (presenter.presentedViewController ?? presenter).present(sheet, animated: true)
        }

        /// The sheet's Cancel, from the app's own strings when it has one.
        public static var cancelTitle: String {
            let missing = "\u{0}missing"
            let found = Bundle.main.localizedString(forKey: "Cancel", value: missing, table: nil)
            return found == missing ? "Cancel" : found
        }
    }

    extension UIResponder {
        /// The view controller this responder is shown by.
        public var legacyOwningViewController: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }
    }

    // MARK: - Buttons

    private var menuProviderKey: UInt8 = 0
    private var actionTargetKey: UInt8 = 0

    private final class LegacyControlTarget: NSObject {
        var handlers: [(UIControl.Event.RawValue, (UIControl) -> Void)] = []

        @objc func fire(_ control: UIControl, event: UIEvent?) {
            // every handler registered for an event this control just sent
            for (_, handler) in handlers {
                handler(control)
            }
        }
    }

    private final class LegacyMenuHolder: NSObject {
        let provider: () -> LegacyMenu?
        init(_ provider: @escaping () -> LegacyMenu?) { self.provider = provider }
    }

    extension UIControl {
        /// `addAction(UIAction(...), for:)` (iOS 14): a closure for `events`.
        public func legacyAddAction(for events: UIControl.Event = .touchUpInside, _ handler: @escaping (UIControl) -> Void) {
            let target = LegacyControlTarget()
            target.handlers.append((events.rawValue, handler))
            var targets = objc_getAssociatedObject(self, &actionTargetKey) as? [LegacyControlTarget] ?? []
            targets.append(target)
            objc_setAssociatedObject(self, &actionTargetKey, targets, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            addTarget(target, action: #selector(LegacyControlTarget.fire(_:event:)), for: events)
        }

        /// Removes every closure `legacyAddAction` added.
        public func legacyRemoveActions() {
            for target in objc_getAssociatedObject(self, &actionTargetKey) as? [LegacyControlTarget] ?? [] {
                removeTarget(target, action: nil, for: .allEvents)
            }
            objc_setAssociatedObject(self, &actionTargetKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    extension UIButton {
        /// `menu` with `showsMenuAsPrimaryAction`: the menu `provider` makes
        /// is shown on a tap, made again each time (as `uncached` was).
        public func legacySetMenu(_ provider: @escaping () -> LegacyMenu?) {
            let holder = LegacyMenuHolder(provider)
            let firstTime = objc_getAssociatedObject(self, &menuProviderKey) == nil
            objc_setAssociatedObject(self, &menuProviderKey, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if #available(iOS 15.0, *) {
                if let menu = provider() {
                    self.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                        let current = (objc_getAssociatedObject(self as Any, &menuProviderKey) as? LegacyMenuHolder)?.provider() ?? menu
                        completion(current.makeNativeMenu(sender: self).children)
                    }])
                    showsMenuAsPrimaryAction = true
                }
                return
            }
            guard firstTime else { return }
            legacyAddAction(for: .touchUpInside) { control in
                guard let button = control as? UIButton,
                      let holder = objc_getAssociatedObject(button, &menuProviderKey) as? LegacyMenuHolder,
                      let menu = holder.provider(),
                      let presenter = button.legacyOwningViewController
                else { return }
                LegacyMenuPresenter.present(menu, from: presenter, sourceView: button)
            }
        }

        /// A fixed menu.
        public func legacySetMenu(_ menu: LegacyMenu?) {
            legacySetMenu { menu }
        }
    }

    // MARK: - Bar button items

    private final class LegacyBarTarget: NSObject {
        let handler: (UIBarButtonItem) -> Void
        init(_ handler: @escaping (UIBarButtonItem) -> Void) { self.handler = handler }
        @objc func fire(_ item: UIBarButtonItem) { handler(item) }
    }

    private var barTargetKey: UInt8 = 0

    extension UIBarButtonItem {
        /// `UIBarButtonItem(title:image:primaryAction:)` (iOS 14).
        public convenience init(
            legacyTitle title: String? = nil,
            image: UIImage? = nil,
            style: UIBarButtonItem.Style = .plain,
            handler: @escaping (UIBarButtonItem) -> Void
        ) {
            let target = LegacyBarTarget(handler)
            if let image {
                self.init(image: image, style: style, target: target, action: #selector(LegacyBarTarget.fire(_:)))
                self.title = title
                accessibilityLabel = title
            } else {
                self.init(title: title, style: style, target: target, action: #selector(LegacyBarTarget.fire(_:)))
            }
            objc_setAssociatedObject(self, &barTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        /// `UIBarButtonItem(systemItem:primaryAction:)` (iOS 14).
        public convenience init(legacySystemItem item: UIBarButtonItem.SystemItem, handler: @escaping (UIBarButtonItem) -> Void) {
            let target = LegacyBarTarget(handler)
            self.init(barButtonSystemItem: item, target: target, action: #selector(LegacyBarTarget.fire(_:)))
            objc_setAssociatedObject(self, &barTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        /// `UIBarButtonItem(title:image:menu:)` (iOS 14): a tap shows the
        /// menu `provider` makes.
        public convenience init(
            legacyTitle title: String? = nil,
            image: UIImage? = nil,
            menu provider: @escaping () -> LegacyMenu?
        ) {
            self.init(legacyTitle: title, image: image) { item in
                guard let menu = provider(), let presenter = item.legacyPresenter else { return }
                LegacyMenuPresenter.present(menu, from: presenter, barButtonItem: item)
            }
            if #available(iOS 15.0, *), let menu = provider() {
                self.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                    completion((provider() ?? menu).makeNativeMenu(sender: self).children)
                }])
                // the menu shows on a tap, as `primaryAction` was nil there
                target = nil
                action = nil
            }
        }

        /// Replaces the handler a `legacyTitle:` item runs.
        public func legacySetHandler(_ handler: @escaping (UIBarButtonItem) -> Void) {
            let newTarget = LegacyBarTarget(handler)
            target = newTarget
            action = #selector(LegacyBarTarget.fire(_:))
            objc_setAssociatedObject(self, &barTargetKey, newTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        /// The view controller a bar item belongs to: the top one of the key
        /// window's hierarchy, which is the one whose bar is on screen.
        var legacyPresenter: UIViewController? {
            var top = UIApplication.shared.keyWindow?.rootViewController
            while let presented = top?.presentedViewController, !(presented is UIAlertController) {
                top = presented
            }
            return top
        }
    }

    // MARK: - Context menus

    private var contextMenuKey: UInt8 = 0

    private final class LegacyLongPressTarget: NSObject {
        let provider: (CGPoint) -> LegacyMenu?
        init(_ provider: @escaping (CGPoint) -> LegacyMenu?) { self.provider = provider }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            guard let menu = provider(point), let presenter = view.legacyOwningViewController else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            LegacyMenuPresenter.present(menu, from: presenter, sourceView: view, sourceRect: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        }
    }

    extension UIView {
        /// A context menu for iOS 12: a long press shows the menu
        /// `provider` makes for the point pressed, as an action sheet.
        public func legacyAddContextMenu(_ provider: @escaping (CGPoint) -> LegacyMenu?) {
            let target = LegacyLongPressTarget(provider)
            let recognizer = UILongPressGestureRecognizer(target: target, action: #selector(LegacyLongPressTarget.pressed(_:)))
            addGestureRecognizer(recognizer)
            var targets = objc_getAssociatedObject(self, &contextMenuKey) as? [LegacyLongPressTarget] ?? []
            targets.append(target)
            objc_setAssociatedObject(self, &contextMenuKey, targets, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
#endif
