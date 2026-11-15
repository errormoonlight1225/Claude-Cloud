import XCTest
@testable import WGCF

/// 拦截网络请求，按测试设定的处理函数返回响应。
final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (_ request: URLRequest, _ body: Data) -> (Int, String)

    private static let lock = NSLock()
    private static var _handler: Handler?
    private static var _requests: [URLRequest] = []
    private static var _bodies: [Data] = []

    static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }
    static var bodies: [Data] { lock.withLock { _bodies } }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
            _bodies = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.lock.withLock {
            Self._requests.append(request)
            Self._bodies.append(body)
        }
        let (status, text) = Self.handler?(request, body) ?? (404, "")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 会把 httpBody 转成流，这里读回来以便断言。
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private enum Fixtures {
    static let device = """
    {"id":"dev-1","token":"tok","account":{"id":"acc","account_type":"free","license":"ABCDEFGH-12345678-abcdefgh",
    "premium_data":0,"quota":0,"role":"parent"},
    "config":{"client_id":"c","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606::2"}},
    "peers":[{"public_key":"peer","endpoint":{"host":"engage.cloudflareclient.com:2408","v4":"162.159.192.1:0","v6":"[2606::1]:0"}}]}}
    """
    static let account = """
    {"id":"acc","account_type":"limited","license":"ABCDEFGH-12345678-abcdefgh","premium_data":1000000000,"quota":1000000000,"role":"parent"}
    """

    static func devices(name: String) -> String {
        """
        [{"id":"dev-1","type":"Android","model":"PC","name":"\(name)","active":true,
        "created":"2024-01-01T00:00:00.000Z","activated":"2024-01-01T00:00:00.000Z","role":"parent"}]
        """
    }
}

/// 供 @Sendable 闭包记录数据的线程安全容器。
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _name: String?

    var name: String? {
        get { lock.withLock { _name } }
        set { lock.withLock { _name = newValue } }
    }
}

final class APITests: XCTestCase {
    private let credentials = Credentials(
        deviceId: "dev-1", accessToken: "tok", privateKey: WireGuardKey.generatePrivate().base64, licenseKey: "")

