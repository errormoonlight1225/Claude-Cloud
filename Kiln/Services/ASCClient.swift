import CryptoKit
import Foundation

/// Minimal App Store Connect API client for the provisioning endpoints
/// (certificates, devices, bundle IDs, profiles). Uses an API key (.p8) with ES256 JWT auth.
struct ASCClient {
    struct Credentials {
        var issuerID: String   // empty = individual key
        var keyID: String
        var privateKeyPEM: String
    }

    let credentials: Credentials
    private let base = URL(string: "https://api.appstoreconnect.apple.com")!
    private let session: URLSession = .shared

    init(credentials: Credentials) throws {
        self.credentials = credentials
        _ = try Self.signingKey(credentials.privateKeyPEM)  // validate early
    }

    // MARK: Auth

    private static func signingKey(_ pem: String) throws -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw KilnError("API 密钥 (.p8) 无法解析：请确认导入的是 App Store Connect 下载的 AuthKey_XXXX.p8")
        }
    }

    private func token() throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]
        var payload: [String: Any] = ["iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]
        if credentials.issuerID.isEmpty {
            payload["sub"] = "user"
        } else {
            payload["iss"] = credentials.issuerID
        }
        let h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).base64URL
        let p = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).base64URL
        let input = Data("\(h).\(p)".utf8)
        let signature = try Self.signingKey(credentials.privateKeyPEM).signature(for: input)
        return "\(h).\(p).\(signature.rawRepresentation.base64URL)"
    }

    // MARK: Transport

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                       body: Encodable? = nil, as type: T.Type) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        do {
            return try ASCJSON.decoder.decode(T.self, from: data)
        } catch {
            throw KilnError("App Store Connect 返回了无法识别的数据：\(error.localizedDescription)")
        }
    }

    @discardableResult
    private func raw(_ method: String, _ path: String, query: [URLQueryItem] = [],
                     body: Encodable? = nil) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try ASCJSON.encoder.encode(AnyEncodable(body))
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ASCError(status: status, data: data)
        }
        return data
    }

    private func all<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
        try await request("GET", path, query: query + [URLQueryItem(name: "limit", value: "200")],
                          as: ASCList<T>.self).data
    }

    // MARK: Certificates

    func certificates() async throws -> [ASCCertificate] {
        try await all("/v1/certificates", query: [
            URLQueryItem(name: "filter[certificateType]", value: "DEVELOPMENT,DISTRIBUTION,IOS_DEVELOPMENT,IOS_DISTRIBUTION"),
        ])
    }

    func createCertificate(type: String, csrPEM: String) async throws -> ASCCertificate {
        let body = ASCCreate(type: "certificates",
                             attributes: ["certificateType": type, "csrContent": csrPEM],
                             relationships: nil)
        return try await request("POST", "/v1/certificates", body: ASCBody(data: body),
                                 as: ASCSingle<ASCCertificate>.self).data
    }

    func revokeCertificate(id: String) async throws {
        try await raw("DELETE", "/v1/certificates/\(id)")
    }

    // MARK: Devices

    func devices() async throws -> [ASCDevice] {
        try await all("/v1/devices", query: [URLQueryItem(name: "filter[platform]", value: "IOS")])
    }

    func registerDevice(name: String, udid: String) async throws -> ASCDevice {
        let body = ASCCreate(type: "devices",
                             attributes: ["name": name, "udid": udid, "platform": "IOS"],
                             relationships: nil)
        return try await request("POST", "/v1/devices", body: ASCBody(data: body),
                                 as: ASCSingle<ASCDevice>.self).data
    }

    // MARK: Bundle IDs

    func bundleID(identifier: String) async throws -> ASCBundleID? {
        let list: [ASCBundleID] = try await all("/v1/bundleIds", query: [
            URLQueryItem(name: "filter[identifier]", value: identifier),
        ])
        // The filter matches prefixes; insist on an exact identifier.
        return list.first { $0.attributes.identifier == identifier }
    }

    func createBundleID(identifier: String, name: String) async throws -> ASCBundleID {
        let body = ASCCreate(type: "bundleIds",
                             attributes: ["identifier": identifier, "name": name, "platform": "IOS"],
                             relationships: nil)
        return try await request("POST", "/v1/bundleIds", body: ASCBody(data: body),
                                 as: ASCSingle<ASCBundleID>.self).data
    }

    // MARK: Profiles

    func createProfile(name: String, type: String, bundleIDResource: String,
                       certificateIDs: [String], deviceIDs: [String]) async throws -> ASCProfile {
        let relationships: [String: ASCRelationship] = [
            "bundleId": .one(ASCLinkage(type: "bundleIds", id: bundleIDResource)),
            "certificates": .many(certificateIDs.map { ASCLinkage(type: "certificates", id: $0) }),
            "devices": .many(deviceIDs.map { ASCLinkage(type: "devices", id: $0) }),
        ]
        let body = ASCCreate(type: "profiles",
                             attributes: ["name": name, "profileType": type],
                             relationships: relationships)
        return try await request("POST", "/v1/profiles", body: ASCBody(data: body),
                                 as: ASCSingle<ASCProfile>.self).data
    }

    func deleteProfile(id: String) async throws {
        try await raw("DELETE", "/v1/profiles/\(id)")
    }
}

