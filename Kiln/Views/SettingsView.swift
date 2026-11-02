import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: KilnStore
    @EnvironmentObject private var installer: Installer

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ASCAccountView() } label: {
                        HStack {
                            Label("开发者账号", systemImage: "person.badge.key")
                            Spacer()
                            Text(store.settings.isASCConfigured ? store.settings.ascKeyID : "未配置")
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Bundle ID 前缀，如 com.yourname", text: $store.settings.bundleIDPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("App Store Connect")
                } footer: {
                    Text("使用 API 密钥申请证书时，新 Bundle ID 默认为「前缀.原 Bundle ID」，避免与原开发者冲突。")
                }

                Section {
                    NavigationLink { ServerSettingsView() } label: {
                        HStack {
                            Label("本机安装服务", systemImage: "lock.shield")
                            Spacer()
                            Text(store.settings.isServerConfigured ? store.settings.serverDomain : "未配置")
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } header: {
                    Text("安装")
                } footer: {
                    Text("签名后的 IPA 通过 itms-services 由系统直接安装，下载只在本机回环地址上进行，不需要电脑、配对文件或 VPN。")
                }

                Section("默认签名选项") {
                    Toggle("移除 App 扩展", isOn: $store.settings.defaultRemoveExtensions)
                    Toggle("移除 Watch App", isOn: $store.settings.defaultRemoveWatchApp)
                    Toggle("移除设备型号限制", isOn: $store.settings.defaultRemoveUISupportedDevices)
                }

                Section("关于") {
                    LabeledValue(label: "版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    NavigationLink("开源许可") { LicensesView() }
                }
            }
            .navigationTitle("设置")
        }
    }
}

// MARK: - App Store Connect API key

struct ASCAccountView: View {
    @EnvironmentObject private var store: KilnStore
    @State private var issuerID = ""
    @State private var keyID = ""
    @State private var keyPEM = ""
    @State private var keyFileName = ""
    @State private var picking = false
    @State private var running = false
    @State private var saved = false
    @State private var error: ErrorMessage?

