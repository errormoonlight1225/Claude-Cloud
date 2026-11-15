import Foundation

enum EndpointMode: String, Codable, CaseIterable, Identifiable {
    case auto, ipv4, ipv6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动（域名）"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        }
    }
}

struct ProfileOptions: Codable, Equatable {
    static let defaultDNS = "1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    static let defaultAllowedIPs = "0.0.0.0/0, ::/0"
    static let defaultMTU = 1280
    static let maxKeepalive = 65535

    /// 0 表示不写入 PersistentKeepalive。
    var keepalive = 0
    var mtu = ProfileOptions.defaultMTU
    var dns = ProfileOptions.defaultDNS
    var allowedIPs = ProfileOptions.defaultAllowedIPs
    var endpointMode = EndpointMode.auto
    /// nil 表示使用 Cloudflare 返回的默认端口。
    var port: Int?
}

enum WireGuardProfile {
    static let defaultPort = 2408
    /// WARP 的 WireGuard 端点监听的 UDP 端口，默认端口被屏蔽时可以换用其他端口。
    static let knownPorts = [2408, 500, 1701, 4500]
    static let fileName = "wgcf-profile.conf"

    /// 生成与 `wgcf generate` 相同格式的 WireGuard 配置。
    static func render(privateKey: String, tunnel: TunnelInfo, options: ProfileOptions = ProfileOptions()) throws -> String {
        guard (0...ProfileOptions.maxKeepalive).contains(options.keepalive) else {
            throw WGCFError.invalidKeepalive
        }
        let endpoint = try endpoint(tunnel.endpoint, mode: options.endpointMode, port: options.port)
        let dns = options.dns.trimmingCharacters(in: .whitespaces)
        let allowedIPs = options.allowedIPs.trimmingCharacters(in: .whitespaces)

        var lines = [
            "[Interface]",
            "PrivateKey = \(privateKey)",
            "Address = \(tunnel.addressV4)/32, \(tunnel.addressV6)/128",
        ]
        if !dns.isEmpty {
            lines.append("DNS = \(dns)")
        }
        lines.append("MTU = \(options.mtu)")
        lines.append("[Peer]")
        lines.append("PublicKey = \(tunnel.peerPublicKey)")
        lines.append("AllowedIPs = \(allowedIPs.isEmpty ? ProfileOptions.defaultAllowedIPs : allowedIPs)")
        lines.append("Endpoint = \(endpoint)")
        if options.keepalive > 0 {
            lines.append("PersistentKeepalive = \(options.keepalive)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 选择端点。自动模式与 wgcf 一致：优先域名，其次 IPv4，最后 IPv6。
    /// 指定 `port` 时覆盖服务器返回的端口。
    static func endpoint(_ endpoint: PeerEndpoint, mode: EndpointMode = .auto, port override: Int? = nil) throws -> String {
        let host = nonEmpty(endpoint.host)
        let v4 = nonEmpty(endpoint.v4)
        let v6 = nonEmpty(endpoint.v6)
        let port = override ?? endpoint.ports?.first ?? defaultPort

        switch mode {
        case .auto:
            if let host {
                guard let override else { return host }
                return join(host: hostPart(host), port: override)
            }
            if let address = v4 ?? v6 { return join(host: hostPart(address), port: port) }
        case .ipv4:
            if let v4 { return join(host: hostPart(v4), port: port) }
        case .ipv6:
            if let v6 { return join(host: hostPart(v6), port: port) }
        }
        throw WGCFError.missingEndpoint
    }

    /// 去掉 "1.2.3.4:0" 或 "[::1]:0" 中的端口，只保留地址。
    static func hostPart(_ address: String) -> String {
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex)..<end])
        }
        let colons = address.filter { $0 == ":" }.count
        if colons == 1, let colon = address.firstIndex(of: ":") {
            return String(address[..<colon])
        }
        return address
    }

    static func join(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func tunnelInfo(from device: SourceDevice) throws -> TunnelInfo {
        guard let config = device.config, let peer = config.peers?.first else {
            throw WGCFError.missingPeer
        }
        return TunnelInfo(
            addressV4: config.interface?.addresses.v4 ?? "",
            addressV6: config.interface?.addresses.v6 ?? "",
            peerPublicKey: peer.publicKey,
            endpoint: peer.endpoint)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
