import SwiftUI

struct SignView: View {
    let app: ImportedApp

    @EnvironmentObject private var store: KilnStore
    @EnvironmentObject private var installer: Installer
    @State private var identityID: UUID?
    @State private var bundleID = ""
    @State private var displayName = ""
    @State private var version = ""
    @State private var minimumOS = ""
    @State private var removeExtensions = false
    @State private var removeWatchApp = true
    @State private var removeUISupportedDevices = true
    @State private var enableFileSharing = false
    @State private var log: [String] = []
    @State private var running = false
    @State private var result: SignedApp?
    @State private var error: ErrorMessage?
    @State private var share: ShareItem?

    private var usableIdentities: [SigningIdentity] { store.identities.filter { !$0.isExpired } }
    private var selected: SigningIdentity? { identityID.flatMap(store.identity) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIcon(image: store.icon(for: app.id), size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        Text("\(app.version) (\(app.build)) · \(Format.bytes(app.fileSize))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if usableIdentities.isEmpty {
                    Text("没有可用证书。请先在「证书」页申请或导入。").foregroundStyle(.secondary)
                } else {
                    Picker("签名证书", selection: $identityID) {
                        ForEach(usableIdentities) { identity in
                            Text(identity.commonName).tag(Optional(identity.id))
                        }
                    }
                    .onChange(of: identityID) { _ in bundleID = store.suggestedBundleID(for: app, identity: selected) }
                }
            } header: {
                Text("证书")
            } footer: {
                if let selected {
                    Text(selected.isAppStoreConnect
                         ? "将自动注册 App ID 并生成包含所有已注册设备的描述文件。"
                         : "使用该证书导入的描述文件（\(selected.profiles.count) 个）。")
                }
            }

            Section("应用信息") {
                TextField("Bundle ID", text: $bundleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                TextField("显示名称", text: $displayName)
                TextField("版本号", text: $version)
                    .keyboardType(.decimalPad)
                TextField("最低系统版本（可选，如 15.0）", text: $minimumOS)
                    .keyboardType(.decimalPad)
            }

            Section {
                Toggle("移除 App 扩展（\(app.extensionBundleIDs.count) 个）", isOn: $removeExtensions)
                    .disabled(app.extensionBundleIDs.isEmpty)
                Toggle("移除 Watch App", isOn: $removeWatchApp)
                    .disabled(!app.hasWatchApp)
                Toggle("移除设备型号限制", isOn: $removeUISupportedDevices)
                Toggle("在「文件」中显示应用文稿", isOn: $enableFileSharing)
            } header: {
                Text("选项")
            } footer: {
                if !app.extensionBundleIDs.isEmpty && !removeExtensions {
                    Text("保留扩展时，每个扩展都需要单独的 App ID 和描述文件。")
                }
            }

            Section {
                Button(action: sign) {
                    HStack {
                        Spacer()
                        if running { ProgressView().padding(.trailing, 6) }
                        Text(running ? "正在签名…" : "签名").bold()
                        Spacer()
                    }
                }
                .disabled(running || selected == nil || bundleID.trimmed.isEmpty)
            }

            if let result {
                Section("签名完成") {
                    Button { install(result) } label: { Label("安装到本机", systemImage: "arrow.down.app") }
                    Button { share = ShareItem(urls: [store.signedURL(result)]) } label: {
                        Label("导出 IPA", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if !log.isEmpty {
                Section("日志") { LogConsole(lines: log) }
            }
        }
        .navigationTitle("签名")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { InstallStatusBar() }
        .onAppear(perform: setDefaults)
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .errorAlert($error)
    }

    private func setDefaults() {
        guard identityID == nil else { return }
        identityID = usableIdentities.first?.id
        bundleID = store.suggestedBundleID(for: app, identity: selected)
        displayName = app.name
        version = app.version
        removeExtensions = store.settings.defaultRemoveExtensions
        removeWatchApp = store.settings.defaultRemoveWatchApp
        removeUISupportedDevices = store.settings.defaultRemoveUISupportedDevices
    }

    private func sign() {
        guard let identityID else { return }
        let config = SignConfiguration(identityID: identityID, bundleID: bundleID, displayName: displayName,
                                       version: version, minimumOSVersion: minimumOS,
                                       removeExtensions: removeExtensions, removeWatchApp: removeWatchApp,
                                       removeUISupportedDevices: removeUISupportedDevices,
                                       enableFileSharing: enableFileSharing)
        running = true
        result = nil
        log = []
        Task {
            defer { running = false }
            do {
                result = try await store.sign(app, configuration: config) { line in
                    Task { @MainActor in log.append(line) }
                }
            } catch {
                log.append("错误：\(error.localizedDescription)")
                self.error = ErrorMessage(error)
            }
        }
    }

    private func install(_ signed: SignedApp) {
        Task {
            do {
                try await installer.install(signed, ipa: store.signedURL(signed),
                                            icon: store.icon(for: app.id), settings: store.settings)
            } catch {
                self.error = ErrorMessage(error)
            }
        }
    }
}
