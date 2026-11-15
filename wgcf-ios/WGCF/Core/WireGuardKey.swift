import CryptoKit
import Foundation

/// 32 字节的 Curve25519 密钥，以 Base64 文本形式在 WireGuard 配置中使用。
struct WireGuardKey: Equatable {
    static let length = 32

    let rawValue: Data

    var base64: String { rawValue.base64EncodedString() }

    init?(rawValue: Data) {
        guard rawValue.count == Self.length else { return nil }
        self.rawValue = rawValue
    }

    init?(base64: String) {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { return nil }
        self.init(rawValue: data)
    }

    /// 生成新的私钥，并按 Curve25519 规范进行 clamp（与 wgcf 行为一致）。
    static func generatePrivate() -> WireGuardKey {
        var bytes = [UInt8](repeating: 0, count: length)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        bytes[0] &= 248
        bytes[31] = (bytes[31] & 127) | 64
        return WireGuardKey(rawValue: Data(bytes))!
    }

    /// 把当前密钥视为私钥，推导出对应的公钥。
    func publicKey() throws -> WireGuardKey {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawValue)
        guard let key = WireGuardKey(rawValue: privateKey.publicKey.rawRepresentation) else {
            throw WGCFError.invalidPrivateKey
        }
        return key
    }

    static func isKey(_ value: String) -> Bool {
        WireGuardKey(base64: value) != nil
    }
}

enum LicenseKey {
    /// WARP+ 许可证格式：三段、每段 8 位字母数字，以连字符分隔。
    static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            part.count == 8 && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }
}
