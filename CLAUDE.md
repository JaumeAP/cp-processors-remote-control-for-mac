# CP Remote

## Building and testing: local only

Verify every change on this Mac, never in CI. Before any build or test, run
`macos/scripts/ensure-swift.sh` with `SWIFT_SCRATCH_DIR` set to the session
scratchpad. It prints where the work runs: `local` (exit 0) means the system's
own Swift 6 and a macOS SDK with SwiftUI and Network are present. Give
`swift build` and `swift test` `--scratch-path <scratchpad>/swift-build`, in
`macos/`. A local pass is enough to merge.

The app is SwiftUI and AppKit, so it builds and runs only on a Mac. It talks to
the processors over TCP/IP through the vendored cpseries library
(`cpseries-release/`, below).

## cpseries-release: the vendored client library

`cpseries-release/` is a SwiftPM package holding CPSeries' release `v2.1.0`
binaries, unchanged: the macOS build (linked by SwiftPM through
`CPSeries.xcframework`, product `CPSeries`, plain-C API). Never edit those files
here; `cpseries-release/RELEASE.md` lists their origin, hashes and how to
refresh them. Test it with
`swift test --scratch-path <scratchpad>/cpseries-release-build` in
`cpseries-release/`.

This repository holds no CPSeries source code. The app works without access to
the CPSeries repository.
