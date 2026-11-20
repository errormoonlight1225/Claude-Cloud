import CommonCrypto
import Foundation
import Security

/// Re-packs a certificate and its RSA private key into a new PKCS#12 archive
/// under a password of the user's choosing. iOS can read `.p12` files but has
/// no public API to write them (`SecItemExport` is macOS-only), so the archive
/// is built here by hand, following RFC 7292:
///
/// - the certificate bag in an `encryptedData` safe,
/// - the key as a `pkcs8ShroudedKeyBag`,
/// - both encrypted with pbeWithSHAAnd3-KeyTripleDES-CBC (what iOS, macOS,
///   OpenSSL 3 and most signing tools read without a "legacy" switch),
/// - an HMAC-SHA1 MAC over the contents.
enum P12Builder {
    enum BuildError: LocalizedError {
        case cannotOpen
        case noPrivateKey
        case notRSA
        case keyNotExportable(String)
        case crypto(Int32)
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "无法用原密码打开这个 .p12，所以无法改密码。"
            case .noPrivateKey: return "这个 .p12 里没有私钥。"
            case .notRSA: return "仅支持 RSA 私钥（Apple 开发证书都是 RSA）。"
            case .keyNotExportable(let why): return "无法读取私钥：\(why)"
            case .crypto(let status): return "加密失败（\(status)）。"
            case .verifyFailed: return "生成的 .p12 无法用新密码打开，已取消。"
            }
        }
    }

    static let iterations = 2048

    /// A copy of `certificate` re-encrypted with `newPassword`.
    static func rewrap(_ certificate: ExportedCertificate, newPassword: String) throws -> ExportedCertificate {
        guard let details = certificate.details else { throw BuildError.cannotOpen }
        let (identity, certDER) = try openIdentity(certificate.p12Data, password: details.workingPassword)

        var keyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else {
            throw BuildError.noPrivateKey
        }
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        guard (attributes?[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeRSA as String) else {
            throw BuildError.notRSA
        }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            let why = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw BuildError.keyNotExportable(why)
        }

        let name = details.commonName ?? "SideStore"
        let data = try build(pkcs1RSAKey: [UInt8](pkcs1), certificate: [UInt8](certDER),
                             password: newPassword, friendlyName: name)

        // Never hand out a file iOS itself can't open with the new password.
        guard (try? openIdentity(data, password: newPassword)) != nil else { throw BuildError.verifyFailed }
        return ExportedCertificate(p12Data: data, password: newPassword,
                                   source: "\(certificate.source) · 已改密码")
    }

    private static func openIdentity(_ data: Data, password: String) throws -> (SecIdentity, Data) {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else { throw BuildError.cannotOpen }
        let identity = identityRef as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw BuildError.cannotOpen
        }
        return (identity, SecCertificateCopyData(cert) as Data)
    }

    // MARK: - Archive

    static func build(pkcs1RSAKey: [UInt8], certificate: [UInt8], password: String,
                      friendlyName: String) throws -> Data {
        let pw = bmpPassword(password)
        let localKeyID = sha1(certificate)
        let attributes = DER.set(
            DER.seq(OID.friendlyName, DER.set(DER.tlv(0x1E, Array(friendlyName.utf16BigEndian)))),
            DER.seq(OID.localKeyID, DER.set(DER.octet(localKeyID)))
        )
        func algorithm(_ salt: [UInt8]) -> [UInt8] {
            DER.seq(OID.pbeSHA3DES, DER.seq(DER.octet(salt), DER.integer(iterations)))
        }

        // Certificate, in an encrypted safe.
        let certSafe = DER.seq(DER.seq(
            OID.certBag,
            DER.context0(DER.seq(OID.x509Certificate, DER.context0(DER.octet(certificate)))),
            attributes
        ))
        let certSalt = randomBytes(8)
        let certInfo = DER.seq(OID.encryptedData, DER.context0(DER.seq(
            DER.integer(0),
            DER.seq(OID.data, algorithm(certSalt),
                    DER.tlv(0x80, try encrypt(certSafe, password: pw, salt: certSalt)))
        )))

        // Private key, as a shrouded key bag in a plain safe.
        let pkcs8 = DER.seq(DER.integer(0), DER.seq(OID.rsaEncryption, DER.null), DER.octet(pkcs1RSAKey))
        let keySalt = randomBytes(8)
        let keySafe = DER.seq(DER.seq(
            OID.shroudedKeyBag,
            DER.context0(DER.seq(algorithm(keySalt), DER.octet(try encrypt(pkcs8, password: pw, salt: keySalt)))),
            attributes
        ))
        let keyInfo = DER.seq(OID.data, DER.context0(DER.octet(keySafe)))

        let authSafe = DER.seq(certInfo, keyInfo)

        let macSalt = randomBytes(8)
        let macKey = kdf(password: pw, salt: macSalt, id: 3, iterations: iterations, length: 20)
        let mac = hmacSHA1(key: macKey, data: authSafe)

        let pfx = DER.seq(
            DER.integer(3),
            DER.seq(OID.data, DER.context0(DER.octet(authSafe))),
            DER.seq(DER.seq(DER.seq(OID.sha1, DER.null), DER.octet(mac)),
                    DER.octet(macSalt), DER.integer(iterations))
        )
        return Data(pfx)
    }

    // MARK: - Crypto

    /// The password as PKCS#12 wants it: UTF-16 big-endian plus a 0x0000 terminator.
    static func bmpPassword(_ password: String) -> [UInt8] {
        Array(password.utf16BigEndian) + [0, 0]
    }

    /// RFC 7292 appendix B.2 key derivation with SHA-1 (u = 20, v = 64).
    static func kdf(password: [UInt8], salt: [UInt8], id: UInt8, iterations: Int, length: Int) -> [UInt8] {
        let v = 64
        let d = [UInt8](repeating: id, count: v)
        func repeated(_ x: [UInt8]) -> [UInt8] {
            guard !x.isEmpty else { return [] }
            let count = v * ((x.count + v - 1) / v)
            return (0..<count).map { x[$0 % x.count] }
        }
        var i = repeated(salt) + repeated(password)
        var out: [UInt8] = []
        while out.count < length {
            var a = sha1(d + i)
            for _ in 1..<iterations { a = sha1(a) }
            out += a
            let b = (0..<v).map { a[$0 % a.count] }
            var j = 0
            while j < i.count {
                var carry = 1
                for k in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(i[j + k]) + Int(b[k]) + carry
                    i[j + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
                j += v
            }
        }
        return Array(out.prefix(length))
    }

    private static func encrypt(_ plain: [UInt8], password: [UInt8], salt: [UInt8]) throws -> [UInt8] {
        let key = kdf(password: password, salt: salt, id: 1, iterations: iterations, length: kCCKeySize3DES)
        let iv = kdf(password: password, salt: salt, id: 2, iterations: iterations, length: kCCBlockSize3DES)
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSize3DES)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES),
                             CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, plain, plain.count,
                             &out, out.count, &moved)
        guard Int(status) == kCCSuccess else { throw BuildError.crypto(status) }
        return Array(out.prefix(moved))
    }

    private static func sha1(_ data: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = CC_SHA1(data, CC_LONG(data.count), &digest)
        return digest
    }

    private static func hmacSHA1(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, data, data.count, &mac)
        return mac
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

