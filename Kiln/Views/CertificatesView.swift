import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject private var store: KilnStore
    @State private var creating = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                if store.identities.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("还没有证书").font(.headline)
                        Text("用 App Store Connect API 密钥在手机上直接申请证书（私钥只保存在本机钥匙串），或导入已有的 .p12。")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                }
                ForEach(store.identities) { identity in
                    NavigationLink(value: identity.id) { IdentityRow(identity: identity) }
                }
            }
            .navigationTitle("证书")
            .navigationDestination(for: UUID.self) { CertificateDetailView(identityID: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { creating = true } label: { Label("申请新证书", systemImage: "wand.and.stars") }
                        Button { importing = true } label: { Label("导入 .p12", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $creating) { CreateCertificateSheet() }
            .sheet(isPresented: $importing) { ImportIdentitySheet() }
        }
    }
}

struct IdentityRow: View {
    let identity: SigningIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(identity.commonName).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                StatusBadge(text: Format.remaining(identity.notAfter), color: Format.expiryColor(identity.notAfter))
                StatusBadge(text: identity.isAppStoreConnect ? "API" : "导入", color: .blue)
                Text("\(identity.teamName) · \(identity.teamID)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Create via App Store Connect

struct CreateCertificateSheet: View {
    @EnvironmentObject private var store: KilnStore
    @Environment(\.dismiss) private var dismiss
    @State private var type = "DEVELOPMENT"
    @State private var running = false
    @State private var error: ErrorMessage?

    var body: some View {
        NavigationStack {
            Form {
                if !store.settings.isASCConfigured {
                    Section {
                        Label("请先在「设置 → 开发者账号」中添加 App Store Connect API 密钥。", systemImage: "key")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Picker("类型", selection: $type) {
                        Text("Apple Development").tag("DEVELOPMENT")
                        Text("Apple Distribution（Ad Hoc）").tag("DISTRIBUTION")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("证书类型")
                } footer: {
                    Text(type == "DEVELOPMENT"
                         ? "开发证书：可安装到已注册设备，支持调试。每个账号数量有限。"
                         : "发布证书：用于 Ad Hoc 描述文件，同样只能装到已注册设备。每个账号最多 3 个。")
                }
                Section {
                    Text("Kiln 会在本机生成 RSA-2048 私钥和 CSR，只把 CSR 发送给 Apple。私钥保存在本机钥匙串，可随时导出为 .p12。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("申请证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if running { ProgressView() } else {
                        Button("申请", action: create).disabled(!store.settings.isASCConfigured)
                    }
                }
            }
            .interactiveDismissDisabled(running)
            .errorAlert($error)
        }
    }

    private func create() {
        running = true
        Task {
            defer { running = false }
            do {
                _ = try await store.createASCIdentity(type: type)
                dismiss()
            } catch {
                self.error = ErrorMessage(error)
            }
        }
    }
}

// MARK: - Import p12

struct ImportIdentitySheet: View {
    private enum Target { case p12, profile }

    @EnvironmentObject private var store: KilnStore
    @Environment(\.dismiss) private var dismiss
    @State private var p12: (name: String, data: Data)?
    @State private var profile: (name: String, data: Data)?
    @State private var password = ""
    @State private var target: Target?
    @State private var error: ErrorMessage?

    var body: some View {
        NavigationStack {
            Form {
                Section("证书") {
                    Button { target = .p12 } label: {
                        LabeledValue(label: ".p12 文件", value: p12?.name ?? "选择…")
                    }
                    SecureField("p12 密码", text: $password)
                }
                Section {
                    Button { target = .profile } label: {
                        LabeledValue(label: "描述文件", value: profile?.name ?? "选择…（可选）")
                    }
                } footer: {
                    Text("导入的证书无法自动生成描述文件，签名时需要使用与之配套的 .mobileprovision（可在详情页继续添加）。")
                }
            }
            .navigationTitle("导入证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("导入", action: save).disabled(p12 == nil) }
            }
            .fileImporter(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                          allowedContentTypes: target == .profile ? [.mobileProvision, .data] : [.p12, .data]) { result in
                let which = target
                target = nil
                guard case let .success(url) = result else { return }
                do {
                    let data = try readPicked(url)
                    if which == .profile { profile = (url.lastPathComponent, data) } else { p12 = (url.lastPathComponent, data) }
                } catch {
                    self.error = ErrorMessage(error)
                }
            }
            .errorAlert($error)
        }
    }

    private func save() {
        guard let p12 else { return }
        do {
            _ = try store.importIdentity(p12: p12.data, password: password, profileData: profile?.data)
            dismiss()
        } catch {
            self.error = ErrorMessage(error)
        }
    }
}

// MARK: - Detail

struct CertificateDetailView: View {
    let identityID: UUID

    @EnvironmentObject private var store: KilnStore
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var addingProfile = false
    @State private var confirmDelete = false
    @State private var share: ShareItem?
    @State private var error: ErrorMessage?

    var body: some View {
        if let identity = store.identity(identityID) {
            content(identity)
        } else {
            Text("证书已删除").foregroundStyle(.secondary)
        }
    }

    private func content(_ identity: SigningIdentity) -> some View {
        Form {
            Section("证书") {
                LabeledValue(label: "名称", value: identity.commonName)
                LabeledValue(label: "类型", value: identity.kindLabel)
                LabeledValue(label: "团队", value: identity.teamName)
                LabeledValue(label: "Team ID", value: identity.teamID, monospaced: true)
                LabeledValue(label: "到期", value: "\(Format.date(identity.notAfter))（\(Format.remaining(identity.notAfter))）")
                LabeledValue(label: "序列号", value: identity.serialNumber, monospaced: true)
                LabeledValue(label: "SHA-1", value: identity.sha1, monospaced: true)
            }

            Section {
                ForEach(identity.profiles) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.bundleIDPattern).font(.system(.subheadline, design: .monospaced))
                        HStack(spacing: 6) {
                            StatusBadge(text: Format.remaining(profile.expiresAt), color: Format.expiryColor(profile.expiresAt))
                            Text("\(profile.deviceUDIDs.count) 台设备 · \(profile.name)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contextMenu {
                        Button { share = ShareItem(urls: [store.profileURL(profile)]) } label: {
                            Label("导出描述文件", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { identity.profiles[$0] }.forEach { store.removeProfile($0, from: identity.id) }
                }
                Button { addingProfile = true } label: { Label("添加描述文件", systemImage: "plus") }
            } header: {
                Text("描述文件")
            } footer: {
                Text(identity.isAppStoreConnect ? "签名时会按 Bundle ID 自动创建/更新。长按可导出。" : "长按可导出。")
            }

            Section {
                Button { exporting = true } label: { Label("导出 .p12 + 描述文件", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("导出的文件同时保存在「文件 → 我的 iPhone → Kiln → Exports」。")
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除证书", systemImage: "trash") }
            }
        }
        .navigationTitle(identity.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $exporting) {
            ExportSheet(identity: identity) { urls in
                exporting = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { share = ShareItem(urls: urls) }
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .fileImporter(isPresented: $addingProfile, allowedContentTypes: [.mobileProvision, .data]) { result in
            guard case let .success(url) = result else { return }
            do { try store.addProfile(try readPicked(url), to: identity.id) } catch { self.error = ErrorMessage(error) }
        }
        .confirmationDialog("删除「\(identity.commonName)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            if identity.isAppStoreConnect {
                Button("删除并在 Apple 吊销", role: .destructive) { delete(identity, revoke: true) }
            }
            Button("仅从本机删除", role: .destructive) { delete(identity, revoke: false) }
        } message: {
            Text("本机保存的私钥会一并删除。若没有导出过 .p12，将无法再用该证书签名。")
        }
        .errorAlert($error)
    }

    private func delete(_ identity: SigningIdentity, revoke: Bool) {
        Task {
            do {
                try await store.deleteIdentity(identity, revoke: revoke)
                dismiss()
            } catch {
                self.error = ErrorMessage(error)
            }
        }
    }
}

struct ExportSheet: View {
    let identity: SigningIdentity
    let onExport: ([URL]) -> Void

    @EnvironmentObject private var store: KilnStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var includeProfiles = true
    @State private var error: ErrorMessage?

    private var valid: Bool { password.count >= 4 && password == confirm }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("设置 p12 密码", text: $password)
                    SecureField("再次输入", text: $confirm)
                } footer: {
                    Text("至少 4 位。导入到其它签名工具或 Mac 钥匙串时需要这个密码。")
                }
                Section {
                    Toggle("同时导出描述文件（\(identity.profiles.count)）", isOn: $includeProfiles)
                }
            }
            .navigationTitle("导出证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") {
                        do {
                            onExport(try store.export(identity, password: password, includeProfiles: includeProfiles))
                        } catch {
                            self.error = ErrorMessage(error)
                        }
                    }
                    .disabled(!valid)
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }
}
