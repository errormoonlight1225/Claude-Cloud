import Foundation
import UIKit

struct SignConfiguration {
    var identityID: UUID
    var bundleID: String
    var displayName: String
    var version: String
    var minimumOSVersion: String = ""
    var removeExtensions: Bool
    var removeWatchApp: Bool
    var removeUISupportedDevices: Bool
    var enableFileSharing: Bool
}

/// App-wide state and the operations on it. Persisted as JSON; secrets go to the keychain.
@MainActor
final class KilnStore: ObservableObject {
    @Published private(set) var identities: [SigningIdentity] = []
    @Published private(set) var apps: [ImportedApp] = []
    @Published private(set) var signedApps: [SignedApp] = []
    @Published var settings = AppSettings() {
        didSet { if settings != oldValue { save() } }
    }

    private var iconCache: [UUID: UIImage] = [:]

    init() { load() }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.state),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        identities = state.identities
        apps = state.apps
        signedApps = state.signedApps
        settings = state.settings
    }

    private func save() {
        let state = PersistedState(identities: identities, apps: apps, signedApps: signedApps, settings: settings)
        do {
            try JSONEncoder().encode(state).write(to: Paths.state, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("Kiln: failed to save state: \(error)")
        }
    }

    // MARK: App Store Connect account

    func ascClient() throws -> ASCClient {
        guard settings.isASCConfigured, let pem = Keychain.string(for: Keychain.ascPrivateKey) else {
            throw KilnError("尚未配置 App Store Connect API 密钥（设置 → 开发者账号）")
        }
        return try ASCClient(credentials: .init(issuerID: settings.ascIssuerID, keyID: settings.ascKeyID, privateKeyPEM: pem))
    }

    /// Verifies the key against the API before storing it.
    func saveASCCredentials(issuerID: String, keyID: String, privateKeyPEM: String) async throws {
        let creds = ASCClient.Credentials(issuerID: issuerID.trimmed, keyID: keyID.trimmed, privateKeyPEM: privateKeyPEM)
        _ = try await ASCClient(credentials: creds).devices()
        try Keychain.set(privateKeyPEM, for: Keychain.ascPrivateKey)
        settings.ascIssuerID = creds.issuerID
        settings.ascKeyID = creds.keyID
        settings.hasASCKey = true
    }

    func removeASCCredentials() {
        Keychain.remove(Keychain.ascPrivateKey)
        settings.hasASCKey = false
        settings.ascKeyID = ""
        settings.ascIssuerID = ""
    }

    // MARK: Identities

    func identity(_ id: UUID) -> SigningIdentity? { identities.first { $0.id == id } }

    func certificateDER(for identity: SigningIdentity) throws -> Data {
        try Data(contentsOf: Paths.identities.appendingPathComponent(identity.certificateFileName))
    }

    func privateKeyPEM(for identity: SigningIdentity) throws -> String {
        guard let pem = Keychain.string(for: identity.privateKeyAccount) else {
            throw KilnError("钥匙串中找不到该证书的私钥（可能是从备份恢复的设备），请重新导入或重新申请证书")
        }
        return pem
    }

    /// Generates a key pair on device, sends the CSR to Apple and stores the issued certificate.
    func createASCIdentity(type: String) async throws -> SigningIdentity {
        let client = try ascClient()
        let csr = try await Task.detached(priority: .userInitiated) {
            try Core.generateCSR(commonName: "Kiln Signing Key")
        }.value
        let certificate = try await client.createCertificate(type: type, csrPEM: csr.csrPEM)
        guard let der = certificate.der else { throw KilnError("Apple 没有返回证书内容") }

        let identity = try storeIdentity(certificateDER: der, privateKeyPEM: csr.privateKeyPEM,
                                         source: .appStoreConnect(certificateID: certificate.id, certificateType: type),
                                         profiles: [])
        return identity
    }

    /// Imports an existing .p12 and optionally a provisioning profile that contains it.
    func importIdentity(p12: Data, password: String, profileData: Data?) throws -> SigningIdentity {
        let core = try Core.identity(pkcs12: p12, password: password)
        var profiles: [(MobileProvision, Data)] = []
        if let profileData {
            let profile = try MobileProvision(data: profileData)
            guard profile.contains(certificate: core.certificateDER) else {
                throw KilnError("描述文件「\(profile.name)」不包含这个 p12 里的证书，请确认两者是配套的")
            }
            profiles.append((profile, profileData))
        }
        return try storeIdentity(certificateDER: core.certificateDER, privateKeyPEM: core.privateKeyPEM,
                                 source: .imported, profiles: profiles)
    }

    private func storeIdentity(certificateDER: Data, privateKeyPEM: String, source: IdentitySource,
                               profiles: [(MobileProvision, Data)]) throws -> SigningIdentity {
        let info = try Core.certificateInfo(certificateDER)
        if let existing = identities.first(where: { $0.sha1 == info.sha1 }) {
            throw KilnError("该证书已存在：\(existing.commonName)")
        }
        var identity = SigningIdentity(id: UUID(), commonName: info.commonName, teamID: info.organizationalUnit,
                                       teamName: info.organization, serialNumber: info.serialNumber, sha1: info.sha1,
                                       notAfter: info.notAfter, source: source, profiles: [], createdAt: Date())
        try Keychain.set(privateKeyPEM, for: identity.privateKeyAccount)
        try certificateDER.write(to: Paths.identities.appendingPathComponent(identity.certificateFileName), options: .atomic)
        for (profile, data) in profiles {
            let record = profile.record()
            try data.write(to: Paths.profiles.appendingPathComponent(record.fileName), options: .atomic)
            identity.profiles.append(record)
        }
        identities.insert(identity, at: 0)
        save()
        return identity
    }

    func addProfile(_ data: Data, to identityID: UUID) throws {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        let profile = try MobileProvision(data: data)
        guard profile.contains(certificate: try certificateDER(for: identities[index])) else {
            throw KilnError("描述文件「\(profile.name)」不包含该证书")
        }
        let record = profile.record()
        try data.write(to: Paths.profiles.appendingPathComponent(record.fileName), options: .atomic)
        removeProfiles(in: index) { $0.uuid == record.uuid }
        identities[index].profiles.append(record)
        save()
    }

    func removeProfile(_ profile: ProfileRecord, from identityID: UUID) {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        removeProfiles(in: index) { $0.id == profile.id }
        save()
    }

    private func removeProfiles(in index: Int, where predicate: (ProfileRecord) -> Bool) {
        for p in identities[index].profiles where predicate(p) {
            try? FileManager.default.removeItem(at: Paths.profiles.appendingPathComponent(p.fileName))
        }
        identities[index].profiles.removeAll(where: predicate)
    }

    func deleteIdentity(_ identity: SigningIdentity, revoke: Bool) async throws {
        if revoke, let certID = identity.ascCertificateID {
            try await ascClient().revokeCertificate(id: certID)
        }
        guard let index = identities.firstIndex(where: { $0.id == identity.id }) else { return }
        removeProfiles(in: index) { _ in true }
        Keychain.remove(identity.privateKeyAccount)
        try? FileManager.default.removeItem(at: Paths.identities.appendingPathComponent(identity.certificateFileName))
        identities.remove(at: index)
        save()
    }

    // MARK: Export

    /// Writes <name>.p12 (+ all profiles) into Documents/Exports/<name>/ and returns the files.
    func export(_ identity: SigningIdentity, password: String, includeProfiles: Bool) throws -> [URL] {
        let p12 = try Core.makePKCS12(certificate: try certificateDER(for: identity), chain: [],
                                      privateKeyPEM: try privateKeyPEM(for: identity), password: password,
                                      friendlyName: identity.commonName)
        let folderName = identity.commonName.fileSafe + " " + identity.serialNumber.suffix(6)
        let folder = Paths.exports.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var files: [URL] = []
        let p12URL = folder.appendingPathComponent("\(identity.commonName.fileSafe).p12")
        try p12.write(to: p12URL, options: .atomic)
        files.append(p12URL)

        let cerURL = folder.appendingPathComponent("\(identity.commonName.fileSafe).cer")
        try certificateDER(for: identity).write(to: cerURL, options: .atomic)
        files.append(cerURL)

        if includeProfiles {
            for profile in identity.profiles {
                let src = Paths.profiles.appendingPathComponent(profile.fileName)
                let dst = folder.appendingPathComponent("\(profile.bundleIDPattern.fileSafe).mobileprovision")
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
                files.append(dst)
            }
        }
        return files
    }

    func profileURL(_ profile: ProfileRecord) -> URL {
        Paths.profiles.appendingPathComponent(profile.fileName)
    }

    // MARK: Provisioning (App Store Connect)

    /// Returns a profile for `bundleID` that includes this certificate and every enabled device,
    /// registering the App ID and (re)creating the profile when needed.
    func ensureProfile(for identityID: UUID, bundleID: String, appName: String,
                       log: @escaping (String) -> Void) async throws -> ProfileRecord {
        guard let identity = self.identity(identityID), case let .appStoreConnect(certID, certType) = identity.source else {
            throw KilnError("只有通过 App Store Connect 申请的证书才能自动生成描述文件")
        }
        let client = try ascClient()

        log("获取已注册设备…")
        let devices = try await client.devices().filter { $0.isEnabled && $0.isIOSDevice }
        guard !devices.isEmpty else { throw KilnError("账号下没有已启用的 iOS 设备，请先在「设备」页注册本机 UDID") }
        let udids = Set(devices.compactMap { $0.attributes.udid?.uppercased() })

        if let existing = identity.profiles.first(where: { $0.bundleIDPattern == bundleID }),
           existing.expiresAt.timeIntervalSinceNow > 7 * 86400,
           FileManager.default.fileExists(atPath: profileURL(existing).path),
           udids.isSubset(of: Set(existing.deviceUDIDs.map { $0.uppercased() })) {
            log("复用描述文件 \(existing.name)")
            return existing
        }

        log("检查 App ID \(bundleID)…")
        let bundle: ASCBundleID
        if let found = try await client.bundleID(identifier: bundleID) {
            bundle = found
        } else {
            log("注册 App ID \(bundleID)")
            bundle = try await client.createBundleID(identifier: bundleID, name: Self.ascName(appName, bundleID))
        }

        if let old = identity.profiles.first(where: { $0.bundleIDPattern == bundleID }), let oldID = old.ascProfileID {
            try? await client.deleteProfile(id: oldID)
        }

        let profileType = certType.contains("DISTRIBUTION") ? "IOS_APP_ADHOC" : "IOS_APP_DEVELOPMENT"
        let stamp = Int(Date().timeIntervalSince1970)
        log("生成描述文件（\(devices.count) 台设备）…")
        let created = try await client.createProfile(name: "Kiln \(Self.ascName(appName, bundleID)) \(stamp)",
                                                     type: profileType, bundleIDResource: bundle.id,
                                                     certificateIDs: [certID], deviceIDs: devices.map(\.id))
        guard let content = created.attributes.profileContent, let data = Data(base64Encoded: content) else {
            throw KilnError("Apple 没有返回描述文件内容")
        }
        let parsed = try MobileProvision(data: data)
        let record = parsed.record(ascProfileID: created.id, ascBundleIDResource: bundle.id)
        try data.write(to: Paths.profiles.appendingPathComponent(record.fileName), options: .atomic)

        if let index = identities.firstIndex(where: { $0.id == identityID }) {
            removeProfiles(in: index) { $0.bundleIDPattern == bundleID }
            identities[index].profiles.append(record)
            save()
        }
        return record
    }

    /// App Store Connect names only allow letters, digits and spaces.
    private static func ascName(_ name: String, _ fallback: String) -> String {
        let cleaned = String((name.isEmpty ? fallback : name).unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " "
        }).trimmed
        return cleaned.isEmpty ? "Kiln App" : String(cleaned.prefix(40))
    }

    // MARK: Apps

    func importIPA(from url: URL) async throws -> ImportedApp {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let destination = Paths.apps.appendingPathComponent("\(id.uuidString).ipa")
        let info: IPAInspector.Info = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: url, to: destination)
            do {
                return try IPAInspector.inspect(ipa: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value

        let app = ImportedApp(id: id, name: info.name, bundleID: info.bundleID, version: info.version,
                              build: info.build, minimumOSVersion: info.minimumOSVersion,
                              extensionBundleIDs: info.extensionBundleIDs, hasWatchApp: info.hasWatchApp,
                              fileSize: FileManager.default.fileSize(destination), importedAt: Date())
        if let png = info.icon?.pngData() {
            try? png.write(to: Paths.icons.appendingPathComponent(app.iconFileName))
        }
        apps.insert(app, at: 0)
        save()
        return app
    }

    func deleteApp(_ app: ImportedApp) {
        try? FileManager.default.removeItem(at: Paths.apps.appendingPathComponent(app.ipaFileName))
        try? FileManager.default.removeItem(at: Paths.icons.appendingPathComponent(app.iconFileName))
        iconCache[app.id] = nil
        apps.removeAll { $0.id == app.id }
        save()
    }

    func deleteSigned(_ signed: SignedApp) {
        try? FileManager.default.removeItem(at: signedURL(signed))
        signedApps.removeAll { $0.id == signed.id }
        save()
    }

    func signedURL(_ signed: SignedApp) -> URL { Paths.signed.appendingPathComponent(signed.fileName) }

    func icon(for appID: UUID) -> UIImage? {
        if let cached = iconCache[appID] { return cached }
        let image = UIImage(contentsOfFile: Paths.icons.appendingPathComponent("\(appID.uuidString).png").path)
        iconCache[appID] = image
        return image
    }

    /// Default new bundle id: "<prefix>.<original>" when a prefix is set, else the original id.
    func suggestedBundleID(for app: ImportedApp, identity: SigningIdentity?) -> String {
        if let identity, !identity.isAppStoreConnect {
            if let explicit = identity.profiles.first(where: { !$0.isWildcard && !$0.isExpired }) {
                return explicit.bundleIDPattern
            }
            return app.bundleID
        }
        let prefix = settings.bundleIDPrefix.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return prefix.isEmpty ? app.bundleID : "\(prefix).\(app.bundleID)"
    }

    // MARK: Signing

    func sign(_ app: ImportedApp, configuration c: SignConfiguration,
              log: @escaping (String) -> Void) async throws -> SignedApp {
        guard let identity = self.identity(c.identityID) else { throw KilnError("请选择签名证书") }
        guard !identity.isExpired else { throw KilnError("证书已过期") }
        let bundleID = c.bundleID.trimmed
        guard Self.isValidBundleID(bundleID) else { throw KilnError("Bundle ID 格式无效：\(bundleID)") }

        let keyPEM = try privateKeyPEM(for: identity)
        let certDER = try certificateDER(for: identity)

        // Bundle ids zsign will produce for app extensions.
        let extensionIDs = c.removeExtensions ? [] : app.extensionBundleIDs.map {
            $0.replacingOccurrences(of: app.bundleID, with: bundleID)
        }
        if extensionIDs.contains(where: { !$0.hasPrefix(bundleID + ".") }) {
            throw KilnError("部分扩展的 Bundle ID 不以主程序 ID 开头，无法自动改名。请打开「移除扩展」后再签名")
        }

        // Resolve provisioning profiles: main app first, then extensions.
        var profiles: [ProfileRecord] = []
        var entitlementsOverride: Data?
        if identity.isAppStoreConnect {
            for id in [bundleID] + extensionIDs {
                profiles.append(try await ensureProfile(for: identity.id, bundleID: id, appName: app.name, log: log))
            }
        } else {
            let usable = identity.profiles.filter { !$0.isExpired }
            guard let main = usable.first(where: { !$0.isWildcard && $0.matches(bundleID: bundleID) })
                    ?? usable.first(where: { $0.matches(bundleID: bundleID) }) else {
                throw KilnError("该证书没有匹配 \(bundleID) 的有效描述文件。请改用描述文件中的 Bundle ID，或为证书添加通配符描述文件")
            }
            profiles.append(main)
            if main.isWildcard {
                entitlementsOverride = try wildcardEntitlements(profile: main, bundleID: bundleID)
            } else {
                for id in extensionIDs {
                    guard let p = usable.first(where: { !$0.isWildcard && $0.bundleIDPattern == id }) else {
                        throw KilnError("缺少扩展 \(id) 的描述文件，请导入它或打开「移除扩展」")
                    }
                    profiles.append(p)
                }
            }
        }
        let profilePaths = profiles.map { profileURL($0).path }
        let entitlements = entitlementsOverride

        let ipa = Paths.apps.appendingPathComponent(app.ipaFileName)
        let outName = "\(app.name.fileSafe)_\(c.version.fileSafe)_\(Int(Date().timeIntervalSince1970)).ipa"
        let output = Paths.signed.appendingPathComponent(outName)

        log("解压 IPA…")
        try await Task.detached(priority: .userInitiated) {
            let work = try Paths.makeWorkDirectory("sign")
            defer { try? FileManager.default.removeItem(at: work) }
            let root = work.appendingPathComponent("root", isDirectory: true)
            let secrets = work.appendingPathComponent("secrets", isDirectory: true)
            try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)

            let certURL = secrets.appendingPathComponent("cert.der")
            let keyURL = secrets.appendingPathComponent("key.pem")
            try writeProtected(certDER, to: certURL)
            try writeProtected(Data(keyPEM.utf8), to: keyURL)

            try Core.extractZip(at: ipa.path, to: root.path)

            let options = CoreSignOptions()
            options.certificatePath = certURL.path
            options.privateKeyPath = keyURL.path
            options.profilePaths = profilePaths
            if let entitlements {
                let url = secrets.appendingPathComponent("entitlements.plist")
                try entitlements.write(to: url)
                options.entitlementsPath = url.path
            }
            options.bundleID = bundleID
            options.displayName = c.displayName.trimmed.isEmpty ? nil : c.displayName.trimmed
            options.bundleVersion = c.version.trimmed.isEmpty ? nil : c.version.trimmed
            options.minimumOSVersion = c.minimumOSVersion.trimmed.isEmpty ? nil : c.minimumOSVersion.trimmed
            options.removeExtensions = c.removeExtensions
            options.removeWatchApp = c.removeWatchApp
            options.removeUISupportedDevices = c.removeUISupportedDevices
            options.enableFileSharing = c.enableFileSharing

            log("签名中…")
            _ = try Core.sign(folder: root.path, options: options) { _, line in log(line) }
            // Key material is no longer needed; remove before archiving.
            try? FileManager.default.removeItem(at: secrets)
            log("打包 IPA…")
            try Core.archive(folder: root.path, to: output.path, level: 1)
        }.value

        let signed = SignedApp(id: UUID(), sourceAppID: app.id, name: c.displayName.trimmed.isEmpty ? app.name : c.displayName.trimmed,
                               bundleID: bundleID, version: c.version.trimmed.isEmpty ? app.version : c.version.trimmed,
                               identityName: identity.commonName, signedAt: Date(), fileName: outName,
                               fileSize: FileManager.default.fileSize(output))
        signedApps.insert(signed, at: 0)
        save()
        log("完成：\(outName)")
        return signed
    }

    /// For wildcard profiles: profile entitlements with the concrete application identifier.
    private func wildcardEntitlements(profile: ProfileRecord, bundleID: String) throws -> Data {
        let parsed = try MobileProvision(data: Data(contentsOf: profileURL(profile)))
        var entitlements = parsed.entitlements
        entitlements["application-identifier"] = "\(parsed.teamID).\(bundleID)"
        if let groups = entitlements["keychain-access-groups"] as? [String] {
            entitlements["keychain-access-groups"] = groups.map { $0.hasSuffix(".*") ? "\(parsed.teamID).\(bundleID)" : $0 }
        }
        return try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    }

    static func isValidBundleID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$"#, options: .regularExpression) != nil
    }

    // MARK: Install server identity

    func importServerIdentity(certificate: Data, privateKey: Data?, password: String) throws {
        let core: CoreIdentity
        if let privateKey {
            core = try Core.identity(certificate: certificate, privateKey: privateKey, password: password)
        } else {
            core = try Core.identity(pkcs12: certificate, password: password)
        }
        let info = try Core.certificateInfo(core.certificateDER)
        // Re-wrap as a legacy p12 that SecPKCS12Import always understands.
        let internalPassword = UUID().uuidString
        let p12 = try Core.makePKCS12(certificate: core.certificateDER, chain: core.chainDER,
                                      privateKeyPEM: core.privateKeyPEM, password: internalPassword,
                                      friendlyName: "Kiln Install Server")
        _ = try InstallServer.loadIdentity(p12: p12, password: internalPassword)  // validate
        try Keychain.set(p12, for: Keychain.serverIdentity)
        try Keychain.set(internalPassword, for: Keychain.serverIdentityPassword)

        settings.hasServerIdentity = true
        settings.serverCertificateName = info.commonName
        settings.serverCertificateExpiry = info.notAfter
        if settings.serverDomain.isEmpty {
            let cn = info.commonName.hasPrefix("*.") ? String(info.commonName.dropFirst(2)) : info.commonName
            settings.serverDomain = cn
        }
    }

    func removeServerIdentity() {
        Keychain.remove(Keychain.serverIdentity)
        Keychain.remove(Keychain.serverIdentityPassword)
        settings.hasServerIdentity = false
        settings.serverCertificateName = ""
        settings.serverCertificateExpiry = nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var fileSafe: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = components(separatedBy: invalid).joined(separator: "_").trimmed
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
