//
//  AppDelegate.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/17.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AlertController
import AptRepository
import OpenCombine
import OpenCombineDispatch
import OpenCombineFoundation
import Dog
import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var repositoryUpdateSubscription: AnyCancellable?
    let reloadThrottle = Throttler(minimumDelay: 0.5)

    /// possible fix for some tweak crashing on something isn't my problem actually
    /// -[irisin.AppDelegate window]: unrecognized selector sent to instance
    var window: UIWindow?

    func application(
        _: UIApplication,
        willFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppEnvironment.prepare()
        return true
    }

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        observeRepositoryUpdates()

        // before the first table, label or scene exists
        #if !DEBUG
            UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        #endif
        if #available(iOS 15.0, *) { UITableView.appearance().sectionHeaderTopPadding = 0.0 }
        adoptDynamicTypeEverywhere()

        AppBootstrap.start()

        // the promoted button is the app's accent; red is kept for the
        // confirmations that destroy something
        AlertControllerConfiguration.accentColor = .buttonNormal
        // every alert wears the app icon, read from the bundle's own icon
        // entry so it follows whatever Icon Composer renders
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        if let name = (primary?["CFBundleIconFiles"] as? [String])?.last {
            AlertControllerConfiguration.alertImage = UIImage(named: name)
        }

        // iOS 12 port: the window is the app delegate's (AppDelegate+Window)
        makeWindow(launchOptions: launchOptions)
        return true
    }

    func applicationWillTerminate(_: UIApplication) {
        UIApplication.gracefullyTerminate()
    }
}

extension UIApplication {
    static func gracefullyTerminate() {
        Dog.shared.join("Terminator", "calling gracefully terminate", level: .warning)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    static func prepareForExitAndSuspend() {
        UIApplication.gracefullyTerminate()
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }
}
