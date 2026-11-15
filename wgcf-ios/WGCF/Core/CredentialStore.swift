import Foundation
import Security

/// 需要持久化的全部账户状态。
struct StoredState: Codable, Equatable {
    var credentials: Credentials
    var tunnel: TunnelInfo?
}

protocol CredentialStore {
    func load() -> StoredState?
    func save(_ state: StoredState) throws
    func clear()
}

/// 把账户状态以 JSON 形式保存在钥匙串中（私钥与访问令牌属于敏感数据）。
struct KeychainStore: CredentialStore {
    var service = "wgcf.account"
    var account = "default"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> StoredState? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredState.self, from: data)
    }

    func save(_ state: StoredState) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "无法写入钥匙串 (\(status))。"])
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 仅保存在内存中，用于测试与预览。
final class MemoryStore: CredentialStore {
    var state: StoredState?

    init(state: StoredState? = nil) {
        self.state = state
    }

    func load() -> StoredState? { state }
    func save(_ state: StoredState) throws { self.state = state }
    func clear() { state = nil }
}
