import Foundation

/// Cloudflare WARP 注册 API 客户端，行为对应 wgcf 的 cloudflare/api.go。
struct WarpAPI {
    static let baseURL = URL(string: "https://api.cloudflareclient.com")!
    static let apiVersion = "v0a5641"
    static let defaultHeaders = [
        "User-Agent": "1.1.1.1/6.38.9-5641 (Android 16.0.0)",
        "CF-Client-Version": "a-6.38.9-5641",
    ]

    let session: URLSession

    init(session: URLSession = WarpAPI.makeSession()) {
        self.session = session
    }

    /// 官方客户端只使用 TLS 1.2，wgcf 也同样固定版本，这里保持一致。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    // MARK: - 接口

    func register(publicKey: WireGuardKey, model: String, date: Date = Date()) async throws -> SourceDevice {
        let body = RegisterRequest(key: publicKey.base64, model: model, tos: Self.timestamp(date))
        return try await send("POST", path: "reg", token: nil, body: body)
    }

    func sourceDevice(_ credentials: Credentials) async throws -> SourceDevice {
        try await send("GET", path: "reg/\(credentials.deviceId)", token: credentials.accessToken)
    }

    func account(_ credentials: Credentials) async throws -> WarpAccount {
        try await send("GET", path: "reg/\(credentials.deviceId)/account", token: credentials.accessToken)
    }

    func boundDevices(_ credentials: Credentials) async throws -> [BoundDevice] {
        try await send("GET", path: "reg/\(credentials.deviceId)/account/devices", token: credentials.accessToken)
    }

    func updateLicense(_ credentials: Credentials, license: String) async throws {
        try await sendDiscardingResponse(
            "PUT", path: "reg/\(credentials.deviceId)/account",
            token: credentials.accessToken, body: ["license": license])
    }

    @discardableResult
    func renameDevice(_ credentials: Credentials, deviceId: String, name: String) async throws -> [BoundDevice] {
        try await send(
            "PATCH", path: "reg/\(credentials.deviceId)/account/reg/\(deviceId)",
            token: credentials.accessToken, body: ["name": name])
    }

    @discardableResult
    func setDeviceActive(_ credentials: Credentials, deviceId: String, active: Bool) async throws -> [BoundDevice] {
        try await send(
            "PATCH", path: "reg/\(credentials.deviceId)/account/reg/\(deviceId)",
            token: credentials.accessToken, body: ["active": active])
    }

    func deleteBoundDevice(_ credentials: Credentials, deviceId: String) async throws {
        try await sendDiscardingResponse(
            "DELETE", path: "reg/\(credentials.deviceId)/account/reg/\(deviceId)",
            token: credentials.accessToken, body: Optional<[String: String]>.none)
    }

    /// 删除当前设备在 Cloudflare 上的注册。
    func deleteRegistration(_ credentials: Credentials) async throws {
        try await sendDiscardingResponse(
            "DELETE", path: "reg/\(credentials.deviceId)",
            token: credentials.accessToken, body: Optional<[String: String]>.none)
    }

    // MARK: - 请求

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func makeRequest<Body: Encodable>(_ method: String, path: String, token: String?, body: Body?) throws -> URLRequest {
        let url = Self.baseURL.appendingPathComponent(Self.apiVersion).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in Self.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func perform<Body: Encodable>(_ method: String, path: String, token: String?, body: Body?) async throws -> Data {
        let request = try makeRequest(method, path: path, token: token, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WGCFError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw WGCFError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    private func send<Response: Decodable>(_ method: String, path: String, token: String?) async throws -> Response {
        try await send(method, path: path, token: token, body: Optional<[String: String]>.none)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String, path: String, token: String?, body: Body?
    ) async throws -> Response {
        let data = try await perform(method, path: path, token: token, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WGCFError.invalidResponse
        }
    }

    private func sendDiscardingResponse<Body: Encodable>(
        _ method: String, path: String, token: String?, body: Body?
    ) async throws {
        _ = try await perform(method, path: path, token: token, body: body)
    }

    /// 尽量从 Cloudflare 的错误响应里提取可读信息。
    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable {
            struct Item: Decodable { var message: String? }
            var errors: [Item]?
            var message: String?
            var error: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            let messages = (envelope.errors ?? []).compactMap(\.message)
            if !messages.isEmpty { return messages.joined(separator: "；") }
            if let message = envelope.message ?? envelope.error { return message }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // HTML 错误页对用户没有意义。
        if text.hasPrefix("<") { return "" }
        return String(text.prefix(200))
    }
}
