import Foundation

enum Formatting {
    static func bytes(_ value: Int64?) -> String {
        ByteCountFormatter.string(fromByteCount: value ?? 0, countStyle: .decimal)
    }

    /// 把 API 返回的 RFC 3339 时间转成本地化显示；无法解析时原样返回。
    static func date(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFraction.date(from: value) ?? plain.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func accountType(_ value: String?) -> String {
        switch value {
        case "free": return "免费版 (WARP)"
        case "limited": return "WARP+（限量）"
        case "unlimited": return "WARP+（无限量）"
        case "team": return "Zero Trust 团队"
        case .some(let other): return other
        case .none: return "—"
        }
    }

    static func role(_ value: String?) -> String {
        switch value {
        case "parent": return "主设备"
        case "child": return "子设备"
        case .some(let other): return other
        case .none: return "—"
        }
    }
}
