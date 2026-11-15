import Foundation
import Network

/// 探测 WARP 的 WireGuard 端点是否可达：发送一个握手包，收到 92 字节的握手响应即视为可用。
/// 做法与常见的 WARP 端点优选工具相同。
enum EndpointScanner {
    struct Candidate: Hashable {
        var host: String
        var port: Int

        var endpoint: String { WireGuardProfile.join(host: host, port: port) }
    }

    struct Result: Identifiable, Equatable {
        var candidate: Candidate
        /// 握手往返时间（秒）。
        var rtt: TimeInterval

        var id: Candidate { candidate }
        var milliseconds: Int { Int((rtt * 1000).rounded()) }
    }

    static let responseLength = 92

    /// 预先构造好的 WireGuard 握手发起包（148 字节）。
    static let handshakePacket = Data(hex:
        "013cbdafb4135cac96a29484d7a0175ab152dd3e59be35049beadf758b8d48af14ca65f25a168934746fe8bc8867b1c1"
        + "7113d71c0fac5c141ef9f35783ffa5357c9871f4a006662b83ad71245a862495376a5fe3b4f2e1f06974d748416670e5"
        + "f9b086297f652e6dfbf742fbfc63c3d8aeb175a3e9b7582fbc67c77577e4c0b32b05f92900000000000000000000000000000000")

    /// WARP 端点所在的 IPv4 网段（/24 前缀）。
    static let prefixes = [
        "162.159.192", "162.159.193", "162.159.195", "162.159.204",
        "188.114.96", "188.114.97", "188.114.98", "188.114.99",
    ]

    /// WARP 端点监听的 UDP 端口。
    static let ports = [
        2408, 500, 1701, 4500,
        854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942, 943, 945, 946, 955, 968,
        987, 988, 1002, 1010, 1014, 1018, 1070, 1074, 1180, 1387, 1843, 2371, 2506, 3138, 3476, 3581,
        3854, 4177, 4198, 4233, 5279, 5956, 7103, 7152, 7156, 7281, 7559, 8319, 8742, 8854, 8886,
    ]

    /// 生成候选列表：先是默认端点的四个常用端口，其余为随机的 IP 与端口组合。
    static func candidates(count: Int) -> [Candidate] {
        var list = WireGuardProfile.knownPorts.map { Candidate(host: "162.159.192.1", port: $0) }
        var seen = Set(list)
        var attempts = 0
        while list.count < count, attempts < count * 20 {
            attempts += 1
            let candidate = Candidate(
                host: "\(prefixes.randomElement()!).\(Int.random(in: 1...254))",
                port: ports.randomElement()!)
            if seen.insert(candidate).inserted {
                list.append(candidate)
            }
        }
        return list
    }

    /// 探测单个端点，返回握手往返时间；超时或无响应时返回 nil。
    static func probe(_ candidate: Candidate, timeout: TimeInterval = 1.5) async -> TimeInterval? {
        guard let rawPort = UInt16(exactly: candidate.port), let port = NWEndpoint.Port(rawValue: rawPort) else {
            return nil
        }
        let connection = NWConnection(host: NWEndpoint.Host(candidate.host), port: port, using: .udp)
        let queue = DispatchQueue(label: "wgcf.probe")

        return await withCheckedContinuation { continuation in
            let state = ProbeState(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    let start = DispatchTime.now()
                    connection.send(content: handshakePacket, completion: .contentProcessed { error in
                        if error != nil { state.finish(nil) }
                    })
                    connection.receiveMessage { data, _, _, _ in
                        guard let data, data.count == responseLength else {
                            state.finish(nil)
                            return
                        }
                        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                        state.finish(TimeInterval(elapsed) / 1_000_000_000)
                    }
                case .failed, .cancelled:
                    state.finish(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { state.finish(nil) }
            connection.start(queue: queue)
        }
    }

    /// 并发探测全部候选端点，每完成一个就回调一次。
    static func scan(
        _ candidates: [Candidate], concurrency: Int = 32,
        onProgress: @MainActor @Sendable (_ done: Int, _ result: Result?) -> Void
    ) async {
        var done = 0
        var remaining = candidates[...]
        await withTaskGroup(of: Result?.self) { group in
            for candidate in remaining.prefix(concurrency) {
                group.addTask { await result(for: candidate) }
            }
            remaining = remaining.dropFirst(concurrency)

            for await result in group {
                done += 1
                await onProgress(done, result)
                if Task.isCancelled {
                    group.cancelAll()
                } else if let candidate = remaining.popFirst() {
                    group.addTask { await EndpointScanner.result(for: candidate) }
                }
            }
        }
    }

    private static func result(for candidate: Candidate) async -> Result? {
        guard !Task.isCancelled, let rtt = await probe(candidate) else { return nil }
        return Result(candidate: candidate, rtt: rtt)
    }
}

/// 保证每次探测只回调一次，并在结束时关闭连接。
private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<TimeInterval?, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<TimeInterval?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: TimeInterval?) {
        let pending = lock.withLock { () -> CheckedContinuation<TimeInterval?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: value)
    }
}

extension Data {
    /// 由十六进制字符串构造；非法字符会被忽略。
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        self = data
    }
}
