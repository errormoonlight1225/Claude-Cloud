//
//  ReentrantInit.swift
//  LegacyCompat
//
//  iOS 12's UITableViewController.init(style:),
//  UICollectionViewController.init(collectionViewLayout:) and
//  UINavigationController.init(rootViewController:) call
//  -initWithNibName:bundle: on self. A Swift subclass with designated
//  initializers of its own does not inherit init(nibName:bundle:): the
//  compiler gives it a stub that traps ("Use of unimplemented initializer"),
//  and the app stopped at the first such controller. iOS 13 no longer makes
//  that call.
//
//  A subclass that can is better off overriding init(nibName:bundle:) to call
//  super. One whose stored properties have no default values cannot, and is
//  listed here: its stub is replaced with the superclass's implementation,
//  which is what such an override would run. Its own properties were set
//  before it called super.init, so nothing is left uninitialized.
//

#if canImport(UIKit) && os(iOS)
    import ObjectiveC
    import UIKit

    public enum LegacyReentrantInit {
        /// Call before any of `classes` is created, on iOS 12 only.
        public static func inheritNibInitializer(_ classes: [UIViewController.Type]) {
            if #available(iOS 13.0, *) { return }
            let selector = #selector(UIViewController.init(nibName:bundle:))
            for type in classes {
                let cls: AnyClass = type
                guard let superclass = class_getSuperclass(cls),
                      let inherited = class_getInstanceMethod(superclass, selector)
                else { continue }
                class_replaceMethod(
                    cls,
                    selector,
                    method_getImplementation(inherited),
                    method_getTypeEncoding(inherited)
                )
            }
        }
    }
#endif
