# CP Remote

Swift: `macos/scripts/ensure-swift.sh` installs a Swift 6 toolchain for the
user (no root) when none is there, and the cloud session start hook runs it.
Run it again if `swift` is not found. The Swift on Linux builds only the logic
of `CPx50Comms` that needs no Darwin, Network or SwiftUI (`LineBuffer`,
`CommandQueue`, `WireProtocol`, `ProtocolTiming`, `ProcessorModel`,
`ProcessorState`). The app, the transports and the simulator tests build and
run on macOS, in the `macOS` GitHub workflow (`macos.yml`): run it by hand on
a branch with no inputs to test, with `mutation` for the mutation tests, or
with `version` to release.