private extension String {
    var utf16BigEndian: [UInt8] {
        utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

/// Minimal DER encoder.
private enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var lengthBytes: [UInt8] = []
            var rest = n
            while rest > 0 { lengthBytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
            out.append(0x80 | UInt8(lengthBytes.count))
            out += lengthBytes
        }
        return out + content
    }
    static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static func octet(_ content: [UInt8]) -> [UInt8] { tlv(0x04, content) }
    static func context0(_ content: [UInt8]) -> [UInt8] { tlv(0xA0, content) }
    static let null: [UInt8] = [0x05, 0x00]
    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }
}

private enum OID {
    private static func make(_ bytes: [UInt8]) -> [UInt8] { DER.tlv(0x06, bytes) }
    private static let pkcs: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01]
    static let data = make(pkcs + [0x07, 0x01])
    static let encryptedData = make(pkcs + [0x07, 0x06])
    static let rsaEncryption = make(pkcs + [0x01, 0x01])
    static let pbeSHA3DES = make(pkcs + [0x0C, 0x01, 0x03])
    static let shroudedKeyBag = make(pkcs + [0x0C, 0x0A, 0x01, 0x02])
    static let certBag = make(pkcs + [0x0C, 0x0A, 0x01, 0x03])
    static let x509Certificate = make(pkcs + [0x09, 0x16, 0x01])
    static let friendlyName = make(pkcs + [0x09, 0x14])
    static let localKeyID = make(pkcs + [0x09, 0x15])
    static let sha1 = make([0x2B, 0x0E, 0x03, 0x02, 0x1A])
}
