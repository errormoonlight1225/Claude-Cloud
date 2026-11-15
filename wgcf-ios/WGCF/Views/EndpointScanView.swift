import SwiftUI

/// 端点测速：找出当前网络下能完成 WireGuard 握手的 WARP 端点。
struct EndpointScanView: View {
    @Binding var options: ProfileOptions
    @Environment(\.dismiss) private var dismiss

    @State private var results: [EndpointScanner.Result] = []
    @State private var done = 0
    @State private var total = 0
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var scanTask: Task<Void, Never>?

    private static let candidateCount = 240
    private static let shownResults = 30

    var body: some View {
        List {
            Section {
                if isScanning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("已测试 \(String(done)) / \(String(total))，可用 \(String(results.count)) 个")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("停止", role: .destructive) { scanTask?.cancel() }
                } else {
                    Button {
                        start()
                    } label: {
                        Label(hasScanned ? "重新测速" : "开始测速", systemImage: "speedometer")
                    }
                }
            } footer: {
                Text("测速前请先在 WireGuard 中关闭隧道，否则测到的是隧道内的结果。测速会向 Cloudflare 的多个地址发送握手包，大约需要十几秒。")
            }

            if !results.isEmpty {
                Section {
                    ForEach(results.prefix(Self.shownResults)) { result in
                        Button {
                            options.customEndpoint = result.candidate.endpoint
                            dismiss()
                        } label: {
                            HStack {
                                Text(result.candidate.endpoint)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(String(result.milliseconds)) ms")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if options.customEndpoint == result.candidate.endpoint {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text("可用端点（按延迟排序）")
                } footer: {
                    Text("点选一个端点后回到「配置」页，重新分享到 WireGuard 导入。")
                }
            } else if hasScanned && !isScanning {
                Section {
                    Label("没有端点响应", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("当前网络下所有 WARP 端点都没有回应握手。请确认 WireGuard 隧道已关闭后重试，或换一个网络（例如 Wi-Fi）再测。如果始终没有响应，说明这个网络屏蔽了 WARP 的 WireGuard 协议，换端点无法解决。")
                }
            }
        }
        .navigationTitle("端点测速")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { scanTask?.cancel() }
    }

    private func start() {
        let candidates = EndpointScanner.candidates(count: Self.candidateCount)
        results = []
        done = 0
        total = candidates.count
        isScanning = true
        scanTask = Task {
            await EndpointScanner.scan(candidates) { completed, result in
                done = completed
                if let result {
                    let index = results.firstIndex { $0.rtt > result.rtt } ?? results.endIndex
                    results.insert(result, at: index)
                }
            }
            isScanning = false
            hasScanned = true
        }
    }
}
