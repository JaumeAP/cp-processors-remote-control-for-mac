# Vendored: the released cpseries client binaries (CPSeries v1.1.0)

These files come unchanged from the GitHub release `v1.1.0` of the private
repository `JaumeAP/CPSeries` ("cpseries client (C++) 1.1.0 — macOS +
Windows"), built there from `main` at `5ea82b6`. Do not edit or rebuild them
here: refresh them from a newer CPSeries release.

## Release archives

| Archive | SHA-256 (checked against the release notes) |
| --- | --- |
| `cpseries-1.1.0-macos-universal.tar.gz` | `281f4071336bac9bcc59bd8933fd029ab6cb6479b6487deaffa170b388fd3629` |
| `cpseries-1.1.0-windows-x64.zip` | `452b6934fe34efece4e6168bf784073b4e0e5b9b4440949786326e912f0d7461` |

## Layout

1. `Artifacts/macos-universal/` — the macOS archive, extracted as released:
   `libcpseries.a`, `libcpseries.dylib`, `include/cpseries.hpp`,
   `include/cpseries_c.h`, `LICENSE`, `USAGE.md`. macOS 11+, arm64 + x86_64.
2. `CPSeries.xcframework/` — the macOS `libcpseries.a` and both headers,
   wrapped so SwiftPM can link them (`binaryTarget` `CPSeriesC`). Its
   `Info.plist` and `Headers/module.modulemap` are the only files written
   here; the module map exposes only the plain-C header, `cpseries_c.h`.
3. `Sources/CPSeries/` — re-exports `CPSeriesC`, and links libc++, which the
   static library needs.
4. `Tests/CPSeriesTests/` — link checks of the C API, with no network.

Each `USAGE.md` describes its platform's contents and how to link them.

## File hashes

| File | SHA-256 |
| --- | --- |
| `macos-universal/libcpseries.a` | `7d8cdfd381a2baf038b3010ad67b853815e60370f725c8181f30815908d74f02` |
| `macos-universal/libcpseries.dylib` | `0ffe8561f7533a7c9011cf5282a0e02254e06599829a0bf7640537e2a8cbb6e2` |
| `cpseries.hpp` | `18cc1c4f2f36df5124f5c367bd163f29e3c192e6c9c87ebdfa0e6eeede81b908` |
| `cpseries_c.h` | `f827cb72a24f999924ee1f0776ac63692331aec56e981e4268bb490380ad248b` |

The copies inside `CPSeries.xcframework/` are byte-identical to the ones in
`Artifacts/macos-universal/`.

## Build and test

    cd cpseries-release && swift test --scratch-path <scratchpad>/cpseries-release-build

## Refreshing

1. Download the new release's archive (`gh release download <tag> -R
   JaumeAP/CPSeries`) into the session scratchpad and check its SHA-256
   against the release notes.
2. Replace `Artifacts/macos-universal/` with the extracted contents.
3. Copy `libcpseries.a`, `cpseries.hpp` and `cpseries_c.h` into
   `CPSeries.xcframework/macos-arm64_x86_64/` (and `Headers/`), update this
   file (tag, commit, hashes) and run the tests.
