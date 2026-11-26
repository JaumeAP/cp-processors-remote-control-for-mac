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
7. Format: `swift-format lint --recursive Sources Tests` in `macos/`. No
   `.swift-format` file exists, so the defaults apply.
   Status: available (Xcode toolchain), not yet run.
8. Lint: `swiftlint lint` in `macos/`. No `.swiftlint.yml` exists, so the
   defaults apply.
   Status: installed (0.65.1), not configured.
9. Security patterns: `uvx semgrep --config p/swift` (registry config not yet
   checked to exist for Swift).
   Status: semgrep installed, Swift rules not verified.

Not used: mutation testing and the Python tools in the global list (mypy,
pylint, mutmut, pytest, vulture): they do not apply to Swift.
