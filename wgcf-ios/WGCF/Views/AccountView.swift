import SwiftUI

/// 对应 `wgcf status` 与 `wgcf update`：账户信息、许可证绑定和设备管理。
struct AccountView: View {
    @Environment(AppModel.self) private var model

    @State private var licenseInput = ""
    @State private var isBindingLicense = false
    @State private var renaming: BoundDevice?
    @State private var nameInput = ""
    @State private var removing: BoundDevice?
    @State private var isConfirmingUnregister = false
    @State private var isConfirmingForget = false
    @State private var accountFileURL: URL?

    var body: some View {
        NavigationStack {
            List {
                accountSection
                licenseSection
                devicesSection
                dangerSection
            }
            .navigationTitle("账户")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await model.refresh() }
            .task {
                if model.account == nil { await model.refresh() }
            }
            .task(id: model.accountFileText) {
                accountFileURL = model.accountFileText.flatMap {
                    TemporaryFile.write($0, name: AccountFile.fileName)
                }
            }
        }
        .busyOverlay(model.isBusy)
        .alert("绑定许可证", isPresented: $isBindingLicense) {
            TextField("xxxxxxxx-xxxxxxxx-xxxxxxxx", text: $licenseInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("绑定") {
                Task { await model.bindLicense(licenseInput) }
            }
        } message: {
            Text("当前设备会被绑定到该许可证所属的账户。同一账户最多 5 台活跃设备。")
        }
        .alert("重命名设备", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { device in
            TextField("设备名称", text: $nameInput)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task { await model.rename(device, to: nameInput) }
            }
        }
        .confirmationDialog("移除这台设备？", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { device in
            Button("移除", role: .destructive) {
                Task { await model.remove(device) }
            }
        } message: { device in
            Text("「\(device.name ?? device.id)」将从账户中移除，它的配置文件会失效。")
        }
        .confirmationDialog("注销当前设备？", isPresented: $isConfirmingUnregister, titleVisibility: .visible) {
            Button("注销并清除", role: .destructive) {
                Task { await model.unregister() }
            }
        } message: {
            Text("会在 Cloudflare 上删除这台设备的注册并清除本地数据，已生成的配置文件将失效。此操作无法撤销。")
        }
        .confirmationDialog("清除本地数据？", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                model.forgetLocalAccount()
            }
        } message: {
            Text("只删除本机保存的凭据，Cloudflare 上的注册保持不变。未导出账户文件的话将无法再管理该设备。")
        }
    }

    // MARK: - 分区

    private var accountSection: some View {
        Section("账户") {
            if let account = model.account {
                LabeledContent("类型", value: Formatting.accountType(account.accountType))
                LabeledContent("WARP+ 流量", value: Formatting.bytes(account.premiumData))
                LabeledContent("配额", value: Formatting.bytes(account.quota))
                LabeledContent("角色", value: Formatting.role(account.role))
                CopyableRow(title: "账户 ID", value: account.id)
            }
            if let credentials = model.credentials {
                CopyableRow(title: "设备 ID", value: credentials.deviceId)
            }
        }
    }

    private var licenseSection: some View {
        Section {
            if let license = model.credentials?.licenseKey, !license.isEmpty {
                CopyableRow(title: "许可证", value: license)
            }
            Button("绑定其他许可证…") {
                licenseInput = ""
                isBindingLicense = true
            }
        } header: {
            Text("WARP+")
        } footer: {
            Text("输入 WARP+ 许可证密钥，可把这台设备并入已有的 WARP+ 账户。")
        }
    }

    private var devicesSection: some View {
        Section("设备（\(model.devices.count)）") {
            ForEach(model.devices) { device in
                DeviceRow(device: device, isCurrent: model.isCurrent(device))
                    .contextMenu { deviceActions(device) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { deviceActions(device) }
            }
        }
    }

    private var dangerSection: some View {
        Section {
            if let accountFileURL {
                ShareLink(item: accountFileURL) {
                    Label("导出 wgcf-account.toml", systemImage: "square.and.arrow.up")
                }
            }
            Button("清除本地数据", role: .destructive) { isConfirmingForget = true }
            Button("注销当前设备", role: .destructive) { isConfirmingUnregister = true }
        } footer: {
            Text("账户文件包含私钥和访问令牌，请妥善保管。")
        }
    }

    @ViewBuilder
    private func deviceActions(_ device: BoundDevice) -> some View {
        if !model.isCurrent(device) {
            Button(role: .destructive) {
                removing = device
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
        let isActive = device.active ?? false
        Button {
            Task { await model.setActive(device, active: !isActive) }
        } label: {
            Label(isActive ? "停用" : "启用", systemImage: isActive ? "pause.circle" : "play.circle")
        }
        .tint(.orange)
        Button {
            nameInput = device.name ?? ""
            renaming = device
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        .tint(.blue)
    }
}

private struct DeviceRow: View {
    let device: BoundDevice
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.name ?? "未命名")
                    .font(.headline)
                if isCurrent {
                    Text("当前")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Spacer()
                Text(device.active == true ? "活跃" : "已停用")
                    .font(.caption)
                    .foregroundStyle(device.active == true ? Color.green : Color.secondary)
            }
            Text([device.model, device.type, Formatting.role(device.role)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("创建于 \(Formatting.date(device.created))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(device.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

/// 点按即可复制内容的行。
struct CopyableRow: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .imageScale(.small)
            }
        }
    }
}

enum TemporaryFile {
    /// 把文本写入临时目录下的独立子目录，返回的 URL 可交给分享面板。
    static func write(_ text: String, name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}
