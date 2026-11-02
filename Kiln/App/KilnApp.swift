import SwiftUI

@main
struct KilnApp: App {
    @StateObject private var store = KilnStore()
    @StateObject private var installer = Installer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(installer)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: KilnStore
    @State private var tab = 0
    @State private var error: ErrorMessage?

    var body: some View {
        TabView(selection: $tab) {
            AppsView()
                .tabItem { Label("应用", systemImage: "square.stack.3d.up") }
                .tag(0)
            CertificatesView()
                .tabItem { Label("证书", systemImage: "checkmark.seal") }
                .tag(1)
            DevicesView()
                .tabItem { Label("设备", systemImage: "iphone") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        // "Open in Kiln" from Files / Safari / AirDrop.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task {
                do {
                    switch url.pathExtension.lowercased() {
                    case "ipa":
                        _ = try await store.importIPA(from: url)
                        tab = 0
                    default:
                        throw KilnError("暂不支持直接打开 .\(url.pathExtension) 文件，请在「证书」页导入")
                    }
                } catch {
                    self.error = ErrorMessage(error)
                }
            }
        }
        .errorAlert($error)
    }
}
