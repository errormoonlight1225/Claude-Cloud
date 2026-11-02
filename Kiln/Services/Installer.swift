import Foundation
import UIKit

/// Installs a signed IPA on this device via itms-services, served from the local HTTPS server.
@MainActor
final class Installer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case waitingForConfirmation(String)
        case downloading(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var requestLog: [String] = []

    private let server = InstallServer()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        server.onRequest = { [weak self] line in
            Task { @MainActor in self?.didReceive(line) }
        }
    }

    func install(_ signed: SignedApp, ipa: URL, icon: UIImage?, settings: AppSettings) async throws {
        guard settings.isServerConfigured,
              let p12 = Keychain.data(for: Keychain.serverIdentity),
              let password = Keychain.string(for: Keychain.serverIdentityPassword) else {
            throw KilnError("还没有配置安装服务器证书（设置 → 本机安装服务）。也可以先导出 IPA 用其它方式安装。")
        }
        if let expiry = settings.serverCertificateExpiry, expiry < Date() {
            throw KilnError("安装服务器证书已过期，请在设置中导入新的证书")
        }

        phase = .starting
        requestLog = []
        do {
            if !server.isRunning || server.port != settings.serverPort {
                try await server.start(p12: p12, password: password, port: settings.serverPort)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }

        let token = UUID().uuidString.lowercased()
        let base = "https://\(settings.serverDomain):\(settings.serverPort)/\(token)"
        var routes: [String: InstallServer.Body] = [
            "/\(token)/app.ipa": .file(ipa, contentType: "application/octet-stream"),
        ]
        var assets: [[String: String]] = [["kind": "software-package", "url": "\(base)/app.ipa"]]
        if let png = icon?.pngData() {
            routes["/\(token)/icon.png"] = .data(png, contentType: "image/png")
            assets.append(["kind": "display-image", "needs-shine": "false", "url": "\(base)/icon.png"] as [String: String])
            assets.append(["kind": "full-size-image", "needs-shine": "false", "url": "\(base)/icon.png"] as [String: String])
        }
        let manifest: [String: Any] = [
            "items": [[
                "assets": assets,
                "metadata": [
                    "bundle-identifier": signed.bundleID,
                    "bundle-version": signed.version,
                    "kind": "software",
                    "title": signed.name,
                ],
            ]],
        ]
        let manifestData = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        routes["/\(token)/manifest.plist"] = .data(manifestData, contentType: "text/xml")
        server.setRoutes(routes)

        // itms-services wants the manifest URL fully percent-encoded.
        let encoded = "\(base)/manifest.plist".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            throw KilnError("无法生成安装链接")
        }

        beginBackgroundWindow()
        phase = .waitingForConfirmation(signed.name)
        let opened = await UIApplication.shared.open(url)
        if !opened {
            phase = .failed("系统拒绝打开安装链接")
            throw KilnError("系统拒绝打开安装链接")
        }
    }

    private func didReceive(_ line: String) {
        requestLog.append(line)
        if line.hasSuffix("/app.ipa"), case let .waitingForConfirmation(name) = phase {
            phase = .downloading(name)
        }
        if line.hasSuffix("/manifest.plist") {
            requestLog.append("系统已读取安装清单")
        }
    }

    func reset() {
        phase = .idle
    }

    /// Keeps the server alive for a while if the user leaves the app during installation.
    private func beginBackgroundWindow() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "kiln.install") { [weak self] in
            Task { @MainActor in self?.endBackgroundWindow() }
        }
    }

    private func endBackgroundWindow() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func stopServer() {
        server.stop()
        endBackgroundWindow()
        phase = .idle
    }
}
