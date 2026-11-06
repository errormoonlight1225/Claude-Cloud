// swift-tools-version: 6.0
import PackageDescription

/// What the iOS 12 port needs in place of APIs that arrived in iOS 13 and
/// later: localization lookups without String.LocalizationValue, the iOS 13
/// system colours, SF Symbol fallbacks, locks and dispatch helpers that stand
/// in for actors and tasks, and FileHandle calls that throw. Only Foundation,
/// UIKit and Darwin, so every vendored package can depend on it.
let package = Package(
    name: "LegacyCompat",
    platforms: [.iOS(.v12), .tvOS(.v12), .macOS(.v10_14)],
    products: [
        .library(name: "LegacyCompat", targets: ["LegacyCompat"]),
        .library(name: "LegacyCrypto", targets: ["LegacyCrypto"]),
    ],
    targets: [
        .target(name: "LegacyCompat", dependencies: ["LegacyRuntime"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // what the compiler calls by name and iOS 12's libSystem lacks
        .target(name: "LegacyRuntime"),
        // SHA256 and Insecure.MD5 with CryptoKit's spelling, on CommonCrypto.
        .target(name: "LegacyCrypto", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
