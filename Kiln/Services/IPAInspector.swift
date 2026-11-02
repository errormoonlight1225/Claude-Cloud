import Foundation
import UIKit

/// Reads metadata out of an .ipa without unpacking the whole archive.
enum IPAInspector {
    struct Info {
        var name: String
        var bundleID: String
        var version: String
        var build: String
        var minimumOSVersion: String
        var extensionBundleIDs: [String]
        var hasWatchApp: Bool
        var icon: UIImage?
    }

    static func inspect(ipa: URL) throws -> Info {
        let path = ipa.path
        let entries = try Core.zipEntries(at: path)

        // Payload/<Name>.app/Info.plist
        guard let infoEntry = entries.first(where: { entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else {
            throw KilnError("不是有效的 IPA：找不到 Payload/*.app/Info.plist")
        }
        let appRoot = String(infoEntry.dropLast("Info.plist".count))  // "Payload/X.app/"
        let plist = try readPlist(infoEntry, in: path)

        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        guard !bundleID.isEmpty else { throw KilnError("Info.plist 缺少 CFBundleIdentifier") }
        let name = (plist["CFBundleDisplayName"] as? String).nonEmpty
            ?? (plist["CFBundleName"] as? String).nonEmpty
            ?? (plist["CFBundleExecutable"] as? String) ?? "App"

        // Top level app extensions: Payload/X.app/PlugIns/Y.appex/Info.plist (and Extensions/)
        var extensionIDs: [String] = []
        for entry in entries where entry.hasPrefix(appRoot) && entry.hasSuffix(".appex/Info.plist") {
            let rest = entry.dropFirst(appRoot.count).split(separator: "/")
            guard rest.count == 3, rest[0] == "PlugIns" || rest[0] == "Extensions" else { continue }
            if let id = try? readPlist(entry, in: path)["CFBundleIdentifier"] as? String {
                extensionIDs.append(id)
            }
        }
        let hasWatch = entries.contains { $0.hasPrefix(appRoot + "Watch/") }

        return Info(name: name,
                    bundleID: bundleID,
                    version: plist["CFBundleShortVersionString"] as? String ?? "1.0",
                    build: plist["CFBundleVersion"] as? String ?? "1",
                    minimumOSVersion: plist["MinimumOSVersion"] as? String ?? "",
                    extensionBundleIDs: extensionIDs,
                    hasWatchApp: hasWatch,
                    icon: icon(plist: plist, appRoot: appRoot, entries: entries, path: path))
    }

    private static func readPlist(_ entry: String, in path: String) throws -> [String: Any] {
        let data = try Core.readZipEntry(entry, at: path, maxSize: 8 << 20)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw KilnError("无法解析 \(entry)")
        }
        return plist
    }

    /// Picks the largest PNG among the declared primary icon files (UIImage handles Apple's CgBI PNGs).
    private static func icon(plist: [String: Any], appRoot: String, entries: [String], path: String) -> UIImage? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = plist[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                names += files
            }
        }
        if let files = plist["CFBundleIconFiles"] as? [String] { names += files }
        if names.isEmpty { names = ["AppIcon", "Icon"] }

        let candidates = entries.filter { entry in
            guard entry.hasPrefix(appRoot), entry.lowercased().hasSuffix(".png") else { return false }
            let file = String(entry.dropFirst(appRoot.count))
            guard !file.contains("/") else { return false }
            return names.contains { file.hasPrefix($0) }
        }
        var best: UIImage?
        for entry in candidates {
            guard let data = try? Core.readZipEntry(entry, at: path, maxSize: 4 << 20),
                  let image = UIImage(data: data) else { continue }
            if (image.size.width * image.scale) > ((best?.size.width ?? 0) * (best?.scale ?? 1)) {
                best = image
            }
        }
        return best
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
