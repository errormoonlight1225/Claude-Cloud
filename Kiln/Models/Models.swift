import Foundation

/// Where a signing identity came from.
enum IdentitySource: Codable, Hashable {
    /// Created by Kiln through the App Store Connect API. The private key never left this device.
    case appStoreConnect(certificateID: String, certificateType: String)
    /// Imported from a .p12 (+ .mobileprovision) the user already had.
    case imported
}

struct SigningIdentity: Identifiable, Codable, Hashable {
    var id: UUID
    var commonName: String
    var teamID: String
    var teamName: String
    var serialNumber: String
    var sha1: String
    var notAfter: Date
    var source: IdentitySource
    var profiles: [ProfileRecord]
    var createdAt: Date

    /// Keychain account holding the PEM private key.
    var privateKeyAccount: String { "identity.\(id.uuidString).key" }
    var certificateFileName: String { "\(id.uuidString).cer" }

    var isExpired: Bool { notAfter < Date() }

    var isAppStoreConnect: Bool {
        if case .appStoreConnect = source { return true }
        return false
    }

    var ascCertificateID: String? {
        if case let .appStoreConnect(id, _) = source { return id }
        return nil
    }

    var kindLabel: String {
        switch source {
        case let .appStoreConnect(_, type):
            return type.contains("DISTRIBUTION") ? "Apple Distribution（Ad Hoc）" : "Apple Development"
        case .imported:
            return commonName.contains("Distribution") ? "导入 · Distribution" : "导入 · Development"
        }
    }
}

struct ProfileRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var uuid: String
    /// e.g. "ABCDE12345.com.example.app" or "ABCDE12345.*"
    var applicationIdentifier: String
    var teamID: String
    var expiresAt: Date
    var deviceUDIDs: [String]
    var ascProfileID: String?
    var ascBundleIDResource: String?

    var fileName: String { "\(id.uuidString).mobileprovision" }

    /// The bundle id part without the team prefix.
    var bundleIDPattern: String {
        let prefix = teamID + "."
        return applicationIdentifier.hasPrefix(prefix)
            ? String(applicationIdentifier.dropFirst(prefix.count))
            : applicationIdentifier
    }

    var isWildcard: Bool { bundleIDPattern.hasSuffix("*") }
    var isExpired: Bool { expiresAt < Date() }

    func matches(bundleID: String) -> Bool {
        let pattern = bundleIDPattern
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast())) }
        return pattern == bundleID
    }
}

struct ImportedApp: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minimumOSVersion: String
    var extensionBundleIDs: [String]
    var hasWatchApp: Bool
    var fileSize: Int64
    var importedAt: Date

    var ipaFileName: String { "\(id.uuidString).ipa" }
    var iconFileName: String { "\(id.uuidString).png" }
}

struct SignedApp: Identifiable, Codable, Hashable {
    var id: UUID
    var sourceAppID: UUID
    var name: String
    var bundleID: String
    var version: String
    var identityName: String
    var signedAt: Date
    var fileName: String
    var fileSize: Int64
}

struct AppSettings: Codable, Equatable {
    /// Prefix used to derive new bundle ids, e.g. "com.yourname.kiln" -> "com.yourname.kiln.com.foo.bar".
    var bundleIDPrefix: String = ""
    var ascIssuerID: String = ""
    var ascKeyID: String = ""
    var hasASCKey: Bool = false

    /// Hostname that resolves to 127.0.0.1 and is covered by the imported TLS certificate.
    var serverDomain: String = ""
    var serverPort: UInt16 = 8443
    var hasServerIdentity: Bool = false
    var serverCertificateName: String = ""
    var serverCertificateExpiry: Date?

    var defaultRemoveExtensions: Bool = false
    var defaultRemoveWatchApp: Bool = true
    var defaultRemoveUISupportedDevices: Bool = true

    var isASCConfigured: Bool { hasASCKey && !ascKeyID.isEmpty }
    var isServerConfigured: Bool { hasServerIdentity && !serverDomain.isEmpty }
}

struct PersistedState: Codable {
    var identities: [SigningIdentity] = []
    var apps: [ImportedApp] = []
    var signedApps: [SignedApp] = []
    var settings = AppSettings()
}
