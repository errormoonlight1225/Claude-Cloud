import Foundation

/// The deep-link handshake SideStore offers for handing its signing
/// certificate to another app (the same one SideInstaller uses to import it):
///
/// 1. We open `sidestore://certificate?callback_template=<template>`, with the
///    whole template percent-encoded (SideStore percent-decodes it once).
/// 2. SideStore asks the user "Export Certificate?" and, on yes, replaces
///    `$(BASE64_CERT)` with its PKCS#12 archive (base64, then percent-encoded)
///    and `$(PASSWORD)` with the archive's password (verbatim), then opens the
///    resulting URL.
/// 3. iOS hands that URL back to us: `sscertexport://certificate?data=…&password=…`.
enum SideStoreLink {
    /// Our URL scheme, registered in Info.plist.
    static let scheme = "sscertexport"

    /// The password goes last, so a password that contains `&` is still read whole.
    static let callbackTemplate = "\(scheme)://certificate?data=$(BASE64_CERT)&password=$(PASSWORD)"

    /// The link that asks SideStore for its certificate.
    static var requestURL: URL? {
        let encoded = callbackTemplate.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "sidestore://certificate?callback_template=\(encoded)")
    }

    enum ParseError: LocalizedError {
        case notOurs
        case noData
        case badData

        var errorDescription: String? {
            switch self {
            case .notOurs: return "这不是证书回调链接。"
            case .noData: return "SideStore 返回的链接中没有证书数据。"
            case .badData: return "SideStore 返回的证书数据无法解码。"
            }
        }
    }

    /// Reads SideStore's reply.
    static func parse(_ url: URL) throws -> ExportedCertificate {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == "certificate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery
        else { throw ParseError.notOurs }

        // Split by hand rather than with `queryItems`: the password is
        // inserted verbatim and may contain `&`, `=` or `+`.
        var dataPart = ""
        var passwordPart = ""
        if let range = query.range(of: "&password=", options: .caseInsensitive) {
            dataPart = String(query[..<range.lowerBound])
            passwordPart = String(query[range.upperBound...])
        } else {
            dataPart = query
        }
        guard dataPart.lowercased().hasPrefix("data=") else { throw ParseError.noData }
        dataPart.removeFirst("data=".count)

        let base64 = dataPart.removingPercentEncoding ?? dataPart
        guard !base64.isEmpty else { throw ParseError.noData }
        guard let data = decodeBase64(base64), ExportedCertificate.isPlausibleArchive(data) else {
            throw ParseError.badData
        }
        let password = passwordPart.removingPercentEncoding ?? passwordPart
        return ExportedCertificate(p12Data: data, password: password, source: "SideStore（链接回调）")
    }

    /// Lenient base64: `+` turned into a space, base64url, whitespace, missing padding.
    static func decodeBase64(_ text: String) -> Data? {
        var cleaned = text
            .replacingOccurrences(of: " ", with: "+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }
        let remainder = cleaned.count % 4
        if remainder != 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }
}
