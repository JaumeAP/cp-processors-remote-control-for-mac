// swift-tools-version: 6.0
// CPRemote: native macOS app that controls Dolby cinema processors over TCP/IP.

import PackageDescription

let package = Package(
    name: "CPRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CPRemote", targets: ["CPRemote"]),
    ],
    targets: [
        // Live control of the Dolby cinema processors (the Swift port of
        // library), kept out of the app target so the tests can import it.
        .target(name: "CPx50Comms"),
        .executableTarget(
            name: "CPRemote",
            dependencies: ["CPx50Comms"]
        ),
        // The app's model driven against the simulator, stress included.
        .testTarget(
            name: "CPRemoteTests",
            dependencies: ["CPRemote", "CPx50Comms"]
        ),
        .testTarget(
            name: "CPx50CommsTests",
            dependencies: ["CPx50Comms"]
        ),
    ]
)
