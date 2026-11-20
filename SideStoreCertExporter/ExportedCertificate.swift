import Foundation
import Security

/// A SideStore signing certificate: its PKCS#12 archive (certificate + private
/// key) and the archive's password. SideStore uses the certificate's serial
/// number as the password; newer SideStore builds may write unencrypted
/// archives, in which case the password is ignored.
struct ExportedCertificate: Identifiable, Equatable {
    let id = UUID()
    let p12Data: Data
    let password: String
    /// Where it came from, shown in the UI.
    let source: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.p12Data == rhs.p12Data && lhs.password == rhs.password
    }

    /// A certificate archive is a few KB and is a DER SEQUENCE.
    static func isPlausibleArchive(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= 256 << 10 && data.first == 0x30
    }

    // MARK: - Details read from the archive

    struct Details {
        var commonName: String?
        var serialHex: String?
        var notAfter: Date?
        /// The password that opened the archive ("" for an unencrypted one).
        var workingPassword: String
    }

    /// Opens the archive with the password (then with an empty one) and reads
    /// the signing certificate. Nil if iOS can't open it with either.
    var details: Details? {
        var candidates = [password]
        if !password.isEmpty { candidates.append("") }
        for candidate in candidates {
            if let details = Self.readDetails(p12Data, password: candidate) { return details }
        }
        return nil
    }

    private static func readDetails(_ data: Data, password: String) -> Details? {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first
        else { return nil }

        var certificate: SecCertificate?
        if let identityRef = first[kSecImportItemIdentity as String] {
            let identity = identityRef as! SecIdentity
            SecIdentityCopyCertificate(identity, &certificate)
        }
        if certificate == nil, let chain = first[kSecImportItemCertChain as String] as? [SecCertificate] {
            certificate = chain.first
        }

        var details = Details(workingPassword: password)
        if let certificate {
            details.commonName = SecCertificateCopySubjectSummary(certificate) as String?
            if let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data? {
                details.serialHex = serial.map { String(format: "%02X", $0) }.joined()
            }
            details.notAfter = DERCertificate.notAfter(SecCertificateCopyData(certificate) as Data)
        }
        return details
    }

    // MARK: - Files

    /// A file-name-safe stem, using the serial when it is known.
    var fileStem: String {
        let serial = details?.serialHex ?? password
        let safe = serial.filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? "SideStore-Certificate" : "SideStore-\(safe.prefix(40))"
    }

    /// Writes `<stem>.p12` and `<stem>-password.txt` into `directory`.
    @discardableResult
    func write(to directory: URL) throws -> (p12: URL, password: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let p12URL = directory.appendingPathComponent("\(fileStem).p12")
        let passwordURL = directory.appendingPathComponent("\(fileStem)-password.txt")
        try p12Data.write(to: p12URL, options: .atomic)
        try Data(password.utf8).write(to: passwordURL, options: .atomic)
        return (p12URL, passwordURL)
    }
}

/// Just enough DER to read an X.509 certificate's expiry date, which iOS has
/// no public API for.
enum DERCertificate {
    static func notAfter(_ der: Data) -> Date? {
        let bytes = [UInt8](der)
        var index = 0
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { … } … }
        guard enter(bytes, &index, tag: 0x30), enter(bytes, &index, tag: 0x30) else { return nil }
        // Optional [0] version.
        if index < bytes.count, bytes[index] == 0xA0 { guard skip(bytes, &index) else { return nil } }
        // serialNumber, signature, issuer.
        for _ in 0..<3 { guard skip(bytes, &index) else { return nil } }
        // validity SEQUENCE { notBefore, notAfter }
        guard enter(bytes, &index, tag: 0x30), skip(bytes, &index) else { return nil }
        guard index < bytes.count else { return nil }
        let tag = bytes[index]
        guard let field = header(bytes, &index) else { return nil }
        let start = field.start, length = field.length
        guard start + length <= bytes.count,
              let text = String(bytes: bytes[start..<start + length], encoding: .ascii)
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return formatter.date(from: text)
    }

    /// Reads a tag + length at `index`; leaves `index` at the contents.
    private static func header(_ b: [UInt8], _ index: inout Int) -> (start: Int, length: Int)? {
        guard index + 1 < b.count else { return nil }
        index += 1
        var length = Int(b[index]); index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= b.count else { return nil }
            length = 0
            for _ in 0..<count { length = (length << 8) | Int(b[index]); index += 1 }
        }
        return (start: index, length: length)
    }

    private static func enter(_ b: [UInt8], _ index: inout Int, tag: UInt8) -> Bool {
        guard index < b.count, b[index] == tag else { return false }
        return header(b, &index) != nil
    }

    private static func skip(_ b: [UInt8], _ index: inout Int) -> Bool {
        guard let field = header(b, &index), field.start + field.length <= b.count else { return false }
        index = field.start + field.length
        return true
    }
}
