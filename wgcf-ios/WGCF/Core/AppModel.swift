import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var credentials: Credentials?
    private(set) var tunnel: TunnelInfo?
    private(set) var account: WarpAccount?
    private(set) var devices: [BoundDevice] = []
    private(set) var isBusy = false
    var errorMessage: String?

    var options: ProfileOptions {
        didSet { saveOptions() }
    }

    @ObservationIgnored private let api: WarpAPI
    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    private static let optionsKey = "profileOptions"

    init(api: WarpAPI = WarpAPI(), store: CredentialStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.api = api
        self.store = store
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(ProfileOptions.self, from: data) {
            options = saved
        } else {
            options = ProfileOptions()
        }
        if let state = store.load() {
            credentials = state.credentials
            tunnel = state.tunnel
        }
    }

    var isRegistered: Bool { credentials != nil }

    /// 当前选项下的 WireGuard 配置文本；缺少隧道信息或选项无效时为 nil。
    var profileText: String? {
        guard let credentials, let tunnel else { return nil }
        return try? WireGuardProfile.render(privateKey: credentials.privateKey, tunnel: tunnel, options: options)
    }

    var accountFileText: String? {
        credentials.map(AccountFile.encode)
    }

    // MARK: - 操作（对应 wgcf 的各个子命令）

    /// `wgcf register`
    func register(deviceName: String, deviceModel: String, existingPrivateKey: String) async {
        await run {
            let privateKey = try Self.resolvePrivateKey(existingPrivateKey)
            let model = deviceModel.trimmingCharacters(in: .whitespaces)
            let device = try await self.api.register(
                publicKey: try privateKey.publicKey(), model: model.isEmpty ? "PC" : model)
            guard let token = device.token, !token.isEmpty else { throw WGCFError.invalidResponse }

            let credentials = Credentials(
                deviceId: device.id, accessToken: token,
                privateKey: privateKey.base64, licenseKey: device.account?.license ?? "")
            // 先落盘再做后续请求，避免后续失败导致刚注册的账户丢失。
            try self.persist(credentials, tunnel: try? WireGuardProfile.tunnelInfo(from: device))
            self.account = device.account

            let name = deviceName.trimmingCharacters(in: .whitespaces)
            try await self.setName(name.isEmpty ? Self.randomName() : name, deviceId: device.id, credentials: credentials)
            try await self.reload(credentials)
        }
    }

    /// `wgcf status` + 刷新隧道参数
    func refresh() async {
        await run {
            try await self.reload(try self.requireCredentials())
        }
    }

    /// `wgcf update --license-key`
    func bindLicense(_ license: String) async {
        await run {
            var credentials = try self.requireCredentials()
            let license = license.trimmingCharacters(in: .whitespacesAndNewlines)
            guard LicenseKey.isValid(license) else {
                throw WireGuardKey.isKey(license) ? WGCFError.licenseLooksLikePrivateKey : WGCFError.invalidLicenseKey
            }
            try await self.api.updateLicense(credentials, license: license)
            credentials.licenseKey = license
            try self.persist(credentials, tunnel: self.tunnel)
            try await self.reload(credentials)
        }
    }

    /// `wgcf update --name`
    func rename(_ device: BoundDevice, to name: String) async {
        await run {
            let credentials = try self.requireCredentials()
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            try await self.setName(name, deviceId: device.id, credentials: credentials)
            self.devices = try await self.api.boundDevices(credentials)
        }
    }

    /// `wgcf update --activate / --deactivate`
    func setActive(_ device: BoundDevice, active: Bool) async {
        await run {
            let credentials = try self.requireCredentials()
            try await self.api.setDeviceActive(credentials, deviceId: device.id, active: active)
            self.devices = try await self.api.boundDevices(credentials)
        }
    }

    /// `wgcf update --remove`
    func remove(_ device: BoundDevice) async {
        await run {
            let credentials = try self.requireCredentials()
            try await self.api.deleteBoundDevice(credentials, deviceId: device.id)
            self.devices = try await self.api.boundDevices(credentials)
        }
    }

    /// 在 Cloudflare 上删除当前设备的注册，并清除本地数据。
    func unregister() async {
        await run {
            let credentials = try self.requireCredentials()
            try await self.api.deleteRegistration(credentials)
            self.forgetLocalAccount()
        }
    }

    /// 只清除本地数据，Cloudflare 上的注册保持不变。
    func forgetLocalAccount() {
        store.clear()
        credentials = nil
        tunnel = nil
        account = nil
        devices = []
    }

    /// 导入 wgcf 命令行生成的 wgcf-account.toml。
    func importAccountFile(_ text: String) async {
        await run {
            let credentials = try AccountFile.decode(text)
            // 先向服务器验证凭据，成功后才保存。
            let device = try await self.api.sourceDevice(credentials)
            try self.persist(credentials, tunnel: try? WireGuardProfile.tunnelInfo(from: device))
            try await self.reload(credentials)
        }
    }

    func isCurrent(_ device: BoundDevice) -> Bool {
        device.id == credentials?.deviceId
    }

    // MARK: - 内部

    static func resolvePrivateKey(_ input: String) throws -> WireGuardKey {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return WireGuardKey.generatePrivate() }
        if LicenseKey.isValid(input) { throw WGCFError.privateKeyLooksLikeLicense }
        guard let key = WireGuardKey(base64: input) else { throw WGCFError.invalidPrivateKey }
        return key
    }

    static func randomName() -> String {
        (0..<3).map { _ in String(format: "%02X", UInt8.random(in: .min ... .max)) }.joined()
    }

    private func requireCredentials() throws -> Credentials {
        guard let credentials else { throw WGCFError.noAccount }
        return credentials
    }

    private func persist(_ credentials: Credentials, tunnel: TunnelInfo?) throws {
        try store.save(StoredState(credentials: credentials, tunnel: tunnel))
        self.credentials = credentials
        self.tunnel = tunnel
    }

    private func reload(_ credentials: Credentials) async throws {
        async let device = api.sourceDevice(credentials)
        async let account = api.account(credentials)
        async let devices = api.boundDevices(credentials)

        let fetchedDevice = try await device
        self.account = try await account
        self.devices = try await devices

        var updated = credentials
        // 账户的许可证可能在别的设备上被更换，以服务器为准。
        if let license = self.account?.license, !license.isEmpty {
            updated.licenseKey = license
        }
        try persist(updated, tunnel: (try? WireGuardProfile.tunnelInfo(from: fetchedDevice)) ?? tunnel)
    }

    private func setName(_ name: String, deviceId: String, credentials: Credentials) async throws {
        do {
            let devices = try await api.renameDevice(credentials, deviceId: deviceId, name: name)
            guard devices.first(where: { $0.id == deviceId })?.name == name else {
                throw WGCFError.nameUpdateFailed
            }
        } catch WGCFError.http(status: 500, message: _) {
            // 与 wgcf 相同：服务器偶尔返回 500，但改名实际已生效。
        }
    }

    private func run(_ operation: @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Self.optionsKey)
        }
    }
}
