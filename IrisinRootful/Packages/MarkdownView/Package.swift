// swift-tools-version: 6.0

import PackageDescription

/// MarkdownView, vendored from Lakr233/MarkdownView 4.6.7 for UIKit alone,
/// without math or code highlighting. README.md says what changed.
let package = Package(
    name: "MarkdownView",
    platforms: [
        .iOS(.v12),
    ],
    products: [
        .library(name: "MarkdownView", targets: ["MarkdownView"]),
        .library(name: "MarkdownParser", targets: ["MarkdownParser"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/Litext"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.7.3"),
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.9.0"),
        .package(path: "../../Vendor/LRUCache"),
        .package(path: "../../Vendor/OpenCombine"),
        .package(path: "../../Vendor/LegacyCompat"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
                "Litext",
                "MarkdownParser",
                "LRUCache",
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "OpenCombine", package: "OpenCombine"),
                .product(name: "OpenCombineDispatch", package: "OpenCombine"),
                .product(name: "LegacyCompat", package: "LegacyCompat"),
            ]
        ),
        .target(
            name: "MarkdownParser",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
    ],
    // iOS 12 port: Swift 5 mode (no concurrency checking to satisfy)
    swiftLanguageModes: [.v5]
)
