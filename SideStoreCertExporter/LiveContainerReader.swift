import Foundation
import ObjectiveC
import Security

/// Reads SideStore's certificate directly when this app runs as a guest inside
/// LiveContainer, the second way SideInstaller imports it.
///
/// Inside LiveContainer the URL handshake can't complete: iOS only routes the
/// URL schemes declared in LiveContainer's own Info.plist, so SideStore's
/// `sscertexport://` callback goes nowhere. But a guest app runs in
/// LiveContainer's process, so it can read:
/// - the built-in SideStore's Keychain items (`signingCertificate`,
///   `signingCertificatePassword`, service `com.kdt.livecontainer`), and
/// - the copy LiveContainer keeps after "Import Certificate from SideStore"
///   (`LCCertificateData` / `LCCertificatePassword` in its app-group defaults).
enum LiveContainerReader {
    /// LiveContainer adds `+[NSUserDefaults lcSharedDefaults]` for its guests.
    static var runsInLiveContainer: Bool {
        class_getClassMethod(UserDefaults.self, NSSelectorFromString("lcSharedDefaults")) != nil
    }

    /// Every certificate found, the built-in SideStore's first, without repeats.
    /// `log` gets a line per place that had nothing.
    static func find(log: (String) -> Void) -> [ExportedCertificate] {
        guard runsInLiveContainer else {
            log("当前不在 LiveContainer 中运行，无法直接读取。")
            return []
        }
        var found: [ExportedCertificate] = []
        func add(_ data: Data, _ password: String?, _ source: String) {
            guard ExportedCertificate.isPlausibleArchive(data) else {
                log("\(source)：数据不是证书归档（\(data.count) 字节）。")
                return
            }
            guard !found.contains(where: { $0.p12Data == data }) else { return }
            found.append(ExportedCertificate(p12Data: data, password: password ?? "", source: source))
        }

        let builtIn = "LiveContainer 内置 SideStore（钥匙串）"
        if hasBuiltInSideStore == false {
            log("此 LiveContainer 没有内置 SideStore。")
        } else {
            let cert = keychainItem("signingCertificate")
            if let data = cert.data {
                let password = keychainItem("signingCertificatePassword").data
                    .flatMap { String(data: $0, encoding: .utf8) }
                add(data, password, builtIn)
            } else {
                log("内置 SideStore 的钥匙串中没有证书（状态 \(cert.status)）。")
            }
        }

        let copy = "LiveContainer 保存的 SideStore 证书副本"
        if let defaults = liveContainerDefaults {
            if let data = defaults.data(forKey: "LCCertificateData"), !data.isEmpty {
                add(data, defaults.string(forKey: "LCCertificatePassword"), copy)
            } else {
                log("LiveContainer 中没有已导入的 SideStore 证书副本。")
            }
        } else {
            log("无法读取 LiveContainer 的共享设置。")
        }
        return found
    }

    // MARK: - Built-in SideStore Keychain

    /// The service SideStore files its items under when LiveContainer hosts it.
    private static let builtInSideStoreService = "com.kdt.livecontainer"

    /// `+[NSUserDefaults sideStoreExist]`; nil on LiveContainer builds without it.
    private static var hasBuiltInSideStore: Bool? {
        let selector = NSSelectorFromString("sideStoreExist")
        guard let method = class_getClassMethod(UserDefaults.self, selector) else { return nil }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Bool
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(UserDefaults.self, selector)
    }

    private static func keychainItem(_ account: String) -> (data: Data?, status: OSStatus) {
        guard let copyMatching = unhookedCopyMatching else { return (nil, errSecUnimplemented) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: builtInSideStoreService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    private typealias CopyMatching =
        @convention(c) (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    /// LiveContainer rebinds a guest's `SecItemCopyMatching` symbol so its
    /// Keychain calls land in the guest's own group. Looking the function up
    /// with `dlsym` bypasses that rebinding and reaches the items the built-in
    /// SideStore stored, the same way LiveContainer's Settings read them.
    private static let unhookedCopyMatching: CopyMatching? = {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security",
                                    RTLD_NOW | RTLD_NOLOAD),
              let symbol = dlsym(security, "SecItemCopyMatching")
        else { return nil }
        return unsafeBitCast(symbol, to: CopyMatching.self)
    }()

    // MARK: - LiveContainer's copy

    private static var liveContainerDefaults: UserDefaults? {
        let selector = NSSelectorFromString("lcSharedDefaults")
        let cls = UserDefaults.self as AnyObject
        guard cls.responds(to: selector) else { return nil }
        return cls.perform(selector)?.takeUnretainedValue() as? UserDefaults
    }
}
