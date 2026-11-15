import Foundation

/// 读写与 wgcf 命令行兼容的 wgcf-account.toml。
enum AccountFile {
    static let fileName = "wgcf-account.toml"

    static func encode(_ credentials: Credentials) -> String {
        [
            "access_token = '\(credentials.accessToken)'",
            "device_id = '\(credentials.deviceId)'",
            "license_key = '\(credentials.licenseKey)'",
            "private_key = '\(credentials.privateKey)'",
        ].joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) throws -> Credentials {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }

        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw WGCFError.invalidAccountFile("缺少 \(key)")
            }
            return value
        }

        let credentials = Credentials(
            deviceId: try required("device_id"),
            accessToken: try required("access_token"),
            privateKey: try required("private_key"),
            licenseKey: values["license_key"] ?? "")
        guard WireGuardKey.isKey(credentials.privateKey) else {
            throw WGCFError.invalidAccountFile("private_key 不是有效的 WireGuard 私钥")
        }
        return credentials
    }
}
