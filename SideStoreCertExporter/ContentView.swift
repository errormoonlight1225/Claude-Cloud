import SwiftUI

@main
struct SideStoreCertExporterApp: App {
    @StateObject private var store = CertificateStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { store.handle($0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: CertificateStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.requestFromSideStore()
                    } label: {
                        Label("从 SideStore 获取证书", systemImage: "arrow.down.app")
                    }
                    Button {
                        store.readFromLiveContainer()
                    } label: {
                        Label("从 LiveContainer 读取", systemImage: "shippingbox")
                    }
                    .disabled(!store.runsInLiveContainer)
                } header: {
                    Text("获取")
                } footer: {
                    Text(store.runsInLiveContainer
                         ? "正在 LiveContainer 中运行：请使用「从 LiveContainer 读取」，SideStore 的回调链接无法回到这里。"
                         : "点击后会跳转到 SideStore，在弹窗中选择「Export」，证书会自动回传到本应用。")
                }

                if store.waitingForSideStore {
                    Section {
                        HStack {
                            ProgressView()
                            Text("等待 SideStore 返回证书…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !store.certificates.isEmpty {
                    Section("证书") {
                        ForEach(store.certificates) { certificate in
                            NavigationLink {
                                CertificateDetailView(certificate: certificate)
                            } label: {
                                CertificateRow(certificate: certificate)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { store.certificates[$0] }.forEach(store.remove)
                        }
                    }
                }

                if !store.log.isEmpty {
                    Section("日志") {
                        ForEach(Array(store.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Text("证书和私钥可用来以你的 Apple ID 签名应用。只把导出的文件交给你信任的应用或设备，不要公开分享。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SideStore 证书导出")
            .alert(item: $store.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
        }
    }
}

struct CertificateRow: View {
    let certificate: ExportedCertificate

    var body: some View {
        let details = certificate.details
        VStack(alignment: .leading, spacing: 4) {
            Text(details?.commonName ?? "SideStore 证书")
                .font(.headline)
            Text(certificate.source)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notAfter = details?.notAfter {
                Text("到期：\(notAfter.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(notAfter < Date() ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CertificateDetailView: View {
    @EnvironmentObject private var store: CertificateStore
    let certificate: ExportedCertificate
    @State private var shareFiles: [URL] = []
    @State private var showPassword = false
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        let details = certificate.details
        List {
            Section("信息") {
                LabeledContent("名称", value: details?.commonName ?? "无法解析")
                LabeledContent("序列号", value: details?.serialHex ?? "—")
                if let notAfter = details?.notAfter {
                    LabeledContent("到期时间", value: notAfter.formatted(date: .long, time: .shortened))
                }
                LabeledContent("来源", value: certificate.source)
                LabeledContent("大小", value: "\(certificate.p12Data.count) 字节")
                if details == nil {
                    Text("iOS 无法用该密码打开此 .p12，但仍可原样导出。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if details?.workingPassword.isEmpty == true, !certificate.password.isEmpty {
                    Text("此 .p12 未加密，导入时密码可留空或填写下方密码。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("密码") {
                HStack {
                    Text(showPassword ? (certificate.password.isEmpty ? "（空）" : certificate.password)
                                      : String(repeating: "•", count: 12))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(showPassword ? "隐藏" : "显示") { showPassword.toggle() }
                        .buttonStyle(.borderless)
                }
                Button {
                    store.copyPassword(certificate)
                } label: {
                    Label("复制密码", systemImage: "key")
                }
            }

            Section {
                SecureField("新密码", text: $newPassword)
                    .textContentType(.newPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("再输入一次", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    if store.changePassword(of: certificate, to: newPassword) {
                        newPassword = ""
                        confirmPassword = ""
                    }
                } label: {
                    Label("生成新密码的 .p12", systemImage: "lock.rotation")
                }
                .disabled(newPassword.isEmpty || newPassword != confirmPassword || details == nil)
            } header: {
                Text("修改密码")
            } footer: {
                if details == nil {
                    Text("原 .p12 无法打开，不能改密码。")
                } else if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    Text("两次输入的密码不一致。").foregroundStyle(.red)
                } else {
                    Text("用新密码重新打包证书和私钥（3DES + SHA-1，兼容 iOS、OpenSSL 和常见签名工具）。新证书会出现在主页列表中，原证书不受影响。")
                }
            }

            Section {
                if !shareFiles.isEmpty {
                    ShareLink(items: shareFiles) {
                        Label("分享 / 存储到文件（.p12 + 密码）", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    store.saveToDocuments(certificate)
                } label: {
                    Label("保存到本应用文件夹", systemImage: "folder")
                }
                Button {
                    store.copyBase64(certificate)
                } label: {
                    Label("复制证书 Base64", systemImage: "doc.on.doc")
                }
            } header: {
                Text("导出")
            } footer: {
                Text("导出的 .p12 可导入 LiveContainer（从文件导入证书）、Feather、ESign 等签名工具。")
            }
        }
        .navigationTitle("证书详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if shareFiles.isEmpty { shareFiles = store.shareFiles(for: certificate) }
        }
    }
}
