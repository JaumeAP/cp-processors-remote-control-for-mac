// swift-tools-version:6.0
// The C++ control client for Dolby CP processors, vendored from CPSeries
// (see VENDORED.md): a C++ library target that Swift code can use through
// Swift/C++ interoperability, and its command-line interop driver.
import PackageDescription

let package = Package(
    name: "CPClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DolbyCP", targets: ["DolbyCP"]),
        .executable(name: "cp_client", targets: ["cp_client"]),
    ],
    targets: [
        .target(name: "DolbyCP"),
        .executableTarget(name: "cp_client", dependencies: ["DolbyCP"]),
    ],
    cxxLanguageStandard: .cxx17
)
