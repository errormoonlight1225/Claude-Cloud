import Foundation
import Network
import Security

/// A tiny HTTPS server bound to the loopback interface. iOS's installer (installd) fetches the
/// manifest and the IPA from it after we open an itms-services:// link, so nothing leaves the device.
final class InstallServer {
    enum Body {
        case data(Data, contentType: String)
        case file(URL, contentType: String)
    }

    private let queue = DispatchQueue(label: "app.kiln.install-server")
    private var listener: NWListener?
    private var routes: [String: Body] = [:]
    private(set) var port: UInt16 = 0
    var onRequest: ((String) -> Void)?

    static func loadIdentity(p12: Data, password: String) throws -> (SecIdentity, [SecCertificate]) {
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw KilnError("无法加载安装服务器证书（错误 \(status)）")
        }
        let identity = identityRef as! SecIdentity  // CF type; cast always succeeds when present
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return (identity, chain)
    }

    func setRoutes(_ routes: [String: Body]) {
        queue.sync { self.routes = routes }
    }

    var isRunning: Bool { listener != nil }

    func start(p12: Data, password: String, port: UInt16) async throws {
        stop()
        let (identity, chain) = try Self.loadIdentity(p12: p12, password: password)

        let tls = NWProtocolTLS.Options()
        // The chain array starts with the leaf, so clients receive leaf + intermediates.
        let secIdentity = chain.isEmpty
            ? sec_identity_create(identity)
            : sec_identity_create_with_certificates(identity, chain as CFArray)
        guard let secIdentity else {
            throw KilnError("无法创建 TLS 身份")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw KilnError("端口无效") }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume()
                case let .failed(error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: KilnError("安装服务器启动失败：\(error.localizedDescription)"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(connection, header: buffer[..<end.lowerBound])
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHeaders(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, header: Data) {
        let text = String(decoding: header, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(connection, status: "400 Bad Request") }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?").first ?? "")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        onRequest?("\(method) \(path)")

        guard method == "GET" || method == "HEAD" else { return respond(connection, status: "405 Method Not Allowed") }
        guard let body = routes[path] else { return respond(connection, status: "404 Not Found") }
        let headOnly = method == "HEAD"

        switch body {
        case let .data(data, type):
            respond(connection, status: "200 OK", type: type, length: data.count, body: headOnly ? nil : data)
        case let .file(url, type):
            serveFile(connection, url: url, type: type, range: headers["range"], headOnly: headOnly)
        }
    }

    private func serveFile(_ connection: NWConnection, url: URL, type: String, range: String?, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return respond(connection, status: "404 Not Found")
        }
        let size = Int(FileManager.default.fileSize(url))
        var start = 0
        var end = size - 1
        var status = "200 OK"
        var extra: [String: String] = ["Accept-Ranges": "bytes"]
        if let range, range.hasPrefix("bytes="), let spec = range.dropFirst(6).split(separator: ",").first {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if bounds.count == 2 {
                if let s = bounds[0] {
                    start = s
                    if let e = bounds[1] { end = min(e, size - 1) }
                } else if let suffix = bounds[1] {
                    start = max(0, size - suffix)
                }
            }
            guard start <= end, start < size else {
                try? handle.close()
                return respond(connection, status: "416 Range Not Satisfiable",
                               extra: ["Content-Range": "bytes */\(size)"])
            }
            status = "206 Partial Content"
            extra["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }
        let length = end - start + 1
        sendHead(connection, status: status, type: type, length: length, extra: extra)
        guard !headOnly else {
            try? handle.close()
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { _ in connection.cancel() })
        }
        try? handle.seek(toOffset: UInt64(start))
        sendChunks(connection, handle: handle, remaining: length)
    }

    private func sendChunks(_ connection: NWConnection, handle: FileHandle, remaining: Int) {
        guard remaining > 0 else {
            try? handle.close()
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { _ in connection.cancel() })
        }
        let chunk = (try? handle.read(upToCount: min(remaining, 512 * 1024))) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            return connection.cancel()
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                return connection.cancel()
            }
            self?.sendChunks(connection, handle: handle, remaining: remaining - chunk.count)
        })
    }

    private func sendHead(_ connection: NWConnection, status: String, type: String, length: Int,
                          extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
    }

    private func respond(_ connection: NWConnection, status: String, type: String = "text/plain",
                         length: Int? = nil, body: Data? = nil, extra: [String: String] = [:]) {
        let payload = body ?? (length == nil ? Data(status.utf8) : nil)
        sendHead(connection, status: status, type: type, length: length ?? payload?.count ?? 0, extra: extra)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Guards a continuation against being resumed twice from a state handler.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
