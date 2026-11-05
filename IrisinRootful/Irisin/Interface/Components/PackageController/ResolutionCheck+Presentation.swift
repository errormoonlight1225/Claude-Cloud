import LegacyCompat
import AptRepository
import AptResolver
import UIKit

extension ResolutionCheck {
    var statusText: String {
        switch outcome {
        case .matched: String(legacyLocalized: "Matching Package Found")
        case .missing: String(legacyLocalized: "Not Found in Installed Packages or Repositories")
        case .incompatibleArchitecture: String(legacyLocalized: "Found for a Different Architecture")
        case .noMatchingVersion: String(legacyLocalized: "No Version Meets This Requirement")
        case .invalidMetadata: String(legacyLocalized: "Package Metadata Could Not Be Read")
        case .conflictingRequirements: String(legacyLocalized: "Requirements Conflict")
        case .requiredBySystem: String(legacyLocalized: "Required by the System")
        }
    }

    var detailText: String {
        var lines = [statusText]
        if outcome == .incompatibleArchitecture {
            let device = AptEnvironment.current.deviceArchitecture
            lines.append(String(legacyLocalized: "This device supports \(device)."))
        }
        return (lines + candidates).joined(separator: "\n")
    }
}
