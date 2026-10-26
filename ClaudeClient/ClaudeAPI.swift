import Foundation

enum StreamEvent {
    case started(model: String)
    case thinkingDelta(String)
    case textDelta(String)
    case fallback(to: String)
    case finished(stopReason: String?, refusalCategory: String?)
    case failed(String)
    case cancelled
}

/// Streams one Messages API request over SSE. Uses URLSessionDataDelegate so it works on iOS 12
/// (no async/await, no URLSession.bytes).
final class ClaudeStream: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let handler: (StreamEvent) -> Void

    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var httpStatus = 200
    private var errorBody = Data()
    private var blockTypes: [Int: String] = [:]
    private var stopReason: String?
    private var refusalCategory: String?
    private var finished = false

    init(handler: @escaping (StreamEvent) -> Void) {
        self.handler = handler
    }

    static func makeRequest(messages: [[String: Any]]) throws -> URLRequest {
        let option = Settings.modelOption
        let base = Settings.baseURL.hasSuffix("/") ? String(Settings.baseURL.dropLast()) : Settings.baseURL
        guard let url = URL(string: base + "/v1/messages") else {
            throw NSError(domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "API 地址无效"])
        }
        var body: [String: Any] = [
            "model": option.id,
            "max_tokens": option.supportsThinking ? 64000 : 8192,
            "stream": true,
            "messages": messages,
        ]
        let system = Settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            body["system"] = system
        }
        if option.supportsThinking {
            body["thinking"] = ["type": "adaptive", "display": Settings.showThinking ? "summarized" : "omitted"]
            body["output_config"] = ["effort": Settings.effort]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if option.supportsFallbacks {
            // Re-runs a safety-classifier refusal on Anthropic's recommended fallback model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    func start(_ request: URLRequest) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if httpStatus != 200 {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            handleLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                emit(.cancelled)
            } else {
                emit(.failed(error.localizedDescription))
            }
            return
        }
        if httpStatus != 200 {
            emit(.failed(ClaudeStream.describeError(status: httpStatus, body: errorBody)))
            return
        }
        if !dataLines.isEmpty { dispatchEvent() }
        if !finished {
            emit(.finished(stopReason: stopReason, refusalCategory: refusalCategory))
        }
    }

    // MARK: - SSE parsing

    private func handleLine(_ line: String) {
        if line.isEmpty {
            dispatchEvent()
        } else if line.hasPrefix("event:") {
            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
    }

    private func dispatchEvent() {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty,
              let data = dataLines.joined(separator: "\n").data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let type = json["type"] as? String ?? eventName else { return }

        switch type {
        case "message_start":
            let message = json["message"] as? [String: Any]
            emit(.started(model: message?["model"] as? String ?? ""))
        case "content_block_start":
            let index = json["index"] as? Int ?? -1
            let block = json["content_block"] as? [String: Any] ?? [:]
            let blockType = block["type"] as? String ?? ""
            blockTypes[index] = blockType
            if blockType == "fallback" {
                let to = (block["to"] as? [String: Any])?["model"] as? String ?? ""
                emit(.fallback(to: to))
            } else if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                emit(.textDelta(text))
            }
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { emit(.textDelta(text)) }
            case "thinking_delta":
                if let text = delta["thinking"] as? String { emit(.thinkingDelta(text)) }
            default:
                break
            }
        case "message_delta":
            let delta = json["delta"] as? [String: Any] ?? [:]
            if let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            let details = delta["stop_details"] as? [String: Any] ?? json["stop_details"] as? [String: Any]
            if let category = details?["category"] as? String {
                refusalCategory = category
            }
        case "message_stop":
            finished = true
            emit(.finished(stopReason: stopReason, refusalCategory: refusalCategory))
        case "error":
            let error = json["error"] as? [String: Any]
            finished = true
            emit(.failed(error?["message"] as? String ?? "流式响应出错"))
        default:
            break
        }
    }

    private func emit(_ event: StreamEvent) {
        DispatchQueue.main.async { self.handler(event) }
    }

    static func describeError(status: Int, body: Data) -> String {
        if let json = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            let type = error["type"] as? String ?? ""
            return "HTTP \(status) \(type): \(message)"
        }
        switch status {
        case 401: return "HTTP 401：API Key 无效"
        case 429: return "HTTP 429：请求过于频繁，请稍后重试"
        case 529: return "HTTP 529：服务繁忙，请稍后重试"
        default:
            let text = String(decoding: body.prefix(300), as: UTF8.self)
            return "HTTP \(status) \(text)"
        }
    }
}
