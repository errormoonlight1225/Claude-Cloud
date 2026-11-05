// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "Dog",
    platforms: [
        .iOS(.v12),
        .macOS(.v11),
        .watchOS(.v7),
        .tvOS(.v12),
    ],
    products: [
        .library(name: "Dog", targets: ["Dog"]),
    ],
    targets: [
        .target(name: "Dog", dependencies: []),
    ]
)
