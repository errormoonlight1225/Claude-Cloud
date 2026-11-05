// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Litext",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v12),
        .macCatalyst(.v13),
        .macOS(.v12),
        .tvOS(.v12),
        .visionOS(.v1),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "Litext", targets: ["Litext"]),
        .library(name: "LitextAnimation", targets: ["LitextAnimation"]),
    ],
    dependencies: [
        .package(path: "../DisplayLink"),
    ],
    targets: [
        .target(
            name: "Litext",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
        ),
        .target(
            name: "LitextAnimation",
            dependencies: [
                "Litext",
                .product(
                    name: "DisplayLink",
                    package: "DisplayLink",
                    condition: .when(platforms: [.iOS, .macCatalyst, .macOS, .tvOS, .visionOS]),
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
        ),
    ],
    swiftLanguageModes: [.v5],
)
