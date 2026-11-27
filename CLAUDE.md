# CP Remote

## Deployment target: macOS 12 for the whole repository

Every Swift package in this repository targets macOS 12 (Monterey) as its
minimum: `macos/Package.swift` and `cpseries-release/Package.swift`
(`platforms: [.macOS(.v12)]`). Do not use APIs newer than macOS 12 without an
availability check. The toolchain here (Swift 6.4.2) compiles no lower than
macOS 12, so macOS 11 is not a target.

## Release builds: universal binary

A published app is a universal binary (arm64 and x86_64).
`macos/scripts/make-dmg.sh` builds both by default (`ARCHS="arm64 x86_64"`);
`check-dmg.sh` checks the image. Build it locally and publish the image
yourself: no CI builds releases. The vendored cpx50comms library in
`cpseries-release/` includes the x86_64 slice since v2.2.0. A single-architecture
build (`ARCHS=arm64`) is not a release. The app bundle carries the library in
`Contents/Frameworks`, and `check-dmg.sh` verifies that the binary finds it there.

## Building and testing: local only

Verify every change on this Mac, never in CI. Before any build or test, run
`macos/scripts/ensure-swift.sh`; it installs nothing. `local` (exit 0) means the
system's own Swift 6 and a macOS SDK with SwiftUI and Network are present;
`unavailable` (exit 2) means this machine cannot build the app. Give
`swift build` and `swift test` `--scratch-path <scratchpad>/swift-build`, in
`macos/`. A local pass is enough to merge.

The app is SwiftUI and AppKit, so it builds and runs only on a Mac. It talks to
the processors over TCP/IP through the vendored cpseries library
(`cpseries-release/`, below).

## cpseries-release: the vendored client library

`cpseries-release/` is a SwiftPM package holding CPSeries' release binaries,
unchanged: the macOS build (linked by SwiftPM through `CPSeries.xcframework`,
product `CPSeries`, plain-C API). Never edit those files here;
`cpseries-release/RELEASE.md` lists their origin, tag, commit and hashes.
Test it with `swift test --scratch-path <scratchpad>/cpseries-release-build` in
`cpseries-release/`.

This repository holds no CPSeries source code. The app works without access to
the CPSeries repository.

Before any build or test, check the vendored pointer. Use the GitHub connector,
not the release notes:

1. Check access: `mcp__github__get_latest_release` on `JaumeAP/CPSeries`. If it
   fails, the repository is unreachable: skip to step 6 and use the vendored copy.
2. Compare the latest release tag with the tag in `cpseries-release/RELEASE.md`.
   If they match, the pointer is current: skip to step 6.
3. If they differ, update the pointer: download the new release's assets with
   `gh release download <tag> -R JaumeAP/CPSeries` into the session scratchpad,
   and verify them against its `SHA256SUMS`.
4. Vendor the new library: copy `libcpx50comms.dylib` into
   `Artifacts/macos-universal/` and `CPSeries.xcframework/macos-arm64_x86_64/`;
   copy the headers from the tag's `cpp/client/` (`cpx50comms.hpp`,
   `cpx50comms_c.h`, `cpx50comms_export.h`) into `Artifacts/macos-universal/include/`,
   and the two C headers into the xcframework's `Headers/`. Check the library's
   architectures (`lipo -archs`) and `minos 12.0`.
5. Update `cpseries-release/RELEASE.md` (tag, commit, hashes). Then build and test.
6. Build and test `cpseries-release/` with the vendored copy.

Access to the repository is for the pointer only: it is never a source for the
build itself.

## Audits: what to run, and where

Run every audit locally, from `macos/` or `cpseries-release/`, with
`--scratch-path <scratchpad>/...`. None runs in CI. Tools: Swift 6 from the
system toolchain (Xcode 27 here), plus the SwiftLint release binary in
`~/.local/bin`.

1. Strict build: `swift build -Xswiftc -warnings-as-errors` in `macos/`.
   Status: runnable.
2. App tests: `swift test` in `macos/`. `SimulatorLinkTests` run only when
   `CPSIM_PORT_CP650`, `CPSIM_PORT_CP750` and `CPSIM_PORT_CP950` are set, and
   need a processor simulator on those ports. The simulator source is not in
   this repository any more, so that binary must come from outside it.
   Status: runnable (13 tests pass with the simulators).
3. Library tests: `swift test` in `cpseries-release/` (3 tests).
   Status: runnable.
4. Thread sanitizer: `swift test --sanitize=thread` in `macos/` and in
   `cpseries-release/`. Targets the link queue and `RemoteModel` timing.
   Status: not yet run.
5. Address sanitizer: `swift test --sanitize=address` in both packages.
   Status: not yet run.
6. Coverage: `swift test --enable-code-coverage` in `macos/`, then read the
   per-file report. Shows which code has no test at all.
   Status: not yet run.
7. Format: `swift-format lint --recursive --configuration ../.swift-format Sources Tests`
   in `macos/`, with the repository's `.swift-format` (4-space indent, 120 columns).
   Status: 0 warnings.
8. Lint: `swiftlint lint --config ../.swiftlint.yml Sources Tests` in `macos/`. The
   repository's `.swiftlint.yml` turns off `trailing_comma` and `opening_brace`,
   which conflict with swift-format.
   Status: 0 findings.
9. Security patterns: `uvx semgrep --config p/swift` (registry config not yet
   checked to exist for Swift).
   Status: semgrep installed, Swift rules not verified.

Not used: mutation testing and the Python tools in the global list (mypy,
pylint, mutmut, pytest, vulture): they do not apply to Swift.
