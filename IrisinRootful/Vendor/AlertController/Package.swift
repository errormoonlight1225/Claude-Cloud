// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AlertController",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v12),
        .macCatalyst(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(name: "AlertController", targets: ["AlertController"]),
    ],
    dependencies: [
        .package(path: "../LegacyCompat"),
    ],
    targets: [
        .target(
            name: "AlertController",
            dependencies: ["LegacyCompat"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
