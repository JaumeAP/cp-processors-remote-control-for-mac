# Vendored: the released cpx50comms client library (CPSeries v3.2.0)

The macOS library comes from the GitHub release `v3.2.0` of the private
repository `JaumeAP/CPSeries`, published 2026-11-27 (tag `v3.2.0`, commit
`a98f6ea`). The library is the release asset `libcpx50comms.dylib`, unchanged,
and its hash is checked against the release's `SHA256SUMS`. The headers are
from the same tag (`cpp/client/`). Do not edit them here: refresh them from a
newer CPSeries release (`CLAUDE.md`, "cpseries-release: the vendored client
library", has the procedure, including the pointer check).

The library is universal (arm64 and x86_64) with `minos 12.0`.

## Release assets (v3.2.0, macOS)

| Asset | SHA-256 (from the release's `SHA256SUMS`) |
| --- | --- |
| `libcpx50comms.dylib` (arm64 + x86_64) | `a54ea1c46eb86f8070799001b2c9649f1a5901d591d9af3ceb421b4ffc0be197` |
| `processor_sim` (the simulator; not vendored here) | `c7c564086aca2a733b651dfc1ac86fa9514e793a3696ce5aca04f78f20fbb9a9` |

## Layout

1. `Artifacts/macos-universal/`: `libcpx50comms.dylib` (arm64 and x86_64), the
   headers `include/cpx50comms.hpp`, `include/cpx50comms_c.h` and
   `include/cpx50comms_export.h` from tag `v3.2.0` (`cpp/client/`), and
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
| `Artifacts/macos-universal/libcpx50comms.dylib` | `a54ea1c46eb86f8070799001b2c9649f1a5901d591d9af3ceb421b4ffc0be197` |
| `Artifacts/macos-universal/include/cpx50comms.hpp` | `a7cc79164f0d61adea0ee2a849c457a743fdeca385367ef2b36b3f6dd972f66b` |
| `Artifacts/macos-universal/include/cpx50comms_c.h` | `6eb5e13876273e852b6b06fcdb86125b817911cbedb385db18e9820247681f5b` |
| `Artifacts/macos-universal/include/cpx50comms_export.h` | `e2fa3cf979050d6e63ff4a7257d34b09310fc3e2c8529059763a4bd4c4a2ef57` |

The copies inside `CPSeries.xcframework/macos-arm64_x86_64/` are byte-identical
to the library in `Artifacts/macos-universal/`.

## Build and test

    cd cpseries-release && swift test --scratch-path <scratchpad>/cpseries-release-build

Last run against v3.2.0: 3 tests pass (arm64, Swift 6.4.2).

## Refreshing

The procedure is in `CLAUDE.md`. In short: check the latest tag with the GitHub
connector, download the assets into the session scratchpad, verify them against
`SHA256SUMS`, vendor the library and headers as listed above, update this file
(tag, commit, hashes), and run the tests.