    var body: some View {
        Form {
            Section {
                TextField("Issuer ID（个人密钥留空）", text: $issuerID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                TextField("Key ID", text: $keyID)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button { picking = true } label: {
                    LabeledValue(label: "私钥 .p8", value: keyFileName.isEmpty ? (store.settings.hasASCKey ? "已保存（可替换）" : "选择…") : keyFileName)
                }
            } header: {
                Text("API 密钥")
            } footer: {
                Text("在 App Store Connect →「用户和访问」→「集成」→「App Store Connect API」创建团队密钥（角色选 Admin 或 Developer），下载 AuthKey_XXXX.p8。密钥只保存在本机钥匙串。")
            }

            Section {
                Button(action: save) {
                    HStack {
                        Text(saved ? "已验证并保存" : "验证并保存")
                        Spacer()
                        if running { ProgressView() } else if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }
                .disabled(running || keyID.trimmed.isEmpty || (keyPEM.isEmpty && !store.settings.hasASCKey))
            }

            if store.settings.hasASCKey {
                Section {
                    Button("移除 API 密钥", role: .destructive) {
                        store.removeASCCredentials()
                        issuerID = ""; keyID = ""; keyPEM = ""; keyFileName = ""
                    }
                }
            }

            Section("为什么不是 Apple ID 密码登录？") {
                Text("Apple ID 账号密码登录走的是 Apple 的私有认证协议，需要额外的「anisette」设备数据，在纯 iOS 环境下只能依赖第三方服务器提供，这正是 SideStore 等工具需要配对文件或外部服务的原因。Kiln 改用 Apple 官方的 App Store Connect API：不需要电脑、不经第三方、不会触发双重认证，但需要付费开发者账号。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("开发者账号")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            issuerID = store.settings.ascIssuerID
            keyID = store.settings.ascKeyID
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.p8, .data, .plainText]) { result in
            guard case let .success(url) = result else { return }
            do {
                let data = try readPicked(url)
                guard let text = String(data: data, encoding: .utf8), text.contains("PRIVATE KEY") else {
                    throw KilnError("这不是 .p8 私钥文件")
                }
                keyPEM = text
                keyFileName = url.lastPathComponent
                // AuthKey_ABC123DEFG.p8 -> Key ID
                if keyID.isEmpty, let range = url.lastPathComponent.range(of: #"(?<=AuthKey_)[A-Z0-9]+"#, options: .regularExpression) {
                    keyID = String(url.lastPathComponent[range])
                }
            } catch {
                self.error = ErrorMessage(error)
            }
        }
        .errorAlert($error)
    }

    private func save() {
        let pem = keyPEM.isEmpty ? (Keychain.string(for: Keychain.ascPrivateKey) ?? "") : keyPEM
        running = true
        saved = false
        Task {
            defer { running = false }
            do {
                try await store.saveASCCredentials(issuerID: issuerID, keyID: keyID, privateKeyPEM: pem)
                saved = true
            } catch {
                self.error = ErrorMessage(error)
            }
        }
    }
}

// MARK: - Local install server

struct ServerSettingsView: View {
    private enum Target { case bundle, certificate, key }

    @EnvironmentObject private var store: KilnStore
    @EnvironmentObject private var installer: Installer
    @State private var mode = 0
    @State private var bundle: (name: String, data: Data)?
    @State private var certificate: (name: String, data: Data)?
    @State private var key: (name: String, data: Data)?
    @State private var password = ""
    @State private var target: Target?
    @State private var portText = ""
    @State private var error: ErrorMessage?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if store.settings.hasServerIdentity {
                    LabeledValue(label: "证书", value: store.settings.serverCertificateName)
                    if let expiry = store.settings.serverCertificateExpiry {
                        LabeledValue(label: "到期", value: "\(Format.date(expiry))（\(Format.remaining(expiry))）")
                    }
                } else {
                    Text("未导入").foregroundStyle(.secondary)
                }
                TextField("域名（必须解析到 127.0.0.1）", text: $store.settings.serverDomain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("端口", text: $portText)
                    .keyboardType(.numberPad)
                    .onChange(of: portText) { value in
                        if let port = UInt16(value), port >= 1024 { store.settings.serverPort = port }
                    }
            } header: {
                Text("当前配置")
            }

            Section {
                Picker("格式", selection: $mode) {
                    Text(".p12").tag(0)
                    Text("证书 + 私钥 (PEM)").tag(1)
                }
                .pickerStyle(.segmented)
                if mode == 0 {
                    Button { target = .bundle } label: { LabeledValue(label: ".p12 / .pfx", value: bundle?.name ?? "选择…") }
                } else {
                    Button { target = .certificate } label: { LabeledValue(label: "证书（含证书链）", value: certificate?.name ?? "选择…") }
                    Button { target = .key } label: { LabeledValue(label: "私钥", value: key?.name ?? "选择…") }
                }
                SecureField("密码（如有）", text: $password)
                Button("导入 TLS 证书", action: importIdentity)
                    .disabled(mode == 0 ? bundle == nil : (certificate == nil || key == nil))
                if let message { Text(message).font(.footnote).foregroundStyle(.green) }
            } header: {
                Text("导入 TLS 证书")
            } footer: {
                Text("""
                iOS 只接受来自 HTTPS 且证书受信任的安装清单。请准备一个由公共 CA 签发、域名解析到 127.0.0.1 的证书，例如公开提供的 localhost.direct 证书（*.localhost.direct），或你自己的域名添加 A 记录指向 127.0.0.1 后用 Let's Encrypt 申请。服务只监听本机回环接口，局域网内其它设备无法访问。
                """)
            }

            if store.settings.hasServerIdentity {
                Section {
                    Button("停止安装服务") { installer.stopServer() }
                    Button("移除 TLS 证书", role: .destructive) {
                        installer.stopServer()
                        store.removeServerIdentity()
                    }
                }
            }
        }
        .navigationTitle("本机安装服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { portText = String(store.settings.serverPort) }
        .fileImporter(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                      allowedContentTypes: [.data, .x509Certificate, .pkcs12, .plainText]) { result in
            let which = target
            target = nil
            guard case let .success(url) = result else { return }
            do {
                let picked = (url.lastPathComponent, try readPicked(url))
                switch which {
                case .bundle: bundle = picked
                case .certificate: certificate = picked
                case .key: key = picked
                case nil: break
                }
            } catch {
                self.error = ErrorMessage(error)
            }
        }
        .errorAlert($error)
    }

    private func importIdentity() {
        do {
            if mode == 0, let bundle {
                try store.importServerIdentity(certificate: bundle.data, privateKey: nil, password: password)
            } else if let certificate, let key {
                try store.importServerIdentity(certificate: certificate.data, privateKey: key.data, password: password)
            }
            installer.stopServer()
            message = "已导入：\(store.settings.serverCertificateName)"
        } catch {
            self.error = ErrorMessage(error)
        }
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text("zsign — MIT License\nCopyright (c) zhlynn\nhttps://github.com/zhlynn/zsign")
                Text("OpenSSL — Apache License 2.0\nhttps://www.openssl.org\n通过 krzyzanowskim/OpenSSL-Package 集成")
                Text("zlib / minizip — zlib License")
            }
            .font(.footnote)
        }
        .navigationTitle("开源许可")
    }
}
