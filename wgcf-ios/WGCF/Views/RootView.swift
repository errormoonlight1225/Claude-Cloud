import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isRegistered {
                TabView {
                    AccountView()
                        .tabItem { Label("账户", systemImage: "person.crop.circle") }
                    ProfileView()
                        .tabItem { Label("配置", systemImage: "doc.text") }
                    TraceView()
                        .tabItem { Label("检测", systemImage: "waveform.path.ecg") }
                }
            } else {
                RegisterView()
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// 覆盖在内容上的进度指示，网络请求期间显示。
struct BusyOverlay: ViewModifier {
    let isBusy: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isBusy)
            .overlay {
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
    }
}

extension View {
    func busyOverlay(_ isBusy: Bool) -> some View {
        modifier(BusyOverlay(isBusy: isBusy))
    }
}
