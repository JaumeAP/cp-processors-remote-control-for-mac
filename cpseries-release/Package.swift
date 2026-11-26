// swift-tools-version:6.0
// The released cpx50comms control client (CPSeries v2.1.0), as prebuilt
// binaries (see RELEASE.md). On macOS, `CPSeries` links the arm64 dynamic
// library through CPSeries.xcframework and exposes its plain-C API
// (cpx50comms_c.h) to Swift.
import PackageDescription

let package = Package(
    name: "CPSeriesRelease",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "CPSeries", targets: ["CPSeries"]),
    ],
    targets: [
        .binaryTarget(name: "CPSeriesC", path: "CPSeries.xcframework"),
        .target(
            name: "CPSeries",
            dependencies: ["CPSeriesC"],
            // The library is C++ inside; its C API still needs libc++.
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(name: "CPSeriesTests", dependencies: ["CPSeries"]),
    ]
)
