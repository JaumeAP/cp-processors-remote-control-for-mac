# CP Remote

## Building and testing: local first, CI only when it cannot run here

Before any build or test, run `macos/scripts/ensure-swift.sh` with
`SWIFT_SCRATCH_DIR` set to the session scratchpad. It prints where the work
runs:

1. `local` (exit 0): build and test here, with `swift build` / `swift test`
   in `macos/`. On a Mac this means the system's own Swift 6 (Xcode or the
   Command Line Tools) and a macOS SDK with SwiftUI and Network are present.
   Build the simulator into the scratchpad too
   (`c++ -std=c++17 -O2 -pthread simulator/processor_sim.cpp -o <scratchpad>/processor_sim`)
   and pass it as `CPSIM_BIN`; give `swift build` and `swift test`
   `--scratch-path <scratchpad>/swift-build`. A local pass is enough to merge;
   do not wait for CI.
2. `ci` (exit 2): this machine cannot build the app (a Mac without the system
   Swift or the SDK, or another system). Then the `test` job of the `macOS`
   GitHub workflow (`macos.yml`), which runs on every pull request, is the
   check: wait for it before merging.

On Linux without a system Swift 6, the script downloads Swift 6.3.3 into
`$SWIFT_SCRATCH_DIR/swift-6.3.3`, never into the home folder, and adds it to
PATH for the session. The Swift on Linux builds only the logic of
`CPx50Comms` that needs no Darwin, Network or SwiftUI (`LineBuffer`,
`CommandQueue`, `WireProtocol`, `ProtocolTiming`, `ProcessorModel`,
`ProcessorState`); the app, the transports and the simulator tests need a
Mac, locally or in CI.