    private func makeAPI() -> WarpAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return WarpAPI(session: URLSession(configuration: configuration))
    }

    @MainActor
    private func makeModel(store: MemoryStore) -> AppModel {
        let defaults = UserDefaults(suiteName: "wgcf.tests")!
        defaults.removePersistentDomain(forName: "wgcf.tests")
        return AppModel(api: makeAPI(), store: store, defaults: defaults)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    @MainActor
    func testRegisterRequestShape() async throws {
        MockURLProtocol.handler = { _, _ in (200, Fixtures.device) }
        let publicKey = try WireGuardKey.generatePrivate().publicKey()
        let device = try await makeAPI().register(publicKey: publicKey, model: "PC")

        XCTAssertEqual(device.id, "dev-1")
        XCTAssertEqual(device.token, "tok")

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflareclient.com/v0a5641/reg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Client-Version"), "a-6.38.9-5641")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "1.1.1.1/6.38.9-5641 (Android 16.0.0)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MockURLProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["key"] as? String, publicKey.base64)
        XCTAssertEqual(body["model"] as? String, "PC")
        XCTAssertEqual(body["key_type"] as? String, "curve25519")
        XCTAssertEqual(body["tunnel_type"] as? String, "wireguard")
        XCTAssertEqual(body["install_id"] as? String, "")
        XCTAssertEqual(body["fcm_token"] as? String, "")
        XCTAssertEqual(body["serial_number"] as? String, "")
        XCTAssertNotNil(body["tos"] as? String)
    }

    @MainActor
    func testAuthorizedRequest() async throws {
        MockURLProtocol.handler = { _, _ in (200, Fixtures.account) }
        let account = try await makeAPI().account(credentials)
        XCTAssertEqual(account.accountType, "limited")
        XCTAssertEqual(account.premiumData, 1_000_000_000)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v0a5641/reg/dev-1/account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    @MainActor
    func testHTTPErrorCarriesServerMessage() async {
        MockURLProtocol.handler = { _, _ in (403, #"{"success":false,"errors":[{"code":1,"message":"Invalid license"}]}"#) }
        do {
            _ = try await makeAPI().account(credentials)
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(error as? WGCFError, .http(status: 403, message: "Invalid license"))
        }
    }

    @MainActor
    func testRegisterFlowPersistsAccount() async throws {
        let recorder = Recorder()
        MockURLProtocol.handler = { request, body in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/v0a5641/reg"), ("GET", "/v0a5641/reg/dev-1"):
                return (200, Fixtures.device)
            case ("PATCH", "/v0a5641/reg/dev-1/account/reg/dev-1"):
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                recorder.name = json?["name"] as? String
                return (200, Fixtures.devices(name: recorder.name ?? ""))
            case ("GET", "/v0a5641/reg/dev-1/account"):
                return (200, Fixtures.account)
            case ("GET", "/v0a5641/reg/dev-1/account/devices"):
                return (200, Fixtures.devices(name: recorder.name ?? ""))
            default:
                return (404, "")
            }
        }

        let store = MemoryStore()
        let model = makeModel(store: store)
        XCTAssertFalse(model.isRegistered)

        await model.register(deviceName: "iPhone", deviceModel: "", existingPrivateKey: "")

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isRegistered)
        XCTAssertEqual(recorder.name, "iPhone")
        XCTAssertEqual(model.devices.first?.name, "iPhone")
        XCTAssertEqual(model.account?.accountType, "limited")
        XCTAssertEqual(store.state?.credentials.deviceId, "dev-1")
        XCTAssertEqual(store.state?.credentials.accessToken, "tok")
        XCTAssertEqual(store.state?.credentials.licenseKey, "ABCDEFGH-12345678-abcdefgh")

        let profile = try XCTUnwrap(model.profileText)
        XCTAssertTrue(profile.contains("PrivateKey = \(store.state!.credentials.privateKey)\n"))
        XCTAssertTrue(profile.contains("Address = 172.16.0.2/32, 2606::2/128\n"))
        XCTAssertTrue(profile.contains("PublicKey = peer\n"))
        XCTAssertTrue(profile.contains("Endpoint = engage.cloudflareclient.com:2408\n"))

        // 重新创建模型应能从存储中恢复账户。
        let restored = AppModel(api: makeAPI(), store: store, defaults: UserDefaults(suiteName: "wgcf.tests")!)
        XCTAssertTrue(restored.isRegistered)
        XCTAssertEqual(restored.profileText, profile)
    }

    @MainActor
    func testRegisterFailureLeavesNoAccount() async {
        MockURLProtocol.handler = { _, _ in (429, "") }
        let store = MemoryStore()
        let model = makeModel(store: store)
        await model.register(deviceName: "", deviceModel: "PC", existingPrivateKey: "")
        XCTAssertFalse(model.isRegistered)
        XCTAssertNil(store.state)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testRenameToleratesServerError500() async {
        MockURLProtocol.handler = { request, _ in
            if request.httpMethod == "PATCH" { return (500, "") }
            return (200, Fixtures.devices(name: "new"))
        }
        let model = makeModel(store: MemoryStore(state: StoredState(credentials: credentials, tunnel: nil)))
        await model.rename(BoundDevice(id: "dev-1"), to: "new")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.devices.first?.name, "new")
    }

    @MainActor
    func testBindLicenseValidatesInputBeforeNetwork() async {
        let model = makeModel(store: MemoryStore(state: StoredState(credentials: credentials, tunnel: nil)))
        await model.bindLicense("nope")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testUnregisterClearsStore() async {
        MockURLProtocol.handler = { _, _ in (204, "") }
        let store = MemoryStore(state: StoredState(credentials: credentials, tunnel: nil))
        let model = makeModel(store: store)
        await model.unregister()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isRegistered)
        XCTAssertNil(store.state)
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/v0a5641/reg/dev-1")
    }
}
