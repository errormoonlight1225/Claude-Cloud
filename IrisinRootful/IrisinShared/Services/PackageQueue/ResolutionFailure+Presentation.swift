//
//  ResolutionFailure+Presentation.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import LegacyCompat
import AptResolver
import Foundation

nonisolated extension ResolutionFailure {
    /// The reason, in the user's language.
    var message: String {
        reason.message
    }
}

nonisolated extension ResolutionFailure.Reason {
    var message: String {
        let list = LegacyListFormatter.localizedString(byJoining:)
        return switch self {
        case let .unreadableVersion(package):
            String(legacyLocalized: "\(package): the repository sent an unreadable version. Refresh the repository and try again.")
        case let .unreadableMetadata(package, version):
            String(legacyLocalized: "\(package) \(version): the repository sent unreadable package information. Refresh the repository and try again.")
        case let .unfinishedInstall(package):
            String(legacyLocalized: "\(package) did not finish installing. Install it again before making other changes.")
        case let .ambiguousVersion(package):
            String(legacyLocalized: "\(package) could not be resolved to a single version. Clear the queue and try again.")
        case let .missingRequirement(package, requirement):
            String(legacyLocalized: "\(package) requires \(requirement), which is not available. Add a repository that provides it and try again.")
        case let .conflict(package, requirement):
            String(legacyLocalized: "\(package) conflicts with \(requirement). Remove one of them and try again.")
        case let .noInstallOrder(packages):
            String(legacyLocalized: "These packages could not be installed in a valid order: \(list(packages)). Remove some of them from the queue and try again.")
        case .orderUnplanned:
            String(legacyLocalized: "The installation order could not be planned. Try again with fewer changes.")
        case let .noVersion(package):
            String(legacyLocalized: "\(package): no version is available from its repository. Refresh the repository and try again.")
        case let .versionUnavailable(package):
            String(legacyLocalized: "\(package): this version is not available from its repository. Refresh the repository and try again.")
        case .noPlan:
            String(legacyLocalized: "No compatible installation plan was found.")
        case .requirementsUnmatched:
            String(legacyLocalized: "Some package requirements could not be matched.")
        case .requirementsConflict:
            String(legacyLocalized: "Matching packages were found, but their requirements conflict.")
        case .unresolvable:
            String(legacyLocalized: "The selected packages could not be resolved. Adjust your selection and try again.")
        case let .requiredBySystem(package):
            String(legacyLocalized: "\(package) is required by the system and cannot be removed.")
        case let .neededBySystem(package, dependents):
            String(legacyLocalized: "\(package) is needed by \(list(dependents)), which the system requires, so it cannot be removed.")
        case let .onHold(package):
            String(legacyLocalized: "\(package) is on hold and cannot be changed. Remove the hold and try again.")
        case .updateAllRemoves:
            String(legacyLocalized: "Updating everything would remove installed packages. Update packages one at a time.")
        case .unknown:
            String(legacyLocalized: "Unable to resolve the packages. Review the queue and try again.")
        case let .message(text):
            text
        }
    }
}
