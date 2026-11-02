import Foundation
import Security

enum Paths {
    static let fm = FileManager.default

    private static func dir(_ base: URL, _ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Private app data (not visible in Files).
    static var support: URL {
        dir(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], "Kiln")
    }

    /// Visible in the Files app (UIFileSharingEnabled).
    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static var identities: URL { dir(support, "Identities") }
    static var profiles: URL { dir(support, "Profiles") }
    static var apps: URL { dir(support, "Apps") }
    static var icons: URL { dir(support, "Icons") }
    static var signed: URL { dir(documents, "Signed") }
    static var exports: URL { dir(documents, "Exports") }
    static var state: URL { support.appendingPathComponent("state.json") }

    /// A fresh scratch directory; caller removes it.
    static func makeWorkDirectory(_ label: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("kiln-\(label)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        if case let .status(code) = self {
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "\(code)"
            return "钥匙串错误：\(message)"
        }
        return nil
    }
}

/// Secrets (private keys, API key, TLS identity) live in the keychain, never in plain files.
enum Keychain {
    private static let service = "app.kiln.secrets"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ data: Data, for account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func set(_ string: String, for account: String) throws {
        try set(Data(string.utf8), for: account)
    }

    static func data(for account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static let ascPrivateKey = "asc.p8"
    static let serverIdentity = "server.p12"
    static let serverIdentityPassword = "server.p12.password"
}

extension FileManager {
    func fileSize(_ url: URL) -> Int64 {
        ((try? attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

/// Writes data to a file only readable while the device is unlocked, for handing secrets to zsign.
func writeProtected(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtection])
}
