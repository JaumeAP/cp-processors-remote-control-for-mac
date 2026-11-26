# Vendored: the released cpx50comms client binaries (CPSeries v2.2.0)

The macOS files come from the GitHub release `v2.2.0` of the private
repository `JaumeAP/CPSeries`, published 2026-11-26. The library is the
release asset, unchanged. The headers are from the same tag (`cpp/client/`),
and they are byte-identical to the v2.1.0 headers. Do not edit them here:
refresh them from a newer CPSeries release.

The previous release, v2.1.0, shipped an arm64-only library. v2.2.0 ships a
universal one (arm64 and x86_64, `minos 12.0`).

## Release assets (v2.2.0, macOS)

| Asset | SHA-256 (checked against the release notes) |
| --- | --- |
| `libcpx50comms.dylib` (CPX50COMMS_OMVLL + OBFUSCATE + SHARED, arm64 + x86_64) | `4a6cc941acddabf793030c90b8c8e870df4d2a773dcbd4b6f206c18037b211ae` |

`processor_sim-obf` (the obfuscated processor simulator) is also a v2.2.0
asset, `236b731d4b59d56eb2bd040b896c048eec3270999d9c2e6ce21018c480729e13`.
It is not vendored here: the simulator source is no longer in this repository.

## Layout

1. `Artifacts/macos-universal/`: `libcpx50comms.dylib` (arm64 and x86_64), the
   headers `include/cpx50comms.hpp`, `include/cpx50comms_c.h` and
   `include/cpx50comms_export.h` from tag `v2.2.0` (`cpp/client/`), and
   `LICENSE`.
2. `CPSeries.xcframework/`: the universal `libcpx50comms.dylib` (in
   `macos-arm64_x86_64/`) and the plain-C header `cpx50comms_c.h` (with
   `cpx50comms_export.h`), wrapped so SwiftPM can link them (`binaryTarget`
   `CPSeriesC`). Its `Info.plist` and `macos-arm64_x86_64/Headers/module.modulemap`
   are the only files written here; the module map exposes only
   `cpx50comms_c.h`.
3. `Sources/CPSeries/`: re-exports `CPSeriesC`.
4. `Tests/CPSeriesTests/`: link checks of the C API, with no network.

## File hashes

| File | SHA-256 |
| --- | --- |
| `Artifacts/macos-universal/libcpx50comms.dylib` | `4a6cc941acddabf793030c90b8c8e870df4d2a773dcbd4b6f206c18037b211ae` |
| `Artifacts/macos-universal/include/cpx50comms_c.h` | `6eb5e13876273e852b6b06fcdb86125b817911cbedb385db18e9820247681f5b` |
| `Artifacts/macos-universal/include/cpx50comms.hpp` | `b20823d45c76f54a44b1b40cf2f51d9e642d3334a681a427c36121e73d947338` |
| `Artifacts/macos-universal/include/cpx50comms_export.h` | `cd50fe363877c5e51cfac4fd8a91f7d32da902720165227a6af020181c12a69d` |

The copies inside `CPSeries.xcframework/macos-arm64_x86_64/` are byte-identical
to the library in `Artifacts/macos-universal/`.

## Build and test

    cd cpseries-release && swift test --scratch-path <scratchpad>/cpseries-release-build

## Refreshing

1. Download the new release's assets (`gh release download <tag> -R
   JaumeAP/CPSeries`) into the session scratchpad and check their SHA-256
   against the release notes.
2. Replace `Artifacts/macos-universal/libcpx50comms.dylib` and the headers
   under `Artifacts/macos-universal/include/` from the tag's `cpp/client/`.
3. Copy the new `libcpx50comms.dylib` into `CPSeries.xcframework/macos-arm64_x86_64/`,
   copy `cpx50comms_c.h` and `cpx50comms_export.h` into its `Headers/` if they
   changed, update this file (tag, commit, hashes) and run the tests.
