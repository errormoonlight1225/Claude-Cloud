//
//  AppBootstrap.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import Dog
import Foundation

/// Brings up every engine, once per process. Their state lives on the main
/// actor; each does its reading off it and returns when done. No screen
/// waits on this: the interface is up first and its pages fill in as the
/// centers announce what they read.
enum AppBootstrap {
    private static var task: LegacyTask?

    /// Called once the environment is prepared and before a scene connects.
    /// A bootstrap this build was not packaged for is never read.
    static func start() {
        guard task == nil, PackagedArchitecture.incompatibilityMessage == nil else { return }

        // read now, before a page counts updates: a blocked package is
        // never in the first count
        PackageCenter.default.restoreUpdatePreferences()

        // iOS 12 port: the reads run on this background task; everything
        // that was the main actor's between them runs on the main queue.
        task = LegacyTask.detached {
            DispatchQueue.main.sync { DeviceIdentity.applyNetworkingHeaders() }

            // MARK: - CENTER

            PackageCenter.default.load()
            RepositoryCenter.default.load()

            DispatchQueue.main.sync {
                // the first tap on Install finds the catalogue already read
                PackageQueue.shared.schedulePreflight()

                // MARK: - PRIVILEGED BACKEND

                PrivilegedBackend.start()

                // MARK: - DOWNLOAD ENGINE

                CellularPolicy.allowForThisApplication()
            }

            Downloads.shared.load()

            DispatchQueue.main.sync {
                // MARK: - PROCESSOR

                _ = Installer.shared

                isFinished = true

                // MARK: - AUTOMATIC REFRESH

                AutomaticRefresh.start()

                // MARK: - COMMAND LINE

                CommandLineChanges.observe()
            }
        }
    }

    /// False while the engines are still coming up: what they read then is
    /// fresh, and nothing needs to be read again on their account.
    private(set) static var isFinished = false

    /// Returns when the engines are up; `false` where they never start.
    /// iOS 12 port: blocks; call off the main thread.
    static nonisolated func finished() -> Bool {
        guard let task = DispatchQueue.main.sync(execute: { self.task }) else {
            Dog.shared.join("AppBootstrap", "asked for engines that were never started", level: .warning)
            return false
        }
        task.wait()
        return true
    }
}
