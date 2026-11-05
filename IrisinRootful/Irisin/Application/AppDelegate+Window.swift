//
//  AppDelegate+Window.swift
//  Irisin
//
//  iOS 12 port: iOS 12 has no scenes, so what SceneDelegate did (the
//  window, links and files handed to the app, becoming active, going to
//  the background) is the app delegate's. The app uses this on every iOS
//  it runs on: the Info.plist declares no scene manifest.
//

import AptRepository
import Dog
import LegacyCompat
import UIKit

extension AppDelegate {
    /// The window and its root, from `didFinishLaunching`.
    func makeWindow(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window

        guard PackagedArchitecture.incompatibilityMessage == nil else {
            window.rootViewController = UnsupportedArchitectureController()
            window.makeKeyAndVisible()
            return
        }

        // The interface is the root from the first frame: a tab bar that
        // arrives later, over a loading screen, draws itself in as it comes.
        window.rootViewController = InterfaceHostController()
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        finishOwnRegistrationIfStale()

        if let url = launchOptions?[.url] as? URL {
            let inPlace = false
            DispatchQueue.main.async { self.open(url, inPlace: inPlace) }
        }
    }

    func application(_: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard PackagedArchitecture.incompatibilityMessage == nil else { return false }
        open(url, inPlace: (options[.openInPlace] as? Bool) ?? false)
        return true
    }

    func application(
        _: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler _: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.title == NSUserActivity.dropPackageActivityType,
              let data = userActivity.userInfo?["attach"] as? Data,
              let package = Package.propertyListDecoded(with: data)
        else {
            Dog.shared.join(self, "failed to restore from \(userActivity)", level: .warning)
            return false
        }
        whenInterfaceIsReady { interface in
            interface.pageStack?.pushViewController(PackageController(package: package), animated: true)
        }
        return true
    }

    func applicationDidBecomeActive(_: UIApplication) {
        guard PackagedArchitecture.incompatibilityMessage == nil else { return }
        Dog.shared.join(self, "applicationDidBecomeActive", level: .info)
        // at launch the first read is `load()`'s own, and a second one right
        // behind it reads the same file
        guard AppBootstrap.isFinished else { return }
        reloadThrottle.throttle {
            LegacyTask.detached {
                PackageCenter.default.reloadLocalPackages()
            }
        }
        // back after a while away: what went out of date meanwhile is
        // refreshed now, not at the next minute's look
        AutomaticRefresh.check()
    }

    /// A repository added, changed or deleted a moment ago is written behind
    /// whatever refresh holds the database: the app stays up until it is,
    /// or the next launch reads the repositories as they were.
    func applicationDidEnterBackground(_ application: UIApplication) {
        let background = BackgroundTask()
        background.identifier = application.beginBackgroundTask(withName: "RepositoryWrites") {
            background.end()
        }
        LegacyTask.detached {
            RepositoryCenter.default.writesLanded()
            DispatchQueue.main.async { background.end() }
        }
    }

    // MARK: - Links and files

    private func open(_ url: URL, inPlace: Bool) {
        if url.isFileURL {
            open(file: url, inPlace: inPlace)
            return
        }
        guard let link = IrisinLink(url) else {
            Dog.shared.join(self, "refused link \(url.absoluteString)", level: .warning)
            presentNotice(title: "Unable to Open Link", message: "This link is not valid.")
            return
        }
        Dog.shared.join(self, "opening link \(url.absoluteString)")
        switch link {
        case let .addRepositories(sources): openQuickAddRepo(sources)
        case let .package(identity): openPackage(identity)
        }
    }

    /// Runs `body` on the main queue with the interface, once the engines
    /// are up, so what is opened in it finds the repositories and packages
    /// it asks for. Nothing where the interface never opens.
    private func whenInterfaceIsReady(_ body: @escaping (InterfaceHostController) -> Void) {
        LegacyTask.detached {
            guard AppBootstrap.finished() else { return }
            DispatchQueue.main.async {
                guard let interface = self.window?.rootViewController as? InterfaceHostController else { return }
                body(interface)
            }
        }
    }

