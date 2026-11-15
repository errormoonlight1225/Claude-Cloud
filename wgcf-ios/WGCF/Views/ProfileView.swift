import CoreImage.CIFilterBuiltins
import SwiftUI

/// 对应 `wgcf generate`：生成、预览并导出 WireGuard 配置文件。
struct ProfileView: View {
    @Environment(AppModel.self) private var model

    @State private var profileURL: URL?
    @State private var isShowingQRCode = false
    @State private var copied = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                if let profile = model.profileText {
                    exportSection(profile)
                    optionsSection(options: $model.options)
                    previewSection(profile)
                } else {
                    ContentUnavailableView {
                        Label("暂无配置", systemImage: "doc.questionmark")
                    } description: {
                        Text("还没有从 Cloudflare 获取到隧道参数，或当前选项无法生成有效配置。")
                    } actions: {
                        Button("重新获取") {
                            Task { await model.refresh() }
                        }
                        Button("恢复默认选项") {
                            model.options = ProfileOptions()
                        }
                    }
                }
            }
            .navigationTitle("配置")
            .scrollDismissesKeyboard(.interactively)
            .task(id: model.profileText) {
                profileURL = model.profileText.flatMap {
                    TemporaryFile.write($0, name: WireGuardProfile.fileName)
                }
            }
            .sheet(isPresented: $isShowingQRCode) {
                QRCodeSheet(text: model.profileText ?? "")
            }
        }
        .busyOverlay(model.isBusy)
    }

    private func exportSection(_ profile: String) -> some View {
        Section {
            if let profileURL {
                ShareLink(item: profileURL) {
                    Label("分享 / 在 WireGuard 中打开", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                isShowingQRCode = true
            } label: {
                Label("显示二维码", systemImage: "qrcode")
            }
            Button {
                UIPasteboard.general.string = profile
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制配置文本", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        } footer: {
            Text("在分享面板中选择 WireGuard 即可导入隧道；二维码可供另一台设备上的 WireGuard 扫描。隧道启用后没有收到数据时，可以在下方换一个端点或端口再重新导入。")
        }
    }

    private func optionsSection(options: Binding<ProfileOptions>) -> some View {
        Section("选项") {
            Picker("端点", selection: options.endpointMode) {
                ForEach(EndpointMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("端口", selection: options.port) {
                Text("默认").tag(Int?.none)
                ForEach(WireGuardProfile.knownPorts, id: \.self) { port in
                    Text(String(port)).tag(Int?.some(port))
                }
            }
            Toggle("保持连接 (PersistentKeepalive)", isOn: Binding(
                get: { options.wrappedValue.keepalive > 0 },
                set: { options.wrappedValue.keepalive = $0 ? 25 : 0 }
            ))
            if options.wrappedValue.keepalive > 0 {
                Stepper(
                    "间隔 \(options.wrappedValue.keepalive) 秒",
                    value: options.keepalive, in: 1...ProfileOptions.maxKeepalive, step: 5)
            }
            Stepper("MTU \(options.wrappedValue.mtu)", value: options.mtu, in: 576...1500, step: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text("DNS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("留空则不写入 DNS", text: options.dns, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("AllowedIPs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(ProfileOptions.defaultAllowedIPs, text: options.allowedIPs, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button("恢复默认") {
                options.wrappedValue = ProfileOptions()
            }
        }
    }

    private func previewSection(_ profile: String) -> some View {
        Section {
            Text(profile)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text(WireGuardProfile.fileName)
        } footer: {
            Text("配置中包含私钥，请勿分享给他人。")
        }
    }
}

private struct QRCodeSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = QRCode.image(for: text) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: 360)
                } else {
                    Text("无法生成二维码。")
                }
                Text("在另一台设备的 WireGuard 中选择「从二维码创建」并扫描。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
