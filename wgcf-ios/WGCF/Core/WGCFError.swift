import Foundation

enum WGCFError: LocalizedError, Equatable {
    case invalidPrivateKey
    case privateKeyLooksLikeLicense
    case licenseLooksLikePrivateKey
    case invalidLicenseKey
    case invalidKeepalive
    case noAccount
    case missingPeer
    case missingEndpoint
    case nameUpdateFailed
    case invalidAccountFile(String)
    case http(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return "私钥无效：需要 44 个字符的 Base64 WireGuard 私钥。"
        case .privateKeyLooksLikeLicense:
            return "这看起来是 WARP+ 许可证密钥，请在注册后到「账户」页绑定。"
        case .licenseLooksLikePrivateKey:
            return "这看起来是 WireGuard 私钥，而不是 WARP+ 许可证密钥。"
        case .invalidLicenseKey:
            return "许可证密钥格式不正确，应为 xxxxxxxx-xxxxxxxx-xxxxxxxx。"
        case .invalidKeepalive:
            return "保活间隔必须在 0 到 65535 秒之间。"
        case .noAccount:
            return "尚未注册账户。"
        case .missingPeer:
            return "Cloudflare 的响应中没有 WireGuard 节点信息。"
        case .missingEndpoint:
            return "Cloudflare 的响应中没有可用的 WireGuard 端点。"
        case .nameUpdateFailed:
            return "设备名称更新失败。"
        case .invalidAccountFile(let reason):
            return "账户文件无效：\(reason)"
        case .http(let status, let message):
            return message.isEmpty ? "服务器返回错误 (HTTP \(status))。" : "服务器返回错误 (HTTP \(status))：\(message)"
        case .invalidResponse:
            return "无法解析服务器响应。"
        }
    }
}
