import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa", conformingTo: .zip) ?? .zip
    static let p12 = UTType(filenameExtension: "p12") ?? .data
    static let mobileProvision = UTType(filenameExtension: "mobileprovision") ?? .data
    static let p8 = UTType(filenameExtension: "p8") ?? .data
}

/// Reads a file returned by a document picker.
func readPicked(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so share sheets can be driven by `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ErrorMessage: Identifiable {
    let id = UUID()
    let text: String
    init(_ error: Error) { text = error.localizedDescription }
    init(_ text: String) { self.text = text }
}

extension View {
    func errorAlert(_ error: Binding<ErrorMessage?>) -> some View {
        alert("出错了", isPresented: Binding(get: { error.wrappedValue != nil },
                                         set: { if !$0 { error.wrappedValue = nil } })) {
            Button("好") { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue?.text ?? "")
        }
    }
}

struct AppIcon: View {
    let image: UIImage?
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
    }
}

struct LogConsole: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.contains("Failed") || line.contains("failed") || line.hasPrefix("错误") ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func remaining(_ date: Date) -> String {
        let days = Int(date.timeIntervalSinceNow / 86400)
        if date < Date() { return "已过期" }
        if days < 1 { return "不到 1 天" }
        return "剩余 \(days) 天"
    }

    static func expiryColor(_ date: Date) -> Color {
        let days = date.timeIntervalSinceNow / 86400
        return days < 0 ? .red : (days < 14 ? .orange : .green)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