    private func openQuickAddRepo(_ sources: [RepositorySource]) {
        whenInterfaceIsReady { interface in
            // a sheet the user has open stays, with this one over it
            (interface.presentedViewController ?? interface)
                .present(RepositoryAddController.sheet(candidates: sources, origin: .link), animated: true)
        }
    }

    /// The package as the newest repository offers it, else what dpkg reports
    /// is installed. A link to a package no added repository has opens
    /// nothing: there is no page to show, and a blank one would be a lie.
    private func openPackage(_ identity: String) {
        whenInterfaceIsReady { interface in
            let center = PackageCenter.default
            let offered = center.newestPackage(
                of: Array(center.obtainPackageSummary(with: identity).values),
                preferring: center.obtainInstallOrigin(of: identity)?.repoRef
            )
            guard let package = offered
                ?? center.obtainInstalledPackageList().first(where: { $0.identity == identity })
            else {
                (interface.presentedViewController ?? interface).presentNotice(
                    title: "Package Not Found",
                    message: "No added repository offers “\(identity)”. Add the repository that has it, then try again."
                )
                return
            }
            interface.pageStack?.pushViewController(PackageController(package: package), animated: true)
        }
    }

    /// A file the system handed us, by what it is rather than by its name.
    /// Opened in place it is still the user's own file, sitting in Files: it
    /// is read through a security scope and never moved.
    private func open(file url: URL, inPlace: Bool) {
        switch IrisinFileType(url: url) {
        case .irisinRepositoryList, .irisinRepository:
            importRepositories(from: url)
        case .debArchive:
            openQuickInstall(url: url, inPlace: inPlace)
        case nil:
            Dog.shared.join(self, "refused file \(url.lastPathComponent)", level: .warning)
            presentNotice(title: "Unable to Open Link", message: "This link is not valid.")
        }
    }

    private func importRepositories(from url: URL) {
        LegacyTask.detached {
            guard let data = Self.read(url),
                  let sources = try? RepositoryListFile.sources(in: data)
            else {
                DispatchQueue.main.async {
                    self.presentNotice(title: "Unable to Import", message: "This file could not be read. Choose another file.")
                }
                return
            }
            // what is already added is known once the repositories are read
            DispatchQueue.main.async {
                self.whenInterfaceIsReady { interface in
                    let registered = Set(RepositoryCenter.default.obtainRepositoryUrls())
                    let fresh = sources.filter { !registered.contains($0.url) }
                    guard !fresh.isEmpty else {
                        interface.presentNotice(title: "Nothing to Import", message: "This file has no new repositories to add.")
                        return
                    }
                    (interface.presentedViewController ?? interface)
                        .present(RepositoryAddController.sheet(candidates: fresh, origin: .file), animated: true)
                }
            }
        }
    }

    /// The file's bytes. Opened in place from iCloud Drive, it may have to
    /// download first; an inbox copy is read at once.
    private static func read(_ url: URL) -> Data? {
        do {
            return try url.readingCoordinated { try Data(contentsOf: $0) }
        } catch {
            Dog.shared.join("AppDelegate", "can not read \(url.path): \(error)", level: .error)
            return nil
        }
    }

    private func openQuickInstall(url: URL, inPlace: Bool) {
        whenInterfaceIsReady { interface in
            let target = DebOpenController()
            target.patternLocation = url
            target.openedInPlace = inPlace
            interface.pageStack?.pushViewController(target, animated: true)
        }
    }

    /// An update that stopped the app before it asked for its own
    /// registration is finished once the daemon answers (`OwnRegistration`).
    private func finishOwnRegistrationIfStale() {
        PrivilegedBackend.whenBackendIsKnown { [weak self] backend in
            guard backend.isPrivileged else { return }
            self?.whenInterfaceIsReady { interface in
                OwnRegistration.finishIfStale(from: interface.presentedViewController ?? interface)
            }
        }
    }

    /// An alert waits for the interface the same way a page does.
    private func presentNotice(title: LegacyLocalizationValue, message: LegacyLocalizationValue) {
        whenInterfaceIsReady { interface in
            (interface.presentedViewController ?? interface).presentNotice(title: title, message: message)
        }
    }
}

/// One background task's identifier, ended once whichever of the work and
/// the system's deadline comes first.
final class BackgroundTask {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
