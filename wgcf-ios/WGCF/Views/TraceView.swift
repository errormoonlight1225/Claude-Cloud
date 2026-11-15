import SwiftUI

/// 对应 `wgcf trace`：查看当前网络连接是否经过 WARP。
struct TraceView: View {
    @State private var result: TraceResult?
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                } footer: {
                    Text("在 WireGuard 中启用隧道后回到这里重新检测，可确认 WARP 是否生效。")
                }
                if let result {
                    Section("详细信息") {
                        ForEach(result.entries) { entry in
                            LabeledContent(entry.key) {
                                Text(entry.value)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("检测")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if isLoading {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在检测…")
            }
        } else if let errorText {
            VStack(alignment: .leading, spacing: 6) {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("如果 WireGuard 隧道已启用但没有收到数据，说明握手没有成功，可在「配置」页换一个端点或端口后重新导入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let result {
            let status = WarpStatus(result.warp)
            HStack(spacing: 14) {
                Image(systemName: status.symbol)
                    .font(.system(size: 36))
                    .foregroundStyle(status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.headline)
                    if let ip = result["ip"] {
                        Text([ip, result["loc"], result["colo"]].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // 每次使用新的会话，避免复用隧道切换之前建立的连接。
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            result = try await TraceResult.fetch(session: session)
            errorText = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            result = nil
            errorText = "检测失败：\(error.localizedDescription)"
        }
    }
}

private struct WarpStatus {
    let title: String
    let symbol: String
    let color: Color

    init(_ value: String?) {
        switch value {
        case "on":
            title = "WARP 已启用"
            symbol = "checkmark.shield.fill"
            color = .green
        case "plus":
            title = "WARP+ 已启用"
            symbol = "bolt.shield.fill"
            color = .orange
        default:
            title = "未通过 WARP 连接"
            symbol = "shield.slash"
            color = .secondary
        }
    }
}
