import Foundation

/// 对应 `wgcf trace`：通过 Cloudflare 的 trace 接口检查当前连接是否经过 WARP。
struct TraceResult: Equatable {
    struct Entry: Equatable, Identifiable {
        var key: String
        var value: String
        var id: String { key }
    }

    var entries: [Entry]

    subscript(key: String) -> String? {
        entries.first { $0.key == key }?.value
    }

    /// `off`、`on` 或 `plus`。
    var warp: String? { self["warp"] }

    static let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    static func parse(_ text: String) -> TraceResult {
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            entries.append(Entry(key: String(parts[0]), value: String(parts[1])))
        }
        return TraceResult(entries: entries)
    }

    static func fetch(session: URLSession = .shared) async throws -> TraceResult {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 隧道不通时请求会一直挂起，尽快给出结果。
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WGCFError.invalidResponse
        }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
