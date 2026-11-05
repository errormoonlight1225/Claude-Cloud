import LegacyCompat
import Foundation
import IrisinProtocol

extension InstallerEvent {
    /// The row the operation console shows for this event, in the user's
    /// language, or nil for an event that draws something else (progress)
    /// or nothing at all.
    var consoleLine: String? {
        switch self {
        case let .started(started):
            return String(legacyLocalized: "Installer started at \(started.installRoot.isEmpty ? "/" : started.installRoot)")
        case let .phase(phase):
            return phase.localizedTitle
        case .progress, .packageProgress:
            return nil
        case let .package(step, identity, version):
            let subject = version.isEmpty ? identity : "\(identity) (\(version))"
            return switch step {
            case .verifying: String(legacyLocalized: "Checking \(subject)")
            case .removing: String(legacyLocalized: "Removing \(subject)")
            case .unpacking: String(legacyLocalized: "Unpacking \(subject)")
            case .configuring: String(legacyLocalized: "Setting up \(subject)")
            case .triggering: String(legacyLocalized: "Processing triggers for \(subject)")
            }
        case let .script(identity, member, arguments):
            let script = ([identity + "." + member] + arguments.filter { !$0.isEmpty }).joined(separator: " ")
            return String(legacyLocalized: "Running \(script)")
        case let .output(line):
            return line
        case let .notice(text):
            return text
        case let .warning(problem):
            return "[!] " + problem.localizedDescription
        case let .failure(problem):
            // the log is read on its own page: the reason has to be in it
            return "[!!] " + problem.localizedDescription
        case .exit(0):
            // the outcome's summary row says it
            return nil
        case let .exit(status):
            return String(legacyLocalized: "The installer stopped (error code \(status)).")
        }
    }
}

nonisolated extension InstallerEvent.Problem {
    /// The headline in the user's language; the helper's detail follows it
    /// where there is one, as it came.
    var localizedDescription: String {
        switch self {
        case .invalidJob:
            String(legacyLocalized: "This operation is not valid and was not started.")
        case .helperMisplaced:
            String(legacyLocalized: "Irisin is not installed correctly. Reinstall it and try again.")
        case let .installationStopped(detail):
            String(legacyLocalized: "Installation stopped: \(detail)")
        case let .packageFailed(identity, step, detail):
            switch step {
            case .removing: String(legacyLocalized: "Unable to remove \(identity): \(detail)")
            case .unpacking: String(legacyLocalized: "Unable to install \(identity): \(detail)")
            case .configuring, .triggering: String(legacyLocalized: "Unable to set up \(identity): \(detail)")
            case .verifying: String(legacyLocalized: "Unable to verify \(identity): \(detail)")
            }
        case let .scriptFailed(identity, _, script, status):
            String(legacyLocalized: "The \(script) script of \(identity) failed with exit status \(Int(status)).")
        case let .scriptFailureIgnored(identity, script, _):
            String(legacyLocalized: "The \(script) script of \(identity) failed, but installation continued.")
        case .homeScreenNeedsAttention:
            String(legacyLocalized: "Packages were changed, but the home screen was not updated. Choose Rebuild Icons to try again.")
        case let .registrationFailed(bundle, detail):
            String(legacyLocalized: "Unable to add \(bundle) to the home screen: \(detail)")
        case let .unregistrationFailed(bundle, detail):
            String(legacyLocalized: "Unable to remove \(bundle) from the home screen: \(detail)")
        case let .leftoverBundle(path, detail):
            String(legacyLocalized: "Unable to remove leftover app files at \(path): \(detail)")
        case let .refreshFailed(detail):
            String(legacyLocalized: "Unable to refresh apps: \(detail)")
        case let .daemonNotLoaded(detail):
            String(legacyLocalized: "Irisin's background service could not be started: \(detail)")
        case let .noProcess(name):
            String(legacyLocalized: "No process named \(name) is running.")
        case let .packageNeedsRepair(identity):
            String(legacyLocalized: "\(identity) did not finish installing. Install it again to repair it.")
        case let .markingsNotSaved(detail):
            String(legacyLocalized: "Unable to record which packages were installed as dependencies: \(detail)")
        case .browsingOnly:
            String(legacyLocalized: "You can browse, but not install. Install the Irisin package.")
        case .helperUnreachable:
            String(legacyLocalized: "The installer could not be started. Try again.")
        }
    }
}

extension InstallerEvent.Phase {
    /// The heading the console shows while this phase runs.
    var localizedTitle: String {
        switch self {
        case .preparing: String(legacyLocalized: "Preparing…")
        case .verifying: String(legacyLocalized: "Checking packages…")
        case .applying: String(legacyLocalized: "Applying changes…")
        case .processingTriggers: String(legacyLocalized: "Processing triggers…")
        case .registeringApplications: String(legacyLocalized: "Updating the home screen…")
        case .completed: String(legacyLocalized: "Finishing…")
        }
    }
}
