import Foundation

/// Parsed contents of a .mobileprovision file.
struct MobileProvision {
    let name: String
    let uuid: String
    let teamID: String
    let teamName: String
    let applicationIdentifier: String
    let expirationDate: Date
    let provisionedDevices: [String]
    let provisionsAllDevices: Bool
    let developerCertificates: [Data]
    let entitlements: [String: Any]

    init(data: Data) throws {
        let content = try Core.decodeCMS(data)
        guard let plist = try PropertyListSerialization.propertyList(from: content, format: nil) as? [String: Any]
        else { throw KilnError("描述文件内容不是有效的 plist") }

        entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        name = plist["Name"] as? String ?? "未命名描述文件"
        uuid = plist["UUID"] as? String ?? ""
        teamID = (plist["TeamIdentifier"] as? [String])?.first
            ?? entitlements["com.apple.developer.team-identifier"] as? String ?? ""
        teamName = plist["TeamName"] as? String ?? ""
        applicationIdentifier = entitlements["application-identifier"] as? String ?? ""
        expirationDate = plist["ExpirationDate"] as? Date ?? .distantPast
        provisionedDevices = plist["ProvisionedDevices"] as? [String] ?? []
        provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        developerCertificates = plist["DeveloperCertificates"] as? [Data] ?? []
        guard !applicationIdentifier.isEmpty else { throw KilnError("描述文件缺少 application-identifier") }
    }

    func contains(certificate der: Data) -> Bool {
        developerCertificates.contains(der)
    }

    func record(id: UUID = UUID(), ascProfileID: String? = nil, ascBundleIDResource: String? = nil) -> ProfileRecord {
        ProfileRecord(id: id, name: name, uuid: uuid, applicationIdentifier: applicationIdentifier,
                      teamID: teamID, expiresAt: expirationDate, deviceUDIDs: provisionedDevices,
                      ascProfileID: ascProfileID, ascBundleIDResource: ascBundleIDResource)
    }
}

struct KilnError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
