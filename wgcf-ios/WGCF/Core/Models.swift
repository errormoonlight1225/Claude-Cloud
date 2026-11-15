import Foundation

// 字段与 wgcf 的 openapi-spec.yml 对应。除标识符外全部按可选处理，
// 这样 Cloudflare 增删字段时不会导致解码失败。

struct WarpAccount: Codable, Equatable {
    var id: String
    var accountType: String?
    var created: String?
    var updated: String?
    var license: String?
    var premiumData: Int64?
    var quota: Int64?
    var usage: Int64?
    var referralCount: Int?
    var role: String?
    var warpPlus: Bool?
    var plusExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, created, updated, license, quota, usage, role
        case accountType = "account_type"
        case premiumData = "premium_data"
        case referralCount = "referral_count"
        case warpPlus = "warp_plus"
        case plusExpiresAt = "plus_expires_at"
    }
}

struct BoundDevice: Codable, Equatable, Identifiable {
    var id: String
    var type: String?
    var model: String?
    var name: String?
    var active: Bool?
    var created: String?
    var activated: String?
    var role: String?
}

struct NetworkAddress: Codable, Equatable {
    var v4: String?
    var v6: String?
}

struct PeerEndpoint: Codable, Equatable {
    var host: String?
    var v4: String?
    var v6: String?
    var ports: [Int]?
}

struct WarpPeer: Codable, Equatable {
    var publicKey: String
    var endpoint: PeerEndpoint

    enum CodingKeys: String, CodingKey {
        case endpoint
        case publicKey = "public_key"
    }
}

struct WarpInterface: Codable, Equatable {
    var addresses: NetworkAddress
}

struct WarpConfig: Codable, Equatable {
    var clientId: String?
    var interface: WarpInterface?
    var peers: [WarpPeer]?

    enum CodingKeys: String, CodingKey {
        case interface, peers
        case clientId = "client_id"
    }
}

/// `POST /reg` 与 `GET /reg/{id}` 的响应。`token` 只在注册时返回。
struct SourceDevice: Codable, Equatable {
    var id: String
    var token: String?
    var name: String?
    var model: String?
    var type: String?
    var key: String?
    var account: WarpAccount?
    var config: WarpConfig?
}

struct RegisterRequest: Codable, Equatable {
    var fcmToken = ""
    var installId = ""
    var key: String
    var locale = "en_US"
    var model: String
    var tos: String
    var serialNumber = ""
    var osVersion = "16.0.0"
    var keyType = "curve25519"
    var tunnelType = "wireguard"

    enum CodingKeys: String, CodingKey {
        case key, locale, model, tos
        case fcmToken = "fcm_token"
        case installId = "install_id"
        case serialNumber = "serial_number"
        case osVersion = "os_version"
        case keyType = "key_type"
        case tunnelType = "tunnel_type"
    }
}

/// 保存在钥匙串里的本地凭据，等价于 wgcf-account.toml。
struct Credentials: Codable, Equatable {
    var deviceId: String
    var accessToken: String
    var privateKey: String
    var licenseKey: String
}

/// 生成配置文件所需的隧道参数，注册或刷新时从 Cloudflare 获取并缓存。
struct TunnelInfo: Codable, Equatable {
    var addressV4: String
    var addressV6: String
    var peerPublicKey: String
    var endpoint: PeerEndpoint
}
