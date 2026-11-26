# Vendored: the released cpx50comms client binaries (CPSeries v2.1.0)

The macOS files come from the GitHub release `v2.1.0` (tag commit `91855ad`)
of the private repository `JaumeAP/CPSeries`, published 2026-11-25. They are
the release assets and the headers of that tag, unchanged. Do not edit them
here: refresh them from a newer CPSeries release.

The previous release, v1.1.0 (`libcpseries`, `cpseries_c.h`), was removed
from this folder when the package moved to v2.1.0.

## Release assets (v2.1.0, macOS)

| Asset | SHA-256 (checked against the release notes) |
| --- | --- |
| `libcpx50comms.dylib` (CPX50COMMS_OMVLL + OBFUSCATE + SHARED) | `c04b1af8945572c449f7ed858de268d65411d2225398a83b56cde35a74432521` |
| `processor_sim-obf` (arm64 + x86_64, obfuscated, stripped) | `94e644065719d4d5a41d2eb74573dbfd13246bcbc61e07e41863a69d90aa67da` |

`processor_sim-obf` is not in this folder: the vendored simulator under
`cpseries-simulator/` is still the v1.1.0 source and has not been migrated.

## Layout

1. `Artifacts/macos-universal/`: `libcpx50comms.dylib` (arm64 only), the
   headers `include/cpx50comms.hpp`, `include/cpx50comms_c.h` and
   `include/cpx50comms_export.h` from tag `v2.1.0` (`cpp/client/`), and
   `LICENSE`.
2. `CPSeries.xcframework/`: the arm64 `libcpx50comms.dylib` and the plain-C
   header `cpx50comms_c.h` (with `cpx50comms_export.h`), wrapped so SwiftPM can
   link them (`binaryTarget` `CPSeriesC`). Its `Info.plist` and
   `macos-arm64/Headers/module.modulemap` are the only files written here; the
   module map exposes only `cpx50comms_c.h`.
3. `Sources/CPSeries/`: re-exports `CPSeriesC`.
4. `Tests/CPSeriesTests/`: link checks of the C API, with no network.

## File hashes

| File | SHA-256 |
| --- | --- |
| `Artifacts/macos-universal/libcpx50comms.dylib` | `c04b1af8945572c449f7ed858de268d65411d2225398a83b56cde35a74432521` |
| `Artifacts/macos-universal/include/cpx50comms_c.h` | `6eb5e13876273e852b6b06fcdb86125b817911cbedb385db18e9820247681f5b` |
| `Artifacts/macos-universal/include/cpx50comms.hpp` | `b20823d45c76f54a44b1b40cf2f51d9e642d3334a681a427c36121e73d947338` |
| `Artifacts/macos-universal/include/cpx50comms_export.h` | `cd50fe363877c5e51cfac4fd8a91f7d32da902720165227a6af020181c12a69d` |

The copies inside `CPSeries.xcframework/macos-arm64/` are byte-identical to
the ones in `Artifacts/macos-universal/`.

## Build and test

    cd cpseries-release && swift test --scratch-path <scratchpad>/cpseries-release-build

The link step warns that `libcpx50comms.dylib` was built for a newer macOS
than the package target (macOS 14.0).

## Refreshing

1. Download the new release's assets (`gh release download <tag> -R
   JaumeAP/CPSeries`) into the session scratchpad and check their SHA-256
   against the release notes.
2. Replace `Artifacts/macos-universal/` with the new contents.
3. Copy the new `libcpx50comms.dylib` and `cpx50comms_c.h` into
   `CPSeries.xcframework/macos-arm64/` (and `Headers/`), update this file (tag,
   commit, hashes) and run the tests.
