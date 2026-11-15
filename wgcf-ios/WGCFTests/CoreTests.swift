import XCTest
@testable import WGCF

final class WireGuardKeyTests: XCTestCase {
    private func data(hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// RFC 7748 第 6.1 节的测试向量。
    func testPublicKeyDerivation() throws {
        let privateKey = WireGuardKey(
            rawValue: data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))!
        let expected = data(hex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        XCTAssertEqual(try privateKey.publicKey().rawValue, expected)
    }

    func testGeneratedKeyIsClamped() {
        for _ in 0..<32 {
            let bytes = [UInt8](WireGuardKey.generatePrivate().rawValue)
            XCTAssertEqual(bytes.count, 32)
            XCTAssertEqual(bytes[0] & 7, 0)
            XCTAssertEqual(bytes[31] & 128, 0)
            XCTAssertEqual(bytes[31] & 64, 64)
        }
    }

    func testBase64RoundTrip() {
        let key = WireGuardKey.generatePrivate()
        XCTAssertEqual(key.base64.count, 44)
        XCTAssertEqual(WireGuardKey(base64: key.base64 + "\n"), key)
        XCTAssertNil(WireGuardKey(base64: "not a key"))
        XCTAssertNil(WireGuardKey(base64: Data(count: 16).base64EncodedString()))
    }

    func testLicenseKeyValidation() {
        XCTAssertTrue(LicenseKey.isValid("ABCDEFGH-12345678-abcdefgh"))
        XCTAssertFalse(LicenseKey.isValid("ABCDEFGH-12345678"))
        XCTAssertFalse(LicenseKey.isValid("ABCDEFGH-12345678-abcdefg-"))
        XCTAssertFalse(LicenseKey.isValid("ABCDEFGH_12345678_abcdefgh"))
        XCTAssertFalse(LicenseKey.isValid("ABCDEFGH-12345678-abcdefgé"))
    }

    func testResolvePrivateKey() throws {
        let key = WireGuardKey.generatePrivate()
        XCTAssertEqual(try AppModel.resolvePrivateKey(" \(key.base64) "), key)
        XCTAssertNoThrow(try AppModel.resolvePrivateKey(""))
        XCTAssertThrowsError(try AppModel.resolvePrivateKey("ABCDEFGH-12345678-abcdefgh")) {
            XCTAssertEqual($0 as? WGCFError, .privateKeyLooksLikeLicense)
        }
        XCTAssertThrowsError(try AppModel.resolvePrivateKey("garbage")) {
            XCTAssertEqual($0 as? WGCFError, .invalidPrivateKey)
        }
    }
}

final class WireGuardProfileTests: XCTestCase {
    private let tunnel = TunnelInfo(
        addressV4: "2", addressV6: "3", peerPublicKey: "4",
        endpoint: PeerEndpoint(host: "5", v4: "162.159.192.1:0", v6: "[2606:4700:d0::a29f:c001]:0", ports: [2408, 500]))

    /// 与 wgcf 的 profile_test.go 使用相同的期望输出。
    func testDefaultProfileMatchesWgcf() throws {
        let expected = """
        [Interface]
        PrivateKey = 1
        Address = 2/32, 3/128
        DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
        MTU = 1280
        [Peer]
        PublicKey = 4
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 5

        """
        XCTAssertEqual(try WireGuardProfile.render(privateKey: "1", tunnel: tunnel), expected)
    }

    func testKeepalive() throws {
        var options = ProfileOptions()
        options.keepalive = 25
        let profile = try WireGuardProfile.render(privateKey: "1", tunnel: tunnel, options: options)
        XCTAssertTrue(profile.hasSuffix("Endpoint = 5\nPersistentKeepalive = 25\n"))

        options.keepalive = 65536
        XCTAssertThrowsError(try WireGuardProfile.render(privateKey: "1", tunnel: tunnel, options: options))
        options.keepalive = -1
        XCTAssertThrowsError(try WireGuardProfile.render(privateKey: "1", tunnel: tunnel, options: options))
    }

    func testCustomOptions() throws {
        var options = ProfileOptions()
        options.dns = "  "
        options.mtu = 1420
        options.allowedIPs = "10.0.0.0/8"
        options.endpointMode = .ipv6
        let profile = try WireGuardProfile.render(privateKey: "1", tunnel: tunnel, options: options)
        XCTAssertFalse(profile.contains("DNS"))
        XCTAssertTrue(profile.contains("MTU = 1420\n"))
        XCTAssertTrue(profile.contains("AllowedIPs = 10.0.0.0/8\n"))
        XCTAssertTrue(profile.contains("Endpoint = [2606:4700:d0::a29f:c001]:2408\n"))
    }

