import XCTest
@testable import WGCF

/// 访问真实的 Cloudflare 服务，只在设置了 WGCF_LIVE_DIR 时运行（CI 中手动触发）。
final class LiveTests: XCTestCase {
    @MainActor
    func testRegisterGenerateAndProbe() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WGCF_LIVE_DIR"], !directory.isEmpty else {
            throw XCTSkip("未设置 WGCF_LIVE_DIR")
        }

        let defaults = UserDefaults(suiteName: "wgcf.live")!
        defaults.removePersistentDomain(forName: "wgcf.live")
        let model = AppModel(store: MemoryStore(), defaults: defaults)

        await model.register(deviceName: "", deviceModel: "PC", existingPrivateKey: "")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isRegistered)
        XCTAssertFalse(model.devices.isEmpty)

        let profile = try XCTUnwrap(model.profileText)
        let accountFile = try XCTUnwrap(model.accountFileText)
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try profile.write(to: url.appendingPathComponent(WireGuardProfile.fileName), atomically: true, encoding: .utf8)
        try accountFile.write(to: url.appendingPathComponent(AccountFile.fileName), atomically: true, encoding: .utf8)

        let endpoint = try XCTUnwrap(profile.split(separator: "\n").first { $0.hasPrefix("Endpoint") })
        print("LIVE account type: \(model.account?.accountType ?? "nil")")
        print("LIVE \(endpoint)")

        let rtt = await EndpointScanner.probe(.init(host: "162.159.192.1", port: 2408), timeout: 3)
        print("LIVE probe rtt: \(rtt.map { String($0) } ?? "nil")")
        XCTAssertNotNil(rtt, "默认端点没有回应握手包")
    }
}
