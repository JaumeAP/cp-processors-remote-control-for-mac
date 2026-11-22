# Windows package

The Windows application (WPF, .NET 10) goes in this folder. It is not written yet.

It builds on the `common/CPRemote.Core` library, which wraps the cpseries C API
(`libcpseries.dll`, shipped in `cpseries-release/Artifacts/windows-x64`). The
Mac package is `macos/`, the Swift app. The release binaries and the simulator
stay at the repository root, where `macos/Package.swift` and the CI workflow
already reference them.
