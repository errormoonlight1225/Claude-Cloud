//
//  Installer.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptRepository
import AptResolver
import Dog
import Foundation
import IrisinProtocol

/// Turns one solved plan into one package transaction and runs it through
/// the privileged helper. One operation at a time; the plan is read on the
/// main actor and the files are staged off it. A running operation is an
/// `OperationMonitor`, which the console binds to.
final class Installer {
    nonisolated static let shared = Installer()

    nonisolated let workingLocation: URL
    private(set) var inProcessingQueue = false

    private init() {
        workingLocation = documentsDirectory.appendingPathComponent("Installer")
        try? Self.reset(workingLocation)
    }

    /// Copies every download the plan installs into the staging directory.
    /// nil when a download is missing, the copy failed, or an operation is
    /// already running out of that directory.
    nonisolated func createOperationPayload(
        plan: ResolutionPlan,
        ignoreScriptFailures: Bool = false,
        bootstrapInstall: Bool = false
    ) -> OperationPayload? {
        // iOS 12 port: runs on a background thread; the installer's and the
        // queue's state are the main thread's
        let reserved = DispatchQueue.main.sync { () -> Bool in
            guard !inProcessingQueue else { return false }
            // Reserve staging across the copies; a second tap must not erase
            // the first payload's files. Each confirmed plan has a separate
            // directory.
            inProcessingQueue = true
            PackageQueue.shared.operationBegan()
            return true
        }
        guard reserved else {
            Dog.shared.join(self, "refusing to stage a payload while an operation runs", level: .warning)
            return nil
        }
        defer { DispatchQueue.main.sync { inProcessingQueue = false } }
        var sources: [(Package, URL)] = []
        do {
            guard try PackageQueue.currency(of: plan, index: DispatchQueue.main.sync { PackageCenter.default.index }) == .current else {
                // read again, so the queue is solved against what moved and
                // Retry stages that plan, not this one again
                PackageCenter.default.reloadLocalPackages()
                DispatchQueue.main.sync { PackageQueue.shared.solveAgainNow() }
                throw ResolutionFailure(message: String(legacyLocalized: "Packages changed. Review the changes and try again."))
            }
            for package in plan.install {
                var file = package.localFileURL
                if file == nil {
                    file = Downloads.shared.downloadedFile(for: package)
                }
                guard let file else {
                    throw MissingDownload(identity: package.identity)
                }
                sources.append((package, file))
            }
            let install = try Self.stage(sources, at: workingLocation.appendingPathComponent(plan.id.uuidString))
            // checked again after staging, which takes a while
            guard try PackageQueue.currency(of: plan, index: DispatchQueue.main.sync { PackageCenter.default.index }) == .current else {
                PackageCenter.default.reloadLocalPackages()
                DispatchQueue.main.sync { PackageQueue.shared.solveAgainNow() }
                throw ResolutionFailure(
                    message: String(legacyLocalized: "Packages changed while preparing the installation. Try again.")
                )
            }
            let installing = Set(install.map(\.identity))
            let configuring = Set(plan.stages.flatMap { stage -> [String] in
                if case let .configure(names) = stage {
                    return names
                }
                return []
            })
            let transaction = InstallerJob.Transaction(
                install: install,
                remove: plan.remove.map(\.identity),
                stages: plan.stages,
                configureExisting: configuring.subtracting(installing).sorted(),
                autoInstalled: plan.autoInstalled,
                statusDigest: plan.snapshot.statusDigest,
                // read now, not when the plan was solved: a switch turned
                // off since then has the helper refuse the removal
                allowSystemRemoval: DispatchQueue.main.sync { PackageQueue.shared.allowSystemRemoval },
                ignoreScriptFailures: ignoreScriptFailures,
                recoveryMode: plan.recoveryMode,
                bootstrapInstall: bootstrapInstall
            )
            try InstallerJob.transaction(transaction).validate()
            return OperationPayload(plan: plan, transaction: transaction)
        } catch let missing as MissingDownload {
            // not a resolution problem: the plan is fine, the file is not
            // there. The caller asks for it again.
            DispatchQueue.main.sync { PackageActionReport.shared.clear() }
            Dog.shared.join(self, "download for \(missing.identity) is missing, not staging", level: .warning)
            return nil
        } catch let mismatch as ArchiveMismatch {
            // the file is whole and the listing is wrong: rejected before the
            // helper hears of it, and said out loud, since Retry cannot fix it
            DispatchQueue.main.sync { PackageActionReport.shared.clear() }
            DispatchQueue.main.sync { PackageActionReport.shared.record(
                mismatch.report,
                alertTitle: String(legacyLocalized: "Package Does Not Match Repository")
            ) }
            Dog.shared.join(self, "refusing to install: \(mismatch)", level: .error)
            return nil
        } catch {
            // this attempt's reason, not every attempt's
            DispatchQueue.main.sync { PackageActionReport.shared.clear() }
            DispatchQueue.main.sync { PackageActionReport.shared.record(
                (error as? ResolutionFailure)?.message
                    ?? String(legacyLocalized: "Unable to prepare the installation. Try again.")
            ) }
            Dog.shared.join(self, "Cannot prepare transaction: \(error)", level: .error)
            return nil
        }
    }

