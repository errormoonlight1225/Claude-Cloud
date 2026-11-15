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
        let entries = text.split(whereSeparator: \.isNewline).compactMap { line -> Entry? in
            guard let separator = line.firstIndex(of: "=") else { return nil }
            return Entry(key: String(line[..<separator]), value: String(line[line.index(after: separator)...]))
        }
        return TraceResult(entries: entries)
    }

    static func fetch(session: URLSession = .shared) async throws -> TraceResult {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WGCFError.invalidResponse
        }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