    func testEndpointSelection() throws {
        let full = tunnel.endpoint
        XCTAssertEqual(try WireGuardProfile.endpoint(full), "5")
        XCTAssertEqual(try WireGuardProfile.endpoint(full, mode: .ipv4), "162.159.192.1:2408")
        XCTAssertEqual(try WireGuardProfile.endpoint(full, mode: .ipv6), "[2606:4700:d0::a29f:c001]:2408")

        XCTAssertEqual(try WireGuardProfile.endpoint(full, port: 4500), "5:4500")
        XCTAssertEqual(try WireGuardProfile.endpoint(full, mode: .ipv4, port: 500), "162.159.192.1:500")
        let named = PeerEndpoint(host: "engage.cloudflareclient.com:2408", v4: nil, v6: nil, ports: nil)
        XCTAssertEqual(try WireGuardProfile.endpoint(named, port: 1701), "engage.cloudflareclient.com:1701")

        let noHost = PeerEndpoint(host: "", v4: "162.159.192.1:0", v6: "", ports: nil)
        XCTAssertEqual(try WireGuardProfile.endpoint(noHost), "162.159.192.1:2408")
        XCTAssertThrowsError(try WireGuardProfile.endpoint(noHost, mode: .ipv6))

        let onlyV6 = PeerEndpoint(host: nil, v4: nil, v6: "2606:4700:d0::1", ports: [4500])
        XCTAssertEqual(try WireGuardProfile.endpoint(onlyV6), "[2606:4700:d0::1]:4500")

        XCTAssertThrowsError(try WireGuardProfile.endpoint(PeerEndpoint())) {
            XCTAssertEqual($0 as? WGCFError, .missingEndpoint)
        }
    }

    func testTunnelInfoFromDevice() throws {
        let json = """
        {"id":"d","config":{"client_id":"c","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606::2"}},
        "peers":[{"public_key":"pk","endpoint":{"host":"engage.cloudflareclient.com:2408","v4":"162.159.192.1:0","v6":"[2606::1]:0"}}]}}
        """
        let device = try JSONDecoder().decode(SourceDevice.self, from: Data(json.utf8))
        let info = try WireGuardProfile.tunnelInfo(from: device)
        XCTAssertEqual(info.addressV4, "172.16.0.2")
        XCTAssertEqual(info.addressV6, "2606::2")
        XCTAssertEqual(info.peerPublicKey, "pk")
        XCTAssertEqual(try WireGuardProfile.endpoint(info.endpoint), "engage.cloudflareclient.com:2408")

        XCTAssertThrowsError(try WireGuardProfile.tunnelInfo(from: SourceDevice(id: "d"))) {
            XCTAssertEqual($0 as? WGCFError, .missingPeer)
        }
    }
}

final class AccountFileTests: XCTestCase {
    func testRoundTrip() throws {
        let credentials = Credentials(
            deviceId: "device", accessToken: "token",
            privateKey: WireGuardKey.generatePrivate().base64, licenseKey: "ABCDEFGH-12345678-abcdefgh")
        XCTAssertEqual(try AccountFile.decode(AccountFile.encode(credentials)), credentials)
    }

    func testDecodeTolerantFormatting() throws {
        let key = WireGuardKey.generatePrivate().base64
        let text = """
        # comment
        access_token = "token"
        device_id='device'

        private_key = '\(key)'
        """
        let credentials = try AccountFile.decode(text)
        XCTAssertEqual(credentials.accessToken, "token")
        XCTAssertEqual(credentials.deviceId, "device")
        XCTAssertEqual(credentials.privateKey, key)
        XCTAssertEqual(credentials.licenseKey, "")
    }

    func testDecodeRejectsIncompleteFile() {
        XCTAssertThrowsError(try AccountFile.decode("device_id = 'x'"))
        XCTAssertThrowsError(try AccountFile.decode("device_id = 'x'\naccess_token = 'y'\nprivate_key = 'bad'"))
    }
}

final class TraceTests: XCTestCase {
    func testParse() {
        let result = TraceResult.parse("fl=1f1\nip=1.2.3.4\nloc=US\nwarp=plus\nuag=a=b\n")
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(result.warp, "plus")
        XCTAssertEqual(result["ip"], "1.2.3.4")
        XCTAssertEqual(result["uag"], "a=b")
        XCTAssertNil(result["missing"])
    }
}