    /// Stages one local package without asking the resolver to choose or
    /// reject anything around it. The installer still validates the archive
    /// and protects file ownership;
    /// package relationships are bypassed and maintainer-script failures are
    /// tolerated by the resulting transaction.
    nonisolated func createRecoveryOperationPayload(package: Package) -> OperationPayload? {
        guard package.localFileURL != nil,
              package.isSupportedOnDevice
        else {
            DispatchQueue.main.sync { PackageActionReport.shared.clear() }
            DispatchQueue.main.sync { PackageActionReport.shared.record(
                String(legacyLocalized: "This package cannot be installed in Recovery Mode on this system.")
            ) }
            return nil
        }
        do {
            let plan = try Self.recoveryPlan(
                for: package,
                index: DispatchQueue.main.sync { PackageCenter.default.index }
            )
            return createOperationPayload(plan: plan)
        } catch {
            DispatchQueue.main.sync { PackageActionReport.shared.clear() }
            DispatchQueue.main.sync { PackageActionReport.shared.record(
                String(legacyLocalized: "Unable to prepare the installation. Try again.")
            ) }
            Dog.shared.join(self, "Cannot prepare recovery transaction: \(error)", level: .error)
            return nil
        }
    }

    nonisolated func createRecoveryRemovalPayload(identity: String) -> OperationPayload? {
        do {
            let (index, allowSystemRemoval) = DispatchQueue.main.sync {
                (PackageCenter.default.index, PackageQueue.shared.allowSystemRemoval)
            }
            let plan = try Self.recoveryRemovalPlan(
                identity: identity,
                index: index,
                allowSystemRemoval: allowSystemRemoval
            )
            return createOperationPayload(plan: plan)
        } catch {
            DispatchQueue.main.sync { PackageActionReport.shared.clear() }
            if let failure = error as? ResolutionFailure {
                DispatchQueue.main.sync { PackageActionReport.shared.record(failure.message, checks: failure.checks) }
            } else {
                DispatchQueue.main.sync { PackageActionReport.shared.record(String(legacyLocalized: "Unable to prepare this operation. Try again.")) }
            }
            return nil
        }
    }

    private nonisolated static func recoveryRemovalPlan(
        identity: String,
        index: PackageIndex,
        allowSystemRemoval: Bool
    ) throws -> ResolutionPlan {
        try .recoveryRemoval(of: identity, in: index.resolutionSnapshot(), allowSystemRemoval: allowSystemRemoval)
    }

    /// A queued package whose file is not on disk: resumed, not diagnosed.
    private struct MissingDownload: Error {
        let identity: String
    }

    private nonisolated static func stage(
        _ sources: [(Package, URL)],
        at location: URL
    ) throws -> [InstallerJob.Transaction.Item] {
        try reset(location)
        var result: [InstallerJob.Transaction.Item] = []
        for (package, source) in sources {
            let destination = location.appendingPathComponent(package.identity + ".deb")
            try FileManager.default.copyItem(at: source, to: destination)
            let digest = try package.validateArchive(at: destination)
            let prepared = location.appendingPathComponent(package.identity + ".contents")
            let manifestDigest = try ArchiveStream.prepareDebianPackage(at: destination, in: prepared)
            result.append(.init(
                identity: package.identity,
                path: destination.path,
                sha256: digest,
                preparedPath: prepared.path,
                preparedSHA256: manifestDigest
            ))
        }
        return result
    }

