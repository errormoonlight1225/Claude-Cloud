import SwiftUI
import UIKit

@MainActor
final class CertificateStore: ObservableObject {
    @Published private(set) var certificates: [ExportedCertificate] = []
    @Published private(set) var log: [String] = []
    @Published var alert: AlertMessage?
    @Published private(set) var waitingForSideStore = false

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let runsInLiveContainer = LiveContainerReader.runsInLiveContainer

    // MARK: - Getting the certificate

    /// Way 1: ask SideStore over its `sidestore://certificate` deep link.
    func requestFromSideStore() {
        guard let url = SideStoreLink.requestURL else { return }
        if runsInLiveContainer {
            addLog("提示：在 LiveContainer 中，SideStore 的回调链接无法返回本应用，请改用「从 LiveContainer 读取」。")
        }
        addLog("正在请求 SideStore 导出证书…")
        waitingForSideStore = true
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self, !opened else { return }
                self.waitingForSideStore = false
                self.addLog("⛔️ 无法打开 SideStore。")
                self.alert = AlertMessage(title: "无法打开 SideStore",
                                          message: "这台设备上没有安装 SideStore（或其版本不支持证书导出）。请先安装最新版 SideStore 并登录 Apple ID。")
            }
        }
    }

    /// Way 2: read it straight from LiveContainer's built-in SideStore.
    func readFromLiveContainer() {
        addLog("正在从 LiveContainer 读取…")
        let found = LiveContainerReader.find { addLog($0) }
        if found.isEmpty {
            alert = AlertMessage(title: "未找到证书",
                                 message: "LiveContainer 中没有可读取的 SideStore 证书。请先在内置 SideStore 中登录，或在 LiveContainer 设置中点「Import Certificate from SideStore」。")
        }
        for certificate in found { add(certificate) }
    }

    /// SideStore's reply arrives as an `sscertexport://` URL.
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == SideStoreLink.scheme else { return }
        waitingForSideStore = false
        do {
            add(try SideStoreLink.parse(url))
        } catch {
            addLog("⛔️ \(error.localizedDescription)")
            alert = AlertMessage(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func add(_ certificate: ExportedCertificate) {
        if certificates.contains(certificate) {
            addLog("该证书已在列表中（\(certificate.source)）。")
            return
        }
        certificates.insert(certificate, at: 0)
        addLog("✅ 已获取证书：\(certificate.source)，\(certificate.p12Data.count) 字节。")
    }

    /// Re-packs the certificate under a new password and adds the result to
    /// the list. Returns whether it worked.
    @discardableResult
    func changePassword(of certificate: ExportedCertificate, to newPassword: String) -> Bool {
        do {
            let rewrapped = try P12Builder.rewrap(certificate, newPassword: newPassword)
            certificates.insert(rewrapped, at: 0)
            addLog("✅ 已用新密码重新打包证书（\(rewrapped.p12Data.count) 字节）。")
            alert = AlertMessage(title: "已生成",
                                 message: "新密码的证书已加到主页列表最上方，打开它即可导出。")
            return true
        } catch {
            addLog("⛔️ 改密码失败：\(error.localizedDescription)")
            alert = AlertMessage(title: "改密码失败", message: error.localizedDescription)
            return false
        }
    }

    func remove(_ certificate: ExportedCertificate) {
        certificates.removeAll { $0 == certificate }
    }

    // MARK: - Exporting

    /// Files to hand to the share sheet (written to a temporary folder).
    func shareFiles(for certificate: ExportedCertificate) -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent(certificate.id.uuidString, isDirectory: true)
        do {
            let files = try certificate.write(to: directory)
            return [files.p12, files.password]
        } catch {
            addLog("⛔️ 写入临时文件失败：\(error.localizedDescription)")
            return []
        }
    }

    /// Saves into the app's Documents folder, visible in the Files app under
    /// "On My iPhone › 证书导出".
    func saveToDocuments(_ certificate: ExportedCertificate) {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let files = try certificate.write(to: documents)
            addLog("✅ 已保存：\(files.p12.lastPathComponent)、\(files.password.lastPathComponent)")
            alert = AlertMessage(title: "已保存",
                                 message: "已保存到「文件」App →「我的 iPhone」→「证书导出」：\n\(files.p12.lastPathComponent)\n\(files.password.lastPathComponent)")
        } catch {
            alert = AlertMessage(title: "保存失败", message: error.localizedDescription)
        }
    }

    func copyPassword(_ certificate: ExportedCertificate) {
        UIPasteboard.general.string = certificate.password
        addLog("已复制密码。")
    }

    func copyBase64(_ certificate: ExportedCertificate) {
        UIPasteboard.general.string = certificate.p12Data.base64EncodedString()
        addLog("已复制证书 Base64。")
    }

    private func addLog(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.append("[\(time)] \(line)")
    }
}
