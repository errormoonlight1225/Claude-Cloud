import Foundation
import Security

struct ModelOption {
    let id: String
    let name: String
    /// Supports adaptive thinking with `display` and `output_config.effort`.
    let supportsThinking: Bool
    /// Accepts server-side `fallbacks: "default"`.
    let supportsFallbacks: Bool
}

enum Settings {
    static let models: [ModelOption] = [
        ModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5", supportsThinking: true, supportsFallbacks: true),
        ModelOption(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", supportsThinking: true, supportsFallbacks: true),
        ModelOption(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", supportsThinking: true, supportsFallbacks: false),
        ModelOption(id: "claude-fable-5-1", name: "Claude Fable 5.1", supportsThinking: true, supportsFallbacks: true),
    ]

    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static let defaultBaseURL = "https://api.anthropic.com"

    private static let defaults = UserDefaults.standard

    static var model: String {
        get { defaults.string(forKey: "model") ?? models[0].id }
        set { defaults.set(newValue, forKey: "model") }
    }

    static var modelOption: ModelOption {
        if let known = models.first(where: { $0.id == model }) { return known }
        return ModelOption(id: model, name: model, supportsThinking: false, supportsFallbacks: false)
    }

    static var effort: String {
        get { defaults.string(forKey: "effort") ?? "medium" }
        set { defaults.set(newValue, forKey: "effort") }
    }

    static var showThinking: Bool {
        get { defaults.object(forKey: "showThinking") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showThinking") }
    }

    static var systemPrompt: String {
        get { defaults.string(forKey: "systemPrompt") ?? "" }
        set { defaults.set(newValue, forKey: "systemPrompt") }
    }

    static var baseURL: String {
        get {
            let value = defaults.string(forKey: "baseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? defaultBaseURL : value
        }
        set { defaults.set(newValue, forKey: "baseURL") }
    }

    static var apiKey: String {
        get { Keychain.read("apiKey") ?? defaults.string(forKey: "apiKeyFallback") ?? "" }
        set {
            // Fake-signed builds (jailbreak + AppSync) have no keychain entitlement, so
            // SecItemAdd fails there; keep the key in UserDefaults in that case.
            if Keychain.write("apiKey", value: newValue) {
                defaults.removeObject(forKey: "apiKeyFallback")
            } else {
                defaults.set(newValue, forKey: "apiKeyFallback")
            }
        }
    }
}

enum Keychain {
    private static let service = "com.example.claudeclient"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns false when the keychain is unavailable (e.g. missing entitlement).
    @discardableResult
    static func write(_ account: String, value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else {
            return deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
