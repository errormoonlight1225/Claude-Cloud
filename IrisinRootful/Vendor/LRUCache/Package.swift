// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LRUCache",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_15),
        .tvOS(.v12),
        .visionOS(.v1),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "LRUCache", targets: ["LRUCache"]),
    ],
    targets: [
        .target(name: "LRUCache", path: "Sources"),
    ]
)
