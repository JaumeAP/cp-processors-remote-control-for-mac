# CP Remote

## Building and testing: local first, CI only when it cannot run here

Before any build or test, run `macos/scripts/ensure-swift.sh` with
`SWIFT_SCRATCH_DIR` set to the session scratchpad. It prints where the work
runs:

1. `local` (exit 0): build and test here, with `swift build` / `swift test`
   in `macos/`. On a Mac this means the system's own Swift 6 (Xcode or the
   Command Line Tools) and a macOS SDK with SwiftUI and Network are present.
   Give `swift build` and `swift test` `--scratch-path <scratchpad>/swift-build`.
   A local pass is enough to merge; do not wait for CI.
2. `ci` (exit 2): this machine cannot build the app (a Mac without the system
   Swift or the SDK, or another system). Then the `test` job of the `macOS`
   GitHub workflow (`macos.yml`), which runs on every pull request, is the
   check: wait for it before merging.

On Linux without a system Swift 6, the script downloads Swift 6.3.3 into
`$SWIFT_SCRATCH_DIR/swift-6.3.3`, never into the home folder, and adds it to
PATH for the session. The app is SwiftUI and AppKit, so it builds and runs
only on a Mac, locally or in CI. It is currently interface-only: it has no
processor communication.

## CPSeries: a read-only submodule

`CPSeries/` is the private repository `JaumeAP/CPSeries`, included as a git
submodule for reference only. It is read-only from this repository:

1. Read it, never change it: no edits, no commits, no branches and no pushes
   inside `CPSeries/`, and no pull requests or other GitHub writes on
   `JaumeAP/CPSeries`, unless the user explicitly authorizes that action.
2. The only change made from here is moving the pinned commit, and only when
   the user asks: `git submodule update --remote CPSeries`, then commit the
   new pointer in this repository.
3. After a fresh clone (`git submodule update --init CPSeries`), disable its
   push URL: `git -C CPSeries remote set-url --push origin "no-push: CPSeries is read-only here"`.

CPSeries is private, so only accounts with access to it can initialise the
submodule; everyone else gets an empty `CPSeries/` folder.

## cpseries-release: the released client binaries

`cpseries-release/` is a SwiftPM package holding CPSeries' release `v1.1.0`
binaries, unchanged: the macOS universal build (linked by SwiftPM through
`CPSeries.xcframework`, product `CPSeries`, plain-C API) and the Windows x64
build (kept in `Artifacts/windows-x64/`, not linked). Never edit those files
here; `cpseries-release/RELEASE.md` lists their origin, hashes and how to
refresh them. Test it with
`swift test --scratch-path <scratchpad>/cpseries-release-build` in
`cpseries-release/`.
