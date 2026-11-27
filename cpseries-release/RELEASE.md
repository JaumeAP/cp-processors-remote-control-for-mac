# Vendored: the released cpx50comms client library (CPSeries v3.0.0)

The macOS library comes from the GitHub release `v3.0.0` of the private
repository `JaumeAP/CPSeries`, published 2026-11-27 (tag `v3.0.0`, commit
`25d13d3`). The library is the release asset `libcpx50comms.dylib`, unchanged,
and its hash is checked against the release's `SHA256SUMS`. The headers are
from the same tag (`cpp/client/`). Do not edit them here: refresh them from a
newer CPSeries release (`CLAUDE.md`, "cpseries-release: the vendored client
library", has the procedure, including the pointer check).

The library is universal (arm64 and x86_64) with `minos 12.0`.

## Release assets (v3.0.0, macOS)

| Asset | SHA-256 (from the release's `SHA256SUMS`) |
| --- | --- |
| `libcpx50comms.dylib` (arm64 + x86_64) | `290ded6ee2a6d27fd424f465baad0ca832b9757c8026114da7f052178bacfcd3` |
| `processor_sim` (the simulator; not vendored here) | see `SHA256SUMS` of the release |

## Layout

1. `Artifacts/macos-universal/`: `libcpx50comms.dylib` (arm64 and x86_64), the
   headers `include/cpx50comms.hpp`, `include/cpx50comms_c.h` and
   `include/cpx50comms_export.h` from tag `v3.0.0` (`cpp/client/`), and
   `LICENSE`.
2. `CPSeries.xcframework/`: the universal `libcpx50comms.dylib` (in
   `macos-arm64_x86_64/`) and the plain-C headers `cpx50comms_c.h` and
   `cpx50comms_export.h`, wrapped so SwiftPM can link them (`binaryTarget`
   `CPSeriesC`). Its `Info.plist` and `macos-arm64_x86_64/Headers/module.modulemap`
   are the only files written here; the module map exposes only
   `cpx50comms_c.h`.
3. `Sources/CPSeries/`: re-exports `CPSeriesC`.
4. `Tests/CPSeriesTests/`: link checks of the C API, with no network.

## File hashes

| File | SHA-256 |
| --- | --- |
| `Artifacts/macos-universal/libcpx50comms.dylib` | `290ded6ee2a6d27fd424f465baad0ca832b9757c8026114da7f052178bacfcd3` |
| `Artifacts/macos-universal/include/cpx50comms.hpp` | `9d42a112dd90129443683235cac5279cc0a2e94b5c52d39d5fdab48e20b67e31` |
| `Artifacts/macos-universal/include/cpx50comms_c.h` | `6eb5e13876273e852b6b06fcdb86125b817911cbedb385db18e9820247681f5b` |
| `Artifacts/macos-universal/include/cpx50comms_export.h` | `e2fa3cf979050d6e63ff4a7257d34b09310fc3e2c8529059763a4bd4c4a2ef57` |

The copies inside `CPSeries.xcframework/macos-arm64_x86_64/` are byte-identical
to the library in `Artifacts/macos-universal/`.

## Build and test

    cd cpseries-release && swift test --scratch-path <scratchpad>/cpseries-release-build

Last run against v3.0.0: 3 tests pass.

## Refreshing

The procedure is in `CLAUDE.md`. In short: check the latest tag with the GitHub
connector, download the assets into the session scratchpad, verify them against
`SHA256SUMS`, vendor the library and headers as listed above, update this file
(tag, commit, hashes), and run the tests.
