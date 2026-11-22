// swift-tools-version: 6.0
// CPRemote: native macOS app that draws the front panels of Dolby cinema
// processors and controls them through the released cpseries library
// (../cpseries-release).

import PackageDescription

let package = Package(
    name: "CPRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CPRemote", targets: ["CPRemote"]),
    ],
    dependencies: [
        .package(path: "../cpseries-release"),
    ],
    targets: [
        .executableTarget(
            name: "CPRemote",
            dependencies: [.product(name: "CPSeries", package: "cpseries-release")]
        ),
        // The app's model: persistence, rendering, the connection log.
        .testTarget(
            name: "CPRemoteTests",
            dependencies: ["CPRemote"]
        ),
    ]
)
