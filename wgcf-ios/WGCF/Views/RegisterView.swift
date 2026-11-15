import SwiftUI
import UniformTypeIdentifiers

/// 对应 `wgcf register`：注册新设备，或导入已有的 wgcf-account.toml。
struct RegisterView: View {
    @Environment(AppModel.self) private var model

    @State private var deviceName = ""
    @State private var deviceModel = "PC"
    @State private var privateKey = ""
    @State private var acceptedTOS = false
    @State private var isImporting = false

    private static let tosURL = URL(string: "https://www.cloudflare.com/application/terms/")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("注册 Cloudflare WARP 设备，并生成可导入 WireGuard 的配置文件。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    LabeledContent("设备名称") {
                        TextField("留空则随机生成", text: $deviceName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("设备型号") {
                        TextField("PC", text: $deviceModel)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("设备")
                } footer: {
                    Text("名称和型号会显示在 1.1.1.1 应用的设备列表中。")
                }

                Section {
                    TextField("留空则自动生成新密钥", text: $privateKey, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("已有 WireGuard 私钥（可选）")
                }

                Section {
                    Toggle("我已阅读并同意 Cloudflare 服务条款", isOn: $acceptedTOS)
                    Link("查看服务条款", destination: Self.tosURL)
                } footer: {
                    Text("本应用是非官方工具，与 Cloudflare 没有任何关联。")
                }

                Section {
                    Button {
                        Task {
                            await model.register(
                                deviceName: deviceName, deviceModel: deviceModel, existingPrivateKey: privateKey)
                        }
                    } label: {
                        Text("注册")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(!acceptedTOS)
                }

                Section {
                    Button("导入 wgcf-account.toml") { isImporting = true }
                } footer: {
                    Text("已经用 wgcf 命令行注册过？可以直接导入账户文件。")
                }
            }
            .navigationTitle("WGCF")
            .scrollDismissesKeyboard(.interactively)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
                importFile(result)
            }
        }
        .busyOverlay(model.isBusy)
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                Task { await model.importAccountFile(text) }
            } catch {
                model.errorMessage = "无法读取文件：\(error.localizedDescription)"
            }
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }
}