    private nonisolated static func recoveryPlan(
        for package: Package,
        index: PackageIndex
    ) throws -> ResolutionPlan {
        try .recoveryInstallation(of: package, in: index.resolutionSnapshot())
    }

    /// Runs the whole transaction through `irisin-install` as root. The
    /// returned monitor publishes the helper's events as they arrive and the
    /// outcome once the installed list has been reloaded; the console binds
    /// to it. The helper holds the compatible database locks and installs
    /// the package files in a session of its own, so a package that replaces
    /// this app still installs to the end.
    func beginOperation(operation: OperationPayload) -> OperationMonitor {
        let monitor = OperationMonitor(operation: operation)
        guard !inProcessingQueue else {
            Dog.shared.join(self, "refusing to begin an operation while one runs", level: .warning)
            let reason = String(
                legacyLocalized: "Another operation is already running. Wait for it to finish, then try again."
            )
            monitor.finish(.failed(reason))
            return monitor
        }
        inProcessingQueue = true
        PackageQueue.shared.operationBegan()
        LegacyTask.detached {
            let (outcome, changedTweaks) = self.perform(operation, monitor: monitor)
            DispatchQueue.main.sync {
                // released before the outcome is published: whoever awaits
                // the outcome may begin the next operation straight away,
                // and the queue is settled before anyone looks at it
                self.inProcessingQueue = false
                PackageQueue.shared.operationFinished(
                    plan: operation.plan,
                    succeeded: outcome.succeeded,
                    dryRun: operation.transaction.dryRun
                )
                monitor.finish(outcome, changedTweaks: changedTweaks)
            }
        }
        return monitor
    }

    /// How the run ended, and whether it left the tweak directories
    /// different, failed or not: what it finished stays installed.
    private nonisolated func perform(
        _ operation: OperationPayload,
        monitor: OperationMonitor
    ) -> (OperationMonitor.Outcome, changedTweaks: Bool) {
        guard (try? PackageQueue.currency(of: operation.plan, index: DispatchQueue.main.sync { PackageCenter.default.index })) == .current
        else {
            return (.failed(String(legacyLocalized: "Packages changed. Review the changes and try again.")), false)
        }

        Dog.shared.join(
            self,
            """
            beginning \(operation.transaction.dryRun ? "dry run" : "transaction")
                install: \(operation.transaction.install.map(\.identity).joined(separator: ", "))
                remove: \(operation.transaction.remove.joined(separator: ", "))
                requiresRestart: \(operation.transaction.touchesSelf)
            """,
            level: .info
        )

        DispatchQueue.main.sync {
            if case .daemon = PrivilegedBackend.backend {
                // without one, the refusal that follows says it all
                monitor.append(PrivilegedBackend.localizedStatus)
            }
        }
        let tweaks = TweakInjection.read()
        let status = PrivilegedBackend.run(.transaction(operation.transaction)) { event in
            DispatchQueue.main.sync { monitor.record(event) }
        }

        // MARK: - FINISH UP

        // the staged copies served their purpose; the downloads themselves stay
        try? FileManager.default.removeItem(at: workingLocation.appendingPathComponent(operation.plan.id.uuidString))
        // the plan's packages the helper got as far as configuring become
        // origins of what dpkg now reports. `configuring` is announced once
        // the record is in dpkg's database at that version; `unpacking` is
        // announced before the attempt, and a reinstall that fails there
        // leaves the old file behind under the same version. A package the
        // run never reached, or a dry run, leaves the previous origin alone.
        let transcript = DispatchQueue.main.sync { monitor.transcript }
        let configured = Set(transcript.compactMap { event -> String? in
            guard case let .package(.configuring, identity, version) = event else { return nil }
            return identity + " " + version
        })
        let sources = operation.transaction.dryRun ? [] : operation.plan.install.filter {
            configured.contains($0.identity + " " + ($0.latestVersion ?? ""))
        }
        PackageCenter.default.reloadLocalPackages(installedFrom: sources)

        let changedTweaks = TweakInjection.read() != tweaks
        let failure = DispatchQueue.main.sync { monitor.failure }
        return (.init(status: status, failure: failure), changedTweaks)
    }

    private nonisolated static func reset(_ location: URL) throws {
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
        try FileManager.default.createDirectory(
            at: location,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
