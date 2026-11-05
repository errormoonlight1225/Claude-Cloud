//
//  ArchiveMismatch+Console.swift
//  Irisin
//

import LegacyCompat
import AptRepository
import Foundation

extension ArchiveMismatch {
    /// The reason in the user's language, for the action report. The fields
    /// are dpkg's own names and stay as the control file spells them.
    var report: String {
        let fields = differences.map { $0.field == "sha256" ? "SHA256" : $0.field.capitalized }
            .joined(separator: ", ")
        return String(legacyLocalized: "The repository lists \(package) differently from the package file (\(fields)), so it was not installed. Refresh the repository, or ask its maintainer to correct the listing.")
    }
}