// MARK: - Resources

struct ASCList<T: Decodable>: Decodable { let data: [T] }
struct ASCSingle<T: Decodable>: Decodable { let data: T }

struct ASCCertificate: Decodable, Identifiable, Hashable {
    struct Attributes: Decodable, Hashable {
        let name: String?
        let displayName: String?
        let certificateType: String?
        let serialNumber: String?
        let expirationDate: Date?
        let certificateContent: String?
    }
    let id: String
    let attributes: Attributes

    var der: Data? { attributes.certificateContent.flatMap { Data(base64Encoded: $0) } }
}

struct ASCDevice: Decodable, Identifiable, Hashable {
    struct Attributes: Decodable, Hashable {
        let name: String?
        let udid: String?
        let platform: String?
        let deviceClass: String?
        let model: String?
        let status: String?
        let addedDate: Date?
    }
    let id: String
    let attributes: Attributes

    var isEnabled: Bool { attributes.status != "DISABLED" }
    var isIOSDevice: Bool {
        let cls = attributes.deviceClass ?? ""
        return cls.isEmpty || ["IPHONE", "IPAD", "IPOD", "APPLE_VISION_PRO"].contains(cls)
    }
}

struct ASCBundleID: Decodable, Identifiable, Hashable {
    struct Attributes: Decodable, Hashable {
        let identifier: String
        let name: String?
    }
    let id: String
    let attributes: Attributes
}

struct ASCProfile: Decodable, Identifiable, Hashable {
    struct Attributes: Decodable, Hashable {
        let name: String?
        let uuid: String?
        let profileContent: String?
        let expirationDate: Date?
        let profileState: String?
    }
    let id: String
    let attributes: Attributes
}

struct ASCError: LocalizedError {
    let status: Int
    let messages: [String]

    init(status: Int, data: Data) {
        self.status = status
        struct Body: Decodable {
            struct Item: Decodable { let title: String?; let detail: String?; let code: String? }
            let errors: [Item]
        }
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            messages = body.errors.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: "：") }
        } else {
            messages = [String(data: data, encoding: .utf8) ?? ""].filter { !$0.isEmpty }
        }
    }

    var errorDescription: String? {
        let hint: String
        switch status {
        case 401: hint = "认证失败：检查 Issuer ID / Key ID / .p8 是否匹配，设备时间是否准确"
        case 403: hint = "权限不足：API 密钥需要 Admin 或 Developer 角色"
        case 409: hint = "请求冲突"
        case 429: hint = "请求过于频繁，请稍后再试"
        default: hint = "App Store Connect 错误 \(status)"
        }
        return ([hint] + messages).joined(separator: "\n")
    }
}

// MARK: - Request bodies

struct ASCLinkage: Encodable { let type: String; let id: String }

enum ASCRelationship: Encodable {
    case one(ASCLinkage)
    case many([ASCLinkage])

    private enum Keys: String, CodingKey { case data }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .one(link): try c.encode(link, forKey: .data)
        case let .many(links): try c.encode(links, forKey: .data)
        }
    }
}

struct ASCCreate: Encodable {
    let type: String
    let attributes: [String: String]
    let relationships: [String: ASCRelationship]?
}

struct ASCBody<T: Encodable>: Encodable { let data: T }

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

enum ASCJSON {
    static let encoder = JSONEncoder()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: string) ?? plain.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(string)"))
        }
        return d
    }()
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
