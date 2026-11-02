import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @EnvironmentObject private var store: KilnStore
    @EnvironmentObject private var installer: Installer
    @State private var importing = false
    @State private var busy = false
    @State private var error: ErrorMessage?
    @State private var share: ShareItem?

    var body: some View {
        NavigationStack {
            List {
                if store.apps.isEmpty && store.signedApps.isEmpty {
                    emptyState
                }
                if !store.apps.isEmpty {
                    Section("待签名") {
                        ForEach(store.apps) { app in
                            NavigationLink(value: app) { row(app) }
                        }
                        .onDelete { offsets in offsets.map { store.apps[$0] }.forEach(store.deleteApp) }
                    }
                }
                if !store.signedApps.isEmpty {
                    Section("已签名") {
                        ForEach(store.signedApps) { signed in
                            signedRow(signed)
                        }
                        .onDelete { offsets in offsets.map { store.signedApps[$0] }.forEach(store.deleteSigned) }
                    }
                }
            }
            .navigationTitle("应用")
            .navigationDestination(for: ImportedApp.self) { SignView(app: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button { importing = true } label: { Label("导入 IPA", systemImage: "plus") }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipa, .zip, .data]) { result in
                guard case let .success(url) = result else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do { _ = try await store.importIPA(from: url) } catch { self.error = ErrorMessage(error) }
                }
            }
            .safeAreaInset(edge: .bottom) { InstallStatusBar() }
            .sheet(item: $share) { ShareSheet(items: $0.urls) }
            .errorAlert($error)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("还没有应用").font(.headline)
            Text("点右上角 + 从「文件」导入 .ipa，或在其它 App 里用「分享 → Kiln」打开。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }

    private func row(_ app: ImportedApp) -> some View {
        HStack(spacing: 12) {
            AppIcon(image: store.icon(for: app.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(app.version) (\(app.build)) · \(Format.bytes(app.fileSize))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func signedRow(_ signed: SignedApp) -> some View {
        HStack(spacing: 12) {
            AppIcon(image: store.icon(for: signed.sourceAppID), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(signed.name).font(.subheadline.weight(.semibold))
                Text(signed.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(signed.identityName) · \(Format.date(signed.signedAt))")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button { install(signed) } label: { Label("安装到本机", systemImage: "arrow.down.app") }
                Button { share = ShareItem(urls: [store.signedURL(signed)]) } label: {
                    Label("导出 IPA", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
    }

    private func install(_ signed: SignedApp) {
        Task {
            do {
                try await installer.install(signed, ipa: store.signedURL(signed),
                                            icon: store.icon(for: signed.sourceAppID), settings: store.settings)
            } catch {
                self.error = ErrorMessage(error)
            }
        }
    }
}

/// Shows install progress while the system installer is fetching from our local server.
struct InstallStatusBar: View {
    @EnvironmentObject private var installer: Installer

    var body: some View {
        switch installer.phase {
        case .idle:
            EmptyView()
        case .starting:
            bar(icon: "bolt.horizontal", text: "启动本机安装服务…", color: .blue, spinning: true)
        case let .waitingForConfirmation(name):
            bar(icon: "hand.tap", text: "请在系统弹窗中确认安装「\(name)」", color: .blue, spinning: false)
        case let .downloading(name):
            bar(icon: "arrow.down.circle", text: "系统正在安装「\(name)」，请回到主屏幕查看进度", color: .green, spinning: true)
        case let .failed(message):
            bar(icon: "exclamationmark.triangle", text: message, color: .red, spinning: false)
        }
    }

    private func bar(icon: String, text: String, color: Color, spinning: Bool) -> some View {
        HStack(spacing: 10) {
            if spinning { ProgressView() } else { Image(systemName: icon).foregroundStyle(color) }
            Text(text).font(.footnote).lineLimit(2)
            Spacer()
            Button { installer.reset() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}
