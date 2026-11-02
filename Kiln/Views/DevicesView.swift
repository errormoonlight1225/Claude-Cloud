import SwiftUI
import UIKit

struct DevicesView: View {
    @EnvironmentObject private var store: KilnStore
    @State private var devices: [ASCDevice] = []
    @State private var loading = false
    @State private var adding = false
    @State private var error: ErrorMessage?

    var body: some View {
        NavigationStack {
            List {
                if !store.settings.isASCConfigured {
                    Section {
                        Label("配置 App Store Connect API 密钥后可在此管理设备。", systemImage: "key")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(devices) { device in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(device.attributes.name ?? "未命名").font(.headline)
                                    if !device.isEnabled { StatusBadge(text: "已停用", color: .secondary) }
                                }
                                Text(device.attributes.udid ?? "").font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                Text([device.attributes.model, device.attributes.deviceClass].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    } header: {
                        Text("已注册设备（\(devices.count)）")
                    } footer: {
                        Text("描述文件只会包含这里的设备。新增设备后，下次签名会自动重新生成描述文件。")
                    }
                }
            }
            .overlay { if loading && devices.isEmpty { ProgressView() } }
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .disabled(!store.settings.isASCConfigured)
                }
            }
            .refreshable { await load() }
            .task(id: store.settings.isASCConfigured) { await load() }
            .sheet(isPresented: $adding) {
                AddDeviceSheet { device in devices.insert(device, at: 0) }
            }
            .errorAlert($error)
        }
    }

    private func load() async {
        guard store.settings.isASCConfigured else { return }
        loading = true
        defer { loading = false }
        do {
            devices = try await store.ascClient().devices().sorted {
                ($0.attributes.addedDate ?? .distantPast) > ($1.attributes.addedDate ?? .distantPast)
            }
        } catch {
            self.error = ErrorMessage(error)
        }
    }
}

struct AddDeviceSheet: View {
    let onAdded: (ASCDevice) -> Void

    @EnvironmentObject private var store: KilnStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = UIDevice.current.name
    @State private var udid = ""
    @State private var running = false
    @State private var error: ErrorMessage?

    private var normalized: String { udid.trimmed.uppercased() }
    private var valid: Bool {
        // 40 hex (older devices) or 8-16 hex with a dash (A12 and newer).
        normalized.range(of: #"^([0-9A-F]{40}|[0-9A-F]{8}-[0-9A-F]{16})$"#, options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("设备") {
                    TextField("名称", text: $name)
                    TextField("UDID", text: $udid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    if !udid.isEmpty && !valid {
                        Text("UDID 格式不正确").font(.caption).foregroundStyle(.red)
                    }
                }
                Section("如何获取本机 UDID") {
                    Text("iOS 不允许 App 读取 UDID。可以用以下任一方式获取后粘贴到上面：")
                        .font(.footnote)
                    Text("• 用 Safari 打开可信的 UDID 查询网站，安装其提供的描述文件后复制 UDID\n• 在 Mac 访达 / Windows iTunes 的设备页面点击序列号切换显示 UDID\n• 在 Xcode「Devices and Simulators」中查看 Identifier")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("注册设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if running { ProgressView() } else {
                        Button("注册", action: register).disabled(!valid || name.trimmed.isEmpty)
                    }
                }
            }
            .errorAlert($error)
        }
    }

    private func register() {
        running = true
        Task {
            defer { running = false }
            do {
                let device = try await store.ascClient().registerDevice(name: name.trimmed, udid: normalized)
                onAdded(device)
                dismiss()
            } catch {
                self.error = ErrorMessage(error)
            }
        }
    }
}
